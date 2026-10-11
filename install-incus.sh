#!/usr/bin/env bash
# Install Incus from Debian's native repository and the community Hye Ararat UI.
# No third-party Incus apt repository. No network API listener. No test instances.
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
printf 'Incus source: Debian official repository. No IP/network API listener will be configured.\n'
printf 'Local Unix-socket access only; no test containers or VMs will be created.\n\n'
read -r -p 'Install now? [Y/n] ' answer || true
case "${answer,,}" in n|no) echo 'Cancelled.'; exit 0 ;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl tar incus

if ! command -v systemctl >/dev/null 2>&1 || [[ "$(ps -p 1 -o comm= | tr -d ' ')" != systemd ]]; then
  echo "Incus installed, but this host is not running systemd." >&2
  exit 1
fi

# Install the community UI assets. The UI is served by Incus; without an HTTPS
# listener it will not be directly reachable from a browser, by design.
ui_tmp="$(mktemp -d)"
trap 'rm -rf "${ui_tmp:-}"; rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
curl -fL --retry 3 https://github.com/hyecompany/ararat-web/releases/latest/download/ararat.tar.gz -o "$ui_tmp/ararat.tar.gz"
tar -tzf "$ui_tmp/ararat.tar.gz" >/dev/null
install -d -m 0755 /opt/incus/ui
tar -xzf "$ui_tmp/ararat.tar.gz" -C /opt/incus/ui
rm -rf "$ui_tmp"
trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

install -d -m 0755 /etc/systemd/system/incus.service.d
cat > /etc/systemd/system/incus.service.d/ui.conf <<'UNIT'
[Service]
Environment=INCUS_UI=/opt/incus/ui
UNIT
systemctl daemon-reload

# Prefer systemd socket activation. Do not enable incus.service separately
# when the package provides incus.socket.
if systemctl cat incus.socket >/dev/null 2>&1; then
  systemctl enable --now incus.socket
else
  systemctl enable incus.service
fi
if systemctl cat incus-user.socket >/dev/null 2>&1; then
  systemctl enable --now incus-user.socket
fi

# Trigger local Unix-socket activation and initialize only if needed.
if ! incus admin waitready --timeout=30 >/dev/null 2>&1; then
  echo "Incus did not become ready. Check: systemctl status incus.socket incus.service" >&2
  exit 1
fi
if ! incus profile show default >/dev/null 2>&1; then
  incus admin init --minimal
fi

# Explicitly clear any existing network listener so the API remains Unix-socket only.
incus config unset core.https_address 2>/dev/null || true

user="${SUDO_USER:-}"
if [[ -n "$user" && "$user" != root ]] && id "$user" >/dev/null 2>&1; then
  getent group incus-admin >/dev/null || groupadd incus-admin
  usermod -aG incus-admin "$user"
  printf '\nAdded %s to incus-admin; log out and back in for this to take effect.\n' "$user"
fi

printf '\nInstallation complete. No test instances were created.\n'
printf 'Incus version: '; incus version || true
printf '\nSocket units (where provided):\n'
systemctl --no-pager --full status incus.socket incus-user.socket 2>/dev/null || true
printf '\nIncus API: local Unix socket only; no TCP/8443 listener configured.\n'
printf 'Note: the installed UI cannot be opened directly in a browser until you provide a local-only proxy/tunnel.\n'
printf 'Incus docs: https://linuxcontainers.org/incus/docs/main/installing/\n'
printf 'Community UI: https://github.com/hyecompany/ararat-web\n'
