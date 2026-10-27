#!/usr/bin/env bash
set -Eeuo pipefail

# One-time Incus public IPv6 auto allocator installer.
# Automatically detects the host's public global IPv6 /64 and interface.
# Optionally override detection by exporting PREFIX and/or PARENT before running.
# Allocates the lowest free address, attaches routed NICs to new instances,
# and serves Cloud-Init metadata over each routed NIC's link-local gateway.

PREFIX="${PREFIX:-}"
PARENT="${PARENT:-}"
META_PORT="17863"
BASE_DIR="/var/lib/incus-public-ipv6"
CONFIG_DIR="/etc/incus-public-ipv6"
DAEMON="/usr/local/libexec/incus-public-ipv6d.py"
UNIT="/etc/systemd/system/incus-public-ipv6d.service"
SYSCTL_FILE="/etc/sysctl.d/90-incus-public-ipv6-auto.conf"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this setup script as root."
command -v incus >/dev/null || die "Incus CLI not found on this host."
command -v python3 >/dev/null || die "Python 3 is required."
command -v systemctl >/dev/null || die "systemd is required."
command -v ip >/dev/null || die "iproute2 is required."

incus info >/dev/null 2>&1 || die "Cannot connect to the local Incus daemon."
# Detect a unique public /64 and the interface carrying it. No host IPv4 or
# default-profile bridge is required; metadata is reachable via fe80::1 on the
# routed NIC installed for each guest.
DETECTED="$(python3 - "$PREFIX" "$PARENT" <<'PY'
import ipaddress, subprocess, sys
requested_prefix, requested_iface = sys.argv[1:]
try:
    rows = subprocess.check_output(
        ["ip", "-o", "-6", "addr", "show", "scope", "global"], text=True
    ).splitlines()
except subprocess.CalledProcessError as exc:
    raise SystemExit(f"Unable to inspect global IPv6 addresses: {exc}")

records = []
for line in rows:
    fields = line.split()
    if len(fields) < 4:
        continue
    iface = fields[1].split("@", 1)[0]
    try:
        address = ipaddress.ip_interface(fields[3])
    except ValueError:
        continue
    records.append((iface, address))

if requested_prefix:
    try:
        prefix = ipaddress.ip_network(requested_prefix, strict=False)
    except ValueError as exc:
        raise SystemExit(f"Invalid PREFIX: {exc}")
    if not isinstance(prefix, ipaddress.IPv6Network) or prefix.prefixlen != 64:
        raise SystemExit("PREFIX must be an IPv6 /64.")
else:
    # Ignore ULA prefixes (fd00::/8) often present on managed Incus bridges;
    # automatically select from public global-unicast IPv6 only.
    global_unicast = ipaddress.ip_network("2000::/3")
    candidate_prefixes = {
        address.network for _, address in records
        if address.network.prefixlen == 64 and address.ip in global_unicast
    }
    if len(candidate_prefixes) != 1:
        choices = ", ".join(sorted(str(x) for x in candidate_prefixes)) or "none"
        raise SystemExit(
            "Could not automatically select a unique global IPv6 /64 "
            f"(found: {choices}). Set PREFIX to the desired /64 and rerun."
        )
    prefix = next(iter(candidate_prefixes))

if requested_iface:
    if not any(iface == requested_iface and address.ip in prefix
               for iface, address in records):
        raise SystemExit(f"No global address from {prefix} found on {requested_iface}.")
    iface = requested_iface
else:
    candidates = sorted({iface for iface, address in records if address.ip in prefix})
    if len(candidates) != 1:
        choices = ", ".join(candidates) or "none"
        raise SystemExit(
            f"Could not automatically select one interface carrying {prefix} "
            f"(found: {choices}). Set PARENT to the correct interface and rerun."
        )
    iface = candidates[0]

print(prefix)
print(iface)
PY
)" || die "Unable to detect the public IPv6 prefix/interface."
mapfile -t DETECTED_VALUES <<< "$DETECTED"
[[ ${#DETECTED_VALUES[@]} -ge 2 ]] || die "IPv6 auto-detection returned incomplete results."
PREFIX="${DETECTED_VALUES[0]}"
PARENT="${DETECTED_VALUES[1]}"
ip link show "$PARENT" >/dev/null 2>&1 || die "Detected interface $PARENT not found."
printf 'Detected public IPv6 prefix %s on %s\n' "$PREFIX" "$PARENT"

# Metadata is delivered using fe80::1 scoped to guest interface pub6; no
# hardcoded private host IPv4 or default-profile IPv4 network is involved.


printf 'Public prefix : %s\n' "$PREFIX"
printf 'Parent NIC    : %s\n' "$PARENT"
printf 'Metadata URL  : http://[fe80::1%%25pub6]:%s/v1/address\n' "$META_PORT"
printf 'IP allocator  : lowest available address starting at ::1\n'
printf 'Automation    : existing instances reconciled; future instance-created events handled\n'
printf '\nThe service will automatically add a routed NIC to instances that do not already have one from this prefix.\n'
printf 'Linux VMs require the generated Cloud-Init vendor-data snippet to configure IPv6 inside the guest.\n\n'
read -r -p 'Enable automatic public IPv6 allocation? [y/N]: ' CONFIRM
[[ "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]] || die "Cancelled."

install -d -m 0750 "$BASE_DIR" "$CONFIG_DIR" /usr/local/libexec

python3 - "$CONFIG_DIR/config.json" "$PREFIX" "$PARENT" "$META_PORT" "$BASE_DIR/allocations.json" "$BASE_DIR/lock" <<'PY'
import json, os, sys
path, prefix, parent, meta_port, database, lock = sys.argv[1:]
data = {
    "prefix": prefix,
    "parent": parent,
    "metadata_port": int(meta_port),
    "database": database,
    "lock_file": lock,
    "device_base": "public6",
    "guest_interface": "pub6",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o640)
os.replace(tmp, path)
PY

cat > "$SYSCTL_FILE" <<EOF
# Managed by incus-public-ipv6-auto-setup.sh
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.${PARENT}.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.${PARENT}.proxy_ndp=1
EOF
sysctl --load="$SYSCTL_FILE" >/dev/null

cat > "$DAEMON" <<'PYTHON_DAEMON'
#!/usr/bin/env python3
import fcntl
import ipaddress
import json
import os
import random
import re
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, unquote

CONFIG_PATH = "/etc/incus-public-ipv6/config.json"
with open(CONFIG_PATH, encoding="utf-8") as f:
    CFG = json.load(f)

PREFIX = ipaddress.ip_network(CFG["prefix"], strict=False)
PARENT = CFG["parent"]
META_PORT = int(CFG["metadata_port"])
DB_PATH = CFG["database"]
LOCK_PATH = CFG["lock_file"]
DEVICE_BASE = CFG.get("device_base", "public6")
GUEST_IFACE = CFG.get("guest_interface", "pub6")
DB_LOCK = threading.RLock()


def log(message):
    print(f"[incus-public-ipv6] {message}", flush=True)


def run(args, *, check=True, timeout=45):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(args)}: {result.stderr.strip()}")
    return result


def incus(project, *args, check=True, timeout=45):
    return run(["incus", "--project", project, *args], check=check, timeout=timeout)


def lock_file():
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
    return fd


def load_db_unlocked():
    try:
        with open(DB_PATH, encoding="utf-8") as f:
            value = json.load(f)
        if isinstance(value, dict) and isinstance(value.get("allocations"), list):
            return value
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return {"version": 1, "allocations": []}


def save_db_unlocked(db):
    directory = os.path.dirname(DB_PATH)
    os.makedirs(directory, mode=0o750, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="allocations.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(db, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o640)
        os.replace(tmp, DB_PATH)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_db():
    with DB_LOCK:
        return load_db_unlocked()


def update_db(mutator):
    # Cross-process lock also protects against an operator running another copy.
    with DB_LOCK:
        fd = lock_file()
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            db = load_db_unlocked()
            mutator(db)
            save_db_unlocked(db)
            return db
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def valid_address(value):
    try:
        addr = ipaddress.ip_address(str(value).split("/")[0])
        return addr.version == 6 and addr in PREFIX
    except ValueError:
        return False


def get_instance(project, name):
    # `incus config show` emits YAML and does not support --format=json.
    # Query the Incus REST API instead, which returns the instance struct as JSON.
    from urllib.parse import quote

    path = (
        f"/1.0/instances/{quote(name, safe='')}"
        f"?project={quote(project or 'default', safe='')}&recursion=1"
    )
    result = run(["incus", "query", path], check=False, timeout=45)
    if result.returncode != 0:
        log(f"Unable to query instance {project}/{name}: {result.stderr.strip()}")
        return None

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        log(f"Invalid JSON returned for {project}/{name}: {exc}")
        return None

    # `incus query` normally returns API metadata directly; also accept the
    # standard API envelope for clients/builds that preserve it.
    if isinstance(payload, dict) and isinstance(payload.get("metadata"), dict):
        payload = payload["metadata"]
    if not isinstance(payload, dict):
        log(f"Unexpected API response for {project}/{name}")
        return None

    # Use expanded configuration so NICs inherited from profiles are visible.
    payload = dict(payload)
    payload["devices"] = payload.get("expanded_devices") or payload.get("devices") or {}
    payload["config"] = payload.get("expanded_config") or payload.get("config") or {}
    return payload


def config_device_ipv6(device):
    value = device.get("ipv6.address", "")
    if not value or value in ("none", "auto"):
        return ""
    for candidate in str(value).split(","):
        if valid_address(candidate):
            return ipaddress.ip_address(candidate.split("/")[0]).compressed
    return ""


def device_mac(device_name, device, data):
    config = data.get("config", {}) or {}
    mac = device.get("hwaddr") or config.get(f"volatile.{device_name}.hwaddr") or ""
    mac = str(mac).lower()
    return mac if re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", mac) else ""


def existing_public_device(data):
    for dev_name, dev in (data.get("devices", {}) or {}).items():
        if dev.get("type") != "nic" or dev.get("nictype") != "routed":
            continue
        if dev.get("parent") != PARENT:
            continue
        address = config_device_ipv6(dev)
        if address:
            return dev_name, address, device_mac(dev_name, dev, data), dev
    return None


def list_instances():
    result = run(["incus", "list", "--all-projects", "--format=json"], check=False, timeout=60)
    if result.returncode != 0:
        log(f"Unable to list instances: {result.stderr.strip()}")
        return []
    try:
        rows = json.loads(result.stdout)
    except json.JSONDecodeError:
        log("Unable to parse incus list JSON")
        return []
    result_rows = []
    for row in rows:
        name = row.get("name")
        if not name:
            continue
        project = row.get("project") or "default"
        result_rows.append({
            "name": name,
            "project": project,
            "type": row.get("type", "container"),
            "status": row.get("status", ""),
        })
    return result_rows


def all_used_addresses():
    used = set()
    db = read_db()
    for item in db["allocations"]:
        addr = item.get("address", "")
        if valid_address(addr):
            used.add(ipaddress.ip_address(addr))

    # Host's configured global IPv6 addresses.
    result = run(["ip", "-o", "-6", "addr", "show", "scope", "global"], check=False)
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) > 3:
            try:
                addr = ipaddress.ip_interface(fields[3]).ip
                if addr in PREFIX:
                    used.add(addr)
            except ValueError:
                pass

    # Existing proxy-NDP addresses.
    result = run(["ip", "-6", "neigh", "show", "proxy", "dev", PARENT], check=False)
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields:
            try:
                addr = ipaddress.ip_address(fields[0])
                if addr in PREFIX:
                    used.add(addr)
            except ValueError:
                pass

    # Existing instance addresses, including manually configured routed NICs.
    for item in list_instances():
        data = get_instance(item["project"], item["name"])
        if not data:
            continue
        for device in (data.get("devices", {}) or {}).values():
            address = config_device_ipv6(device)
            if address:
                used.add(ipaddress.ip_address(address))

    return used


def allocate_lowest():
    used = all_used_addresses()
    base = int(PREFIX.network_address)
    # Sequentially use ::1, ::2, ::3, ...; enough space for one million guests.
    for host_id in range(1, 1_000_001):
        candidate = ipaddress.IPv6Address(base + host_id)
        if candidate not in used:
            return candidate.compressed
    raise RuntimeError("No free IPv6 found in the first one million addresses of the prefix")


def device_name_for(data):
    devices = data.get("devices", {}) or {}
    if DEVICE_BASE not in devices:
        return DEVICE_BASE
    suffix = 1
    while f"{DEVICE_BASE}auto{suffix}" in devices:
        suffix += 1
    return f"{DEVICE_BASE}auto{suffix}"


def make_mac():
    # Locally administered allocation under the Incus/LXD OUI.
    while True:
        value = random.getrandbits(24)
        mac = f"00:16:3e:{(value >> 16) & 255:02x}:{(value >> 8) & 255:02x}:{value & 255:02x}"
        existing = {item.get("mac", "").lower() for item in read_db()["allocations"]}
        if mac not in existing:
            return mac


def find_assignment(project, name):
    for item in read_db()["allocations"]:
        if item.get("project") == project and item.get("name") == name:
            return item
    return None


def save_assignment(item):
    def mutate(db):
        db["allocations"] = [
            row for row in db["allocations"]
            if not (row.get("project") == item["project"] and row.get("name") == item["name"])
        ]
        db["allocations"].append(item)
    update_db(mutate)


def adopt_existing(project, name, data, existing):
    dev_name, address, mac, device = existing
    if not mac:
        # Already configured manually; leave it intact. No metadata mapping needed.
        log(f"{project}/{name}: existing routed IPv6 {address}; leaving it unchanged")
        return
    item = {
        "project": project, "name": name, "device": dev_name,
        "address": address, "mac": mac, "kind": "existing", "managed": False,
    }
    save_assignment(item)
    log(f"{project}/{name}: adopted existing routed IPv6 {address}; device unchanged")


def add_device(project, name, device_name, address, mac):
    # Static device config; Incus itself manages the host route and Proxy NDP.
    incus(project, "config", "device", "add", name, device_name, "nic",
          "nictype=routed", f"parent={PARENT}", f"ipv6.address={address}",
          f"hwaddr={mac}", f"name={GUEST_IFACE}", timeout=90)


def ensure_instance(project, name, kind="container"):
    data = get_instance(project, name)
    if data is None:
        # Event may arrive slightly before the instance is queryable; reconcile will retry.
        return

    current = existing_public_device(data)
    existing_row = find_assignment(project, name)

    if current:
        if existing_row and current[0] == existing_row.get("device") and current[1] == existing_row.get("address"):
            return
        adopt_existing(project, name, data, current)
        return

    if existing_row:
        # Device may have been removed manually. Restore it with the same reserved address.
        devices = data.get("devices", {}) or {}
        dev_name = existing_row.get("device", DEVICE_BASE)
        if dev_name in devices:
            dev_name = device_name_for(data)
            existing_row["device"] = dev_name
        try:
            add_device(project, name, dev_name, existing_row["address"], existing_row["mac"])
            save_assignment(existing_row)
            log(f"{project}/{name}: restored {existing_row['address']}")
        except Exception as e:
            log(f"{project}/{name}: could not restore previous IPv6 device: {e}")
        return

    # Single daemon worker serializes allocations, avoiding address collisions.
    address = allocate_lowest()
    dev_name = device_name_for(data)
    mac = make_mac()
    try:
        add_device(project, name, dev_name, address, mac)
    except Exception as e:
        log(f"{project}/{name}: failed to attach IPv6 {address}: {e}")
        return

    item = {
        "project": project, "name": name, "device": dev_name,
        "address": address, "mac": mac, "kind": kind, "managed": True,
    }
    save_assignment(item)
    log(f"ALLOCATED {address} -> {project}/{name} ({kind}), device={dev_name}, MAC={mac}")


def prune_deleted(live_keys):
    def mutate(db):
        before = len(db["allocations"])
        db["allocations"] = [
            row for row in db["allocations"]
            if (row.get("project", "default"), row.get("name", "")) in live_keys
        ]
        removed = before - len(db["allocations"])
        if removed:
            log(f"Released {removed} stale IPv6 allocation(s)")
    update_db(mutate)


def reconcile_all():
    rows = list_instances()
    live_keys = {(row["project"], row["name"]) for row in rows}
    prune_deleted(live_keys)
    for row in rows:
        ensure_instance(row["project"], row["name"], row.get("type", "container"))


def parse_instance_event(source, context=None):
    parsed = urlparse(source or "")
    bits = [unquote(bit) for bit in parsed.path.rstrip("/").split("/") if bit]
    if len(bits) < 3 or bits[-2] != "instances":
        return "default", ""
    name = bits[-1]
    query = parse_qs(parsed.query)
    project = (query.get("project") or [None])[0]
    if not project and isinstance(context, dict):
        project = context.get("project")
    return project or "default", name


def handle_event(event):
    if not isinstance(event, dict):
        return
    metadata = event.get("metadata", {}) or {}
    action = metadata.get("action", "")
    if action not in ("instance-created", "instance-deleted", "instance-renamed", "instance-restored", "instance-started"):
        return
    context = metadata.get("context", {}) or {}
    project, name = parse_instance_event(metadata.get("source", ""), context)
    if not name:
        return

    if action == "instance-deleted":
        def mutate(db):
            before = len(db["allocations"])
            db["allocations"] = [r for r in db["allocations"] if not (r.get("project", "default") == project and r.get("name") == name)]
            if len(db["allocations"]) != before:
                log(f"{project}/{name}: released IPv6 allocation after deletion")
        update_db(mutate)
        return

    if action == "instance-renamed":
        old_name = context.get("old_name")
        if old_name:
            def mutate(db):
                for row in db["allocations"]:
                    if row.get("project", "default") == project and row.get("name") == old_name:
                        row["name"] = name
            update_db(mutate)

    ensure_instance(project, name)


class MetadataHandler(BaseHTTPRequestHandler):
    server_version = "IncusPublicIPv6/1.0"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        # Only accept requests coming from the link-local side of a routed NIC.
        # This prevents Internet clients from using the metadata endpoint.
        try:
            peer = ipaddress.ip_address(self.client_address[0].split("%", 1)[0])
        except ValueError:
            self.send_error(403, "Invalid client address")
            return
        if not peer.is_link_local:
            self.send_error(403, "Link-local guest requests only")
            return

        parsed = urlparse(self.path)
        if parsed.path != "/v1/address":
            self.send_error(404)
            return
        query = parse_qs(parsed.query)
        mac = (query.get("mac") or [""])[0].lower()
        if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", mac):
            self.send_error(400, "Expected a NIC MAC address")
            return

        address = ""
        with DB_LOCK:
            db = load_db_unlocked()
            for row in db["allocations"]:
                if row.get("mac", "").lower() == mac and valid_address(row.get("address", "")):
                    address = ipaddress.ip_address(row["address"]).compressed
                    break

        if not address:
            self.send_error(404, "No IPv6 allocation for this MAC")
            return

        body = (address + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class IPv6ThreadingHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def metadata_server():
    try:
        # Routed NICs use fe80::1 as the host-side link-local gateway. One
        # IPv6 listener can serve each guest; the handler accepts link-local
        # clients only, without requiring a private IPv4 bridge.
        server = IPv6ThreadingHTTPServer(("::", META_PORT), MetadataHandler)
    except Exception as e:
        log(f"IPv6 metadata HTTP server failed on port {META_PORT}: {e}")
        raise
    server.daemon_threads = True
    log(f"Metadata endpoint listening on [::]:{META_PORT}; link-local clients only")
    server.serve_forever(poll_interval=1)


def monitor_events():
    command = ["incus", "monitor", "--all-projects", "--type=lifecycle", "--format=json"]
    decoder = json.JSONDecoder()
    while True:
        proc = None
        try:
            log("Connecting to Incus lifecycle event stream")
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            if proc.stdout is None:
                raise RuntimeError("No monitor stdout")
            fd = proc.stdout.fileno()
            buffer = ""
            last_reconcile = time.monotonic()
            while True:
                readable, _, _ = select.select([fd], [], [], 20)
                if not readable:
                    if time.monotonic() - last_reconcile >= 20:
                        reconcile_all()
                        last_reconcile = time.monotonic()
                    if proc.poll() is not None:
                        raise RuntimeError("incus monitor exited")
                    continue

                chunk = os.read(fd, 65536)
                if not chunk:
                    raise RuntimeError("incus monitor stream closed")
                buffer += chunk.decode("utf-8", errors="replace")

                while True:
                    stripped = buffer.lstrip()
                    if not stripped:
                        buffer = ""
                        break
                    try:
                        event, end = decoder.raw_decode(stripped)
                    except json.JSONDecodeError:
                        break
                    buffer = stripped[end:]
                    handle_event(event)
        except Exception as e:
            log(f"Monitor/reconcile error: {e}")
        finally:
            if proc is not None:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
        time.sleep(3)
        try:
            reconcile_all()
        except Exception as e:
            log(f"Startup reconciliation failed: {e}")


def main():
    os.makedirs(os.path.dirname(DB_PATH), mode=0o750, exist_ok=True)
    if not os.path.exists(DB_PATH):
        save_db_unlocked({"version": 1, "allocations": []})
    threading.Thread(target=metadata_server, name="metadata-http", daemon=True).start()
    # Reconcile existing instances first, then watch create/delete events forever.
    try:
        reconcile_all()
    except Exception as e:
        log(f"Initial reconciliation failed (will retry): {e}")
    monitor_events()


if __name__ == "__main__":
    main()
PYTHON_DAEMON
chmod 0750 "$DAEMON"

cat > "$UNIT" <<EOF
[Unit]
Description=Automatic public IPv6 allocator for Incus instances
After=network-online.target incus.service incusd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DAEMON
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$BASE_DIR

[Install]
WantedBy=multi-user.target
EOF

# Cloud-Init vendor-data: guest-side VM interface config. This is intentionally
# a separate file so existing profile user-data/vendor-data is never overwritten.
GUEST_SNIPPET="$BASE_DIR/cloud-init-vendor-data.yaml"
cat > "$GUEST_SNIPPET" <<'GUEST_VENDOR_DATA'
#cloud-config
packages:
  - curl
  - iproute2
write_files:
  - path: /usr/local/sbin/incus-public-ipv6-guest
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      META_PORT="__META_PORT__"
      PUBLIC_PREFIX="__PREFIX_BASE__"
      IFACE="pub6"

      for attempt in $(seq 1 180); do
        if [[ -r "/sys/class/net/${IFACE}/address" ]]; then
          mac="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/${IFACE}/address")"
          metadata_url="http://[fe80::1%25${IFACE}]:${META_PORT}/v1/address?mac=${mac}"
          address="$(curl --noproxy '*' -g -fsS --connect-timeout 2 --max-time 3 "$metadata_url" 2>/dev/null || true)"
          case "$address" in
            "${PUBLIC_PREFIX}"*)
              ip -6 address replace "${address}/128" dev "$IFACE"
              ip -6 route replace default via fe80::1 dev "$IFACE" metric 10
              exit 0
              ;;
          esac
        fi
        sleep 2
      done

      echo "Timed out waiting for Incus public IPv6 allocation on ${IFACE}" >&2
      exit 1
  - path: /etc/systemd/system/incus-public-ipv6.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Configure routed public IPv6 assigned by the Incus host
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/incus-public-ipv6-guest
      RemainAfterExit=yes
      Restart=on-failure
      RestartSec=15

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, incus-public-ipv6.service]
GUEST_VENDOR_DATA

PREFIX_BASE="${PREFIX%/64}"
python3 - "$GUEST_SNIPPET" "$META_PORT" "$PREFIX_BASE" <<'PY'
import os, sys
path, port, prefix_base = sys.argv[1:]
text = open(path, encoding="utf-8").read()
text = text.replace("__META_PORT__", port).replace("__PREFIX_BASE__", prefix_base)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY

log "Enabling IPv6 forwarding and Proxy NDP"
systemctl daemon-reload
systemctl enable incus-public-ipv6d.service
# Restart rather than only enable --now: the installer may be rerun to update
# the daemon code, and an already-active unit must load the new version.
systemctl restart incus-public-ipv6d.service

log "Setup completed"
printf 'Prefix             : %s\n' "$PREFIX"
printf 'Parent NIC         : %s\n' "$PARENT"
printf 'Metadata endpoint  : [fe80::1%%25pub6]:%s/v1/address (link-local)\n' "$META_PORT"
printf 'Cloud-Init snippet : %s\n' "$GUEST_SNIPPET"
printf 'Service status     : systemctl status incus-public-ipv6d\n'
printf 'Service logs       : journalctl -u incus-public-ipv6d -f\n'
printf '\nLXC/container: routed IPv6 is attached and configured by Incus automatically.\n'
printf 'VM: add the contents of the generated snippet to Cloud-Init VENDOR-DATA in each VM profile.\n'
printf 'Use a Cloud-Init-enabled Linux VM image. No per-instance IP command will be needed.\n'
