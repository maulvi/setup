#!/usr/bin/env bash
# Clean Incus + Web UI installer for Debian 12/13.
# Uses Zabbly's Incus LTS packages and systemd socket activation.
set -Eeuo pipefail

trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != debian || ! "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]]; then
  echo "Supported systems: Debian 12 (bookworm) and Debian 13 (trixie)." >&2
  exit 1
fi

CODENAME="$VERSION_CODENAME"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) echo "Unsupported architecture for this installer: $ARCH" >&2; exit 1 ;; esac

printf '\n=== Incus LTS + Web UI installer ===\n'
printf 'OS: Debian %s (%s), architecture: %s\n' "${VERSION_ID:-?}" "$CODENAME" "$ARCH"
printf 'Installs full Incus VM support and incus-ui-canonical.\n'
printf 'Enables systemd socket activation. Does not create test instances.\n\n'
read -r -p 'Install now? [Y/n] ' answer || true
case "${answer,,}" in n|no) echo 'Cancelled.'; exit 0 ;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg

install -d -m 0755 /etc/apt/keyrings
key_tmp="$(mktemp)"
trap 'rm -f "${key_tmp:-}"; rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
curl -fsSL https://pkgs.zabbly.com/key.asc -o "$key_tmp"
fingerprint="$(gpg --show-keys --with-colons "$key_tmp" | awk -F: '$1 == "fpr" { print $10; exit }')"
expected='4EFC590696CB15B87C73A3AD82CC8797C838DCFD'
if [[ "$fingerprint" != "$expected" ]]; then
  echo 'Zabbly signing-key fingerprint mismatch; refusing to install.' >&2
  exit 1
fi
install -m 0644 "$key_tmp" /etc/apt/keyrings/zabbly.asc
rm -f "$key_tmp"
trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

cat > /etc/apt/sources.list.d/zabbly-incus-lts.sources <<SOURCES
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-7.0
Suites: $CODENAME
Components: main
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/zabbly.asc
SOURCES

apt-get update
# incus (not incus-base) installs container and virtual-machine dependencies.
apt-get install -y incus incus-ui-canonical

if ! command -v systemctl >/dev/null 2>&1 || [[ "$(ps -p 1 -o comm= | tr -d ' ')" != systemd ]]; then
  echo 'Incus is installed, but systemd socket activation is unavailable on this host.' >&2
  exit 1
fi

# Prefer socket activation; do not independently enable the daemon service.
for unit in incus.socket incus-user.socket; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    systemctl enable --now "$unit"
  fi
done

# Initialize only if this is a fresh installation; never reset existing configuration.
if ! incus admin waitready --timeout=15 >/dev/null 2>&1; then
  systemctl start incus.socket 2>/dev/null || true
  incus admin waitready --timeout=15 >/dev/null 2>&1 || true
fi
if incus admin waitready --timeout=5 >/dev/null 2>&1; then
  if ! incus profile show default >/dev/null 2>&1; then
    incus admin init --minimal
  fi
  # Bind the UI/API listener to all host interfaces. Restrict access with your firewall.
  incus config set core.https_address ':8443'
else
  echo 'Incus is installed and socket units are enabled, but the daemon is not ready.' >&2
  echo 'Run: sudo incus admin init' >&2
fi

# Grant the invoking non-root user admin access, if applicable.
user="${SUDO_USER:-}"
if [[ -n "$user" && "$user" != root ]] && id "$user" >/dev/null 2>&1; then
  getent group incus-admin >/dev/null || groupadd incus-admin
  usermod -aG incus-admin "$user"
  printf '\nAdded %s to incus-admin; log out and back in for this to take effect.\n' "$user"
fi

printf '\nInstallation complete. No test containers or VMs were created.\n'
printf 'Incus version: '; incus version || true
printf '\nSocket units:\n'
systemctl --no-pager --full status incus.socket incus-user.socket 2>/dev/null || true
printf '\nWeb UI/API: https://<server-ip>:8443\n'
printf 'Before remote use, configure trusted certificates/passwords and restrict TCP/8443 in your firewall.\n'
printf 'Docs: https://linuxcontainers.org/incus/docs/main/\n'
