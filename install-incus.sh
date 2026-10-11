#!/usr/bin/env bash
# Install Incus from Debian's own repository and the community Hye Ararat UI.
# No third-party Incus package repositories. Never creates test instances.
set -Eeuo pipefail

trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_CODENAME:-}" != trixie ]]; then
  echo "This installer requires Debian 13 (trixie), which provides native Incus packages." >&2
  echo "No Zabbly or other third-party Incus apt repository will be added." >&2
  exit 1
fi

if [[ "$(dpkg --print-architecture)" != amd64 && "$(dpkg --print-architecture)" != arm64 ]]; then
  echo "Supported architectures: amd64 and arm64." >&2
  exit 1
fi

printf '\n=== Incus + Hye Ararat UI installer ===\n'
printf 'Source: Debian 13 official repository (Incus) + Hye Ararat GitHub release (UI)\n'
printf 'Includes full VM dependencies. No test containers or VMs will be created.\n\n'
read -r -p 'Install now? [Y/n] ' answer || true
case "${answer,,}" in n|no) echo 'Cancelled.'; exit 0 ;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl tar incus

if ! command -v systemctl >/dev/null 2>&1 || [[ "$(ps -p 1 -o comm= | tr -d ' ')" != systemd ]]; then
  echo "Incus installed, but this host is not running systemd." >&2
  exit 1
fi

# Download the prebuilt Hye Ararat UI; this is a community beta, not an official Incus UI.
ui_tmp="$(mktemp -d)"
trap 'rm -rf "${ui_tmp:-}"; rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
curl -fL --retry 3 https://github.com/hyecompany/ararat-web/releases/latest/download/ararat.tar.gz -o "$ui_tmp/ararat.tar.gz"
tar -tzf "$ui_tmp/ararat.tar.gz" >/dev/null
install -d -m 0755 /opt/incus/ui
tar -xzf "$ui_tmp/ararat.tar.gz" -C /opt/incus/ui
rm -rf "$ui_tmp"
trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

# Use the UI path supported by Incus when it is not bundled by the OS package.
install -d -m 0755 /etc/systemd/system/incus.service.d
cat > /etc/systemd/system/incus.service.d/ui.conf <<'UNIT'
[Service]
Environment=INCUS_UI=/opt/incus/ui
UNIT
systemctl daemon-reload

# Enable the packaged daemon. Enable socket units too if this package provides them.
if systemctl cat incus.socket >/dev/null 2>&1; then
  systemctl enable --now incus.socket
fi
if systemctl cat incus-user.socket >/dev/null 2>&1; then
  systemctl enable --now incus-user.socket
fi
systemctl enable --now incus.service
systemctl restart incus.service

# Initialize only when no default profile exists; do not reset existing configuration.
if incus admin waitready --timeout=30 >/dev/null 2>&1; then
  if ! incus profile show default >/dev/null 2>&1; then
    incus admin init --minimal
  fi
  incus config set core.https_address ':8443'
else
  echo "Incus did not become ready. Run: sudo incus admin init" >&2
  exit 1
fi

# Grant the invoking non-root user administrative access.
user="${SUDO_USER:-}"
if [[ -n "$user" && "$user" != root ]] && id "$user" >/dev/null 2>&1; then
  getent group incus-admin >/dev/null || groupadd incus-admin
  usermod -aG incus-admin "$user"
  printf '\nAdded %s to incus-admin; log out and back in for this to take effect.\n' "$user"
fi

printf '\nInstallation complete. No test instances were created.\n'
printf 'Incus version: '; incus version || true
printf '\nDaemon service:\n'
systemctl --no-pager --full status incus.service 2>/dev/null || true
printf '\nUI: https://<server-ip>:8443\n'
printf 'Restrict TCP/8443 with your firewall and configure trusted client certificates before remote use.\n'
printf 'Incus install docs: https://linuxcontainers.org/incus/docs/main/installing/\n'
printf 'UI project (community beta): https://github.com/hyecompany/ararat-web\n'
