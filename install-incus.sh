#!/usr/bin/env bash
# Install Incus from Debian and the Incus web UI from Zabbly.
# Keep Incus API on the local Unix socket. Never create test instances.
set -Eeuo pipefail

trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_CODENAME:-}" != trixie ]]; then
  echo "This installer requires Debian 13 (trixie)." >&2
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "Supported architectures: amd64 and arm64." >&2; exit 1 ;;
esac

printf '\n=== Incus + Web UI installer ===\n'
printf 'Incus: official Debian repository. Web UI: Zabbly package repository.\n'
printf 'API access: local Unix socket only. No test containers or VMs will be created.\n\n'
read -r -p 'Install now? [Y/n] ' answer || true
case "${answer,,}" in n|no) echo 'Cancelled.'; exit 0 ;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg
apt-get install -y incus

# Add Zabbly's signed Incus LTS repository for the web UI package.
install -d -m 0755 /etc/apt/keyrings
key_tmp="$(mktemp)"
trap 'rm -f "${key_tmp:-}"; rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
curl -fsSL https://pkgs.zabbly.com/key.asc -o "$key_tmp"
fingerprint="$(gpg --show-keys --with-colons "$key_tmp" | awk -F: '$1 == "fpr" { print $10; exit }')"
expected='4EFC590696CB15B87C73A3AD82CC8797C838DCFD'
if [[ "$fingerprint" != "$expected" ]]; then
  echo 'Zabbly signing-key fingerprint mismatch; refusing to add repository.' >&2
  exit 1
fi
install -m 0644 "$key_tmp" /etc/apt/keyrings/zabbly.asc
rm -f "$key_tmp"
trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

cat > /etc/apt/sources.list.d/zabbly-incus-lts.sources <<SOURCES
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-6.0
Suites: $VERSION_CODENAME
Components: main
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/zabbly.asc
SOURCES

# Default to Debian packages; prefer Zabbly only for the UI package.
cat > /etc/apt/preferences.d/incus-ui-zabbly <<'PREFERENCES'
Package: *
Pin: origin "pkgs.zabbly.com"
Pin-Priority: 1

Package: incus-ui-canonical
Pin: origin "pkgs.zabbly.com"
Pin-Priority: 1001
PREFERENCES

apt-get update

if ! command -v systemctl >/dev/null 2>&1 || [[ "$(ps -p 1 -o comm= | tr -d ' ')" != systemd ]]; then
  echo "Incus installed, but this host is not running systemd." >&2
  exit 1
fi

if systemctl cat incus.socket >/dev/null 2>&1; then
  systemctl enable --now incus.socket
else
  systemctl enable --now incus.service
fi
if systemctl cat incus-user.socket >/dev/null 2>&1; then
  systemctl enable --now incus-user.socket
fi

if ! incus admin waitready --timeout=30 >/dev/null 2>&1; then
  echo "Incus did not become ready. Check: systemctl status incus.socket incus.service" >&2
  exit 1
fi

# Initialize only if this is a fresh installation; never reset existing configuration.
if ! incus profile show default >/dev/null 2>&1; then
  incus admin init --minimal
fi

# Keep the API on the local Unix socket; clear any existing HTTPS listener.
incus config unset core.https_address 2>/dev/null || true

printf '\nChecking whether the UI can be installed without changing Incus...\n'
simulation="$(apt-get -s install --no-install-recommends incus-ui-canonical 2>&1)" || {
  printf '%s\n' "$simulation"
  echo "Could not resolve incus-ui-canonical dependencies; no UI package was installed." >&2
  exit 1
}
if grep -Eq '^(Remv|Inst) incus([ :]|$)' <<<"$simulation"; then
  printf '%s\n' "$simulation"
  echo "The UI would change/remove the existing Incus package. Aborting to preserve your Debian Incus installation." >&2
  exit 1
fi
apt-get install -y --no-install-recommends incus-ui-canonical

user="${SUDO_USER:-}"
if [[ -n "$user" && "$user" != root ]] && id "$user" >/dev/null 2>&1; then
  getent group incus-admin >/dev/null || groupadd incus-admin
  usermod -aG incus-admin "$user"
  printf '\nAdded %s to incus-admin; log out and back in for this to take effect.\n' "$user"
fi

printf '\nInstallation complete. No test instances were created.\n'
printf 'Incus version: '; incus version || true
printf '\nSocket services (where provided):\n'
systemctl --no-pager --full status incus.socket incus-user.socket 2>/dev/null || true
printf '\nAPI access: local Unix socket only; no HTTPS IP listener configured.\n'
printf 'Web UI endpoint (when supported by the installed package): https://127.0.0.1:8443/ui\n'
printf 'No listener is configured on 0.0.0.0.\n'
printf 'Docs: https://linuxcontainers.org/incus/docs/main/installing/\n'
