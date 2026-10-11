#!/usr/bin/env bash
# Install Incus from Debian's native repository.
# Local Unix-socket API only. No third-party Incus/UI repositories. No test instances.
set -Eeuo pipefail

trap 'rc=$?; printf "\n[ERROR] Failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_CODENAME:-}" != trixie ]]; then
  echo "This installer requires Debian 13 (trixie), which provides native Incus packages." >&2
  echo "No third-party package repositories will be added." >&2
  exit 1
fi

case "$(dpkg --print-architecture)" in
  amd64|arm64) ;;
  *) echo "Supported architectures: amd64 and arm64." >&2; exit 1 ;;
esac

printf '\n=== Incus installer ===\n'
printf 'Source: official Debian 13 repository. No third-party UI or Incus packages.\n'
printf 'API access: local Unix socket only. No test containers or VMs will be created.\n\n'
read -r -p 'Install now? [Y/n] ' answer || true
case "${answer,,}" in n|no) echo 'Cancelled.'; exit 0 ;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y incus

if ! command -v systemctl >/dev/null 2>&1 || [[ "$(ps -p 1 -o comm= | tr -d ' ')" != systemd ]]; then
  echo "Incus installed, but this host is not running systemd." >&2
  exit 1
fi

# Use socket activation when supplied by the Debian package.
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
printf '\nAPI: local Unix socket only. No IP/TCP listener configured.\n'
printf 'Note: Debian’s incus package does not install a separate browser UI. A browser UI cannot bind directly to a Unix socket; use a local-only proxy/tunnel if needed.\n'
printf 'Official installation docs: https://linuxcontainers.org/incus/docs/main/installing/\n'
