#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive Incus installer for Arch Linux x86_64.
# Installs Incus, the official Arch incus-ui package, and QEMU/KVM support.
# Storage pools and networks are intentionally left to the user / Incus init wizard.
# No disks are formatted, no pools are created, and no public API listener is enabled.

readonly SCRIPT_VERSION="2.0.0"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

ask_yes_no() {
    local prompt="$1" default="${2:-n}" answer
    while true; do
        if [[ "$default" == y ]]; then
            read -r -p "$prompt [Y/n]: " answer || die "Input closed."
        else
            read -r -p "$prompt [y/N]: " answer || die "Input closed."
        fi
        answer="${answer,,}"
        [[ -z "$answer" ]] && answer="$default"
        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) printf 'Enter y or n.\n' >&2 ;;
        esac
    done
}

ask_value() {
    local prompt="$1" default="$2" value
    read -r -p "$prompt [$default]: " value || die "Input closed."
    printf '%s' "${value:-$default}"
}

choose_item() {
    local title="$1"; shift
    local -a items=("$@")
    local i choice
    (("${#items[@]}" > 0)) || die "No choices available for: $title"
    printf '\n%s\n' "$title" >&2
    for i in "${!items[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${items[$i]}" >&2
    done
    while true; do
        read -r -p "Choose [1-${#items[@]}]: " choice || die "Input closed."
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            printf '%s' "${items[$((choice - 1))]}"
            return 0
        fi
        printf 'Invalid choice.\n' >&2
    done
}

is_loopback_listener() {
    case "$1" in
        127.0.0.1:*|localhost:*|'[::1]':*|'::1':*) return 0 ;;
        *) return 1 ;;
    esac
}

# 1. Preflight
[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "This installer is for Arch Linux."
[[ "$(uname -m)" == x86_64 ]] || die "This installer currently targets Arch Linux x86_64."
[[ -t 0 && -t 1 ]] || die "Interactive terminal required; run this script directly in a TTY."
command -v pacman >/dev/null || die "pacman is unavailable."
command -v systemctl >/dev/null || die "systemd is required."

printf '\n============================================================\n'
printf '       INCUS + OFFICIAL UI + QEMU/KVM INSTALLER\n'
printf '                    version %s\n' "$SCRIPT_VERSION"
printf '============================================================\n'
printf '%s\n' \
    'This installer will:' \
    '  - Install Incus and the official Arch incus-ui package.' \
    '  - Install QEMU/KVM, UEFI firmware and virtual TPM support.' \
    '  - Optionally install Btrfs and LVM storage utilities.' \
    '  - Let YOU decide whether to run incus admin init.' \
    '  - Let YOU decide whether to create any storage pools.' \
    '  - Keep the Incus API off public interfaces.'
printf '\n%s\n' \
    'It will NOT format disks, create storage pools, create instances,' \
    'change host networking/firewall rules, or grant incus-admin silently.'
printf '\n'
ask_yes_no "Continue?" y || exit 0

# 2. Packages
BASE_PACKAGES=(incus incus-ui qemu-system-x86 edk2-ovmf cdrtools swtpm jq)
STORAGE_PACKAGES=()

printf '\nOptional local storage driver utilities:\n'
printf '  - Btrfs: btrfs-progs\n'
printf '  - LVM:   lvm2 + thin-provisioning-tools\n'
printf '  - dir:   built into Incus; no extra package\n'
printf '  - ZFS:   requires a compatible ZFS kernel module and utilities\n'
printf '  - Ceph:  requires a separately configured Ceph cluster\n\n'

if ask_yes_no "Install Btrfs and LVM utilities now?" y; then
    STORAGE_PACKAGES+=(btrfs-progs lvm2 thin-provisioning-tools)
fi

ask_yes_no "Run pacman full system upgrade and install selected packages?" y ||
    die "Package installation cancelled."
pacman -Syu --needed "${BASE_PACKAGES[@]}" "${STORAGE_PACKAGES[@]}"

for cmd in incus qemu-system-x86_64 jq; do
    command -v "$cmd" >/dev/null || die "Required command missing after package installation: $cmd"
done

pacman -Q incus incus-ui qemu-system-x86 edk2-ovmf cdrtools swtpm
for pkg in "${STORAGE_PACKAGES[@]}"; do pacman -Q "$pkg"; done

# Verify the UI from the package manifest; do not guess its installation path.
UI_INDEX="$(pacman -Ql incus-ui | awk '$2 ~ /^\/usr\/share\/incus-ui\/index\.html$/ {print $2; exit}')"
[[ -n "$UI_INDEX" && -s "$UI_INDEX" ]] ||
    die "incus-ui is installed but its index.html was not found in the package file list."
UI_DIR="$(dirname "$UI_INDEX")"
[[ -d "$UI_DIR/assets" ]] || warn "UI assets directory not found at $UI_DIR/assets."
log "Official Incus UI verified: $UI_INDEX"

# 3. systemd
systemctl daemon-reload
systemctl cat incus.socket >/dev/null 2>&1 || die "incus.socket unit is missing."
systemctl enable --now incus.socket

if ask_yes_no "Enable incus.service at boot? (recommended for instance autostart)" y; then
    systemctl enable incus.service
fi

incus info >/dev/null 2>&1 || die "Incus daemon is not responding through the local Unix socket."
log "Incus daemon is responding locally."

# 4. Optional initialization. A zero-pool result is valid.
STORAGE_JSON="$(incus storage list --format json)"
NETWORK_JSON="$(incus network list --format json)"
PROFILE_JSON="$(incus profile list --format json)"
STORAGE_COUNT="$(jq 'length' <<<"$STORAGE_JSON")"
NETWORK_COUNT="$(jq 'length' <<<"$NETWORK_JSON")"
PROFILE_COUNT="$(jq 'length' <<<"$PROFILE_JSON")"

printf '\nCurrent Incus state:\n'
printf '  Storage pools: %s\n  Networks: %s\n  Profiles: %s\n\n' \
    "$STORAGE_COUNT" "$NETWORK_COUNT" "$PROFILE_COUNT"

if (( STORAGE_COUNT == 0 && NETWORK_COUNT == 0 && PROFILE_COUNT <= 1 )); then
    INIT_DEFAULT=y
else
    INIT_DEFAULT=n
    warn "Existing Incus configuration detected. The init wizard may reconfigure it."
fi

if ask_yes_no "Run Incus interactive initialization now? (you choose storage, bridge and clustering)" "$INIT_DEFAULT"; then
    printf '\nThe Incus wizard is yours to control:\n'
    printf '%s\n' \
        '  - You may create a storage pool or answer NO.' \
        '  - You may create a managed bridge or skip it.' \
        '  - Keep network API access disabled for local-only exposure.' \
        '  - Finishing with zero storage pools is completely valid.'
    incus admin init
    log "Incus initialization wizard finished."
else
    info "Skipped initialization. You can run: incus admin init"
fi

# Refresh state; do not require any storage pool.
STORAGE_JSON="$(incus storage list --format json)"
NETWORK_JSON="$(incus network list --format json)"
PROFILE_JSON="$(incus profile list --format json)"
STORAGE_COUNT="$(jq 'length' <<<"$STORAGE_JSON")"
NETWORK_COUNT="$(jq 'length' <<<"$NETWORK_JSON")"
PROFILE_COUNT="$(jq 'length' <<<"$PROFILE_JSON")"

if (( STORAGE_COUNT == 0 )); then
    log "No storage pools configured; this is allowed."
else
    log "Found $STORAGE_COUNT existing storage pool(s); none were modified."
fi

# 5. QEMU/KVM
CPU_VENDOR="$(awk -F ': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
modprobe kvm 2>/dev/null || true
KVM_MODULE=""
case "$CPU_VENDOR" in
    GenuineIntel) KVM_MODULE=kvm_intel; modprobe "$KVM_MODULE" 2>/dev/null || true ;;
    AuthenticAMD) KVM_MODULE=kvm_amd; modprobe "$KVM_MODULE" 2>/dev/null || true ;;
esac

if [[ -c /dev/kvm ]]; then
    log "/dev/kvm is present; KVM acceleration is available."
    if [[ -n "$KVM_MODULE" ]] && ask_yes_no "Persist $KVM_MODULE across boots?" y; then
        MODULE_FILE=/etc/modules-load.d/incus-kvm.conf
        if [[ -e "$MODULE_FILE" ]]; then
            warn "$MODULE_FILE already exists; not overwriting."
        else
            printf 'kvm\n%s\n' "$KVM_MODULE" > "$MODULE_FILE"
            chmod 0644 "$MODULE_FILE"
        fi
    fi
else
    warn "/dev/kvm is unavailable. VM support is installed, but hardware acceleration is not ready. Check BIOS VT-x/AMD-V and nested virtualization."
fi

OVMF_CODE=""
for candidate in \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    if [[ -s "$candidate" ]]; then OVMF_CODE="$candidate"; break; fi
done
[[ -n "$OVMF_CODE" ]] || warn "OVMF firmware file not found in common Arch paths; inspect pacman -Ql edk2-ovmf."
command -v swtpm >/dev/null || warn "swtpm is unavailable; virtual TPM support may be unavailable."

# 6. UI/API exposure
CURRENT_API="$(incus config get core.https_address 2>/dev/null || true)"
printf '\nIncus UI access modes:\n'
printf '  1) On-demand: incus webui (no persistent listener)\n'
printf '  2) Persistent HTTPS bound only to 127.0.0.1:8443\n\n'

UI_CHOICE="$(choose_item "Choose UI access mode:" \
    "On-demand incus webui (no persistent HTTPS listener)" \
    "Persistent localhost HTTPS (127.0.0.1:8443)")"

case "$UI_CHOICE" in
    "On-demand incus webui (no persistent HTTPS listener)")
        if [[ -n "$CURRENT_API" ]]; then
            if ! is_loopback_listener "$CURRENT_API"; then
                warn "Existing API listener is not loopback-only: $CURRENT_API"
            fi
            ask_yes_no "Remove the existing HTTPS API listener and use on-demand UI only?" y ||
                die "Approve removing the existing listener or choose persistent localhost HTTPS."
            incus config unset core.https_address
            systemctl restart incus.service
        fi
        UI_MODE=ondemand
        ;;
    "Persistent localhost HTTPS (127.0.0.1:8443)")
        if [[ "$CURRENT_API" != "127.0.0.1:8443" ]]; then
            if [[ -n "$CURRENT_API" ]] && ! is_loopback_listener "$CURRENT_API"; then
                warn "Replacing existing non-loopback API listener: $CURRENT_API"
            fi
            incus config set core.https_address=127.0.0.1:8443
            systemctl restart incus.service
        fi
        UI_MODE=persistent
        ;;
    *) die "Invalid UI access mode." ;;
esac

FINAL_API="$(incus config get core.https_address 2>/dev/null || true)"
if [[ -n "$FINAL_API" ]] && ! is_loopback_listener "$FINAL_API"; then
    die "Security check failed: API is listening on a non-loopback address: $FINAL_API"
fi

# 7. Explicit opt-in for root-equivalent administration.
TARGET_USER="${SUDO_USER:-}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    printf '\nDetected invoking user: %s\n' "$TARGET_USER"
    warn "incus-admin grants effectively root-equivalent control over the host."
    if ask_yes_no "Add $TARGET_USER to incus-admin?" n; then
        getent group incus-admin >/dev/null || die "incus-admin group does not exist."
        usermod -aG incus-admin "$TARGET_USER"
        log "Added $TARGET_USER to incus-admin; a new login session is required."
    else
        log "No administrative group membership granted."
    fi
fi

# 8. Final verification
systemctl is-active --quiet incus.socket || die "incus.socket is not active."
incus info >/dev/null 2>&1 || die "Incus daemon verification failed."
[[ -s "$UI_INDEX" ]] || die "Incus UI index file is missing."
command -v qemu-system-x86_64 >/dev/null || die "QEMU binary is missing."

printf '\n============================================================\n'
printf '                 INSTALLATION COMPLETE\n'
printf '============================================================\n'
printf 'Incus version:       '; incus version | head -n1
printf 'Incus UI package:    '; pacman -Q incus-ui | awk '{print $2}'
printf 'UI index:            %s\n' "$UI_INDEX"
printf 'Storage pools:       %s (installer created none)\n' "$STORAGE_COUNT"
printf 'Networks:            %s\n' "$NETWORK_COUNT"
printf 'Profiles:            %s\n' "$PROFILE_COUNT"
printf 'QEMU:                %s\n' "$(qemu-system-x86_64 --version | head -n1)"
printf 'KVM:                 %s\n' "$( [[ -c /dev/kvm ]] && printf available || printf unavailable )"
printf 'OVMF:                %s\n' "${OVMF_CODE:-not detected}"
printf 'API listener:        %s\n' "${FINAL_API:-disabled}"
printf 'UI mode:             %s\n' "$UI_MODE"
printf '\n'
printf '%s\n' \
    'Storage support:' \
    '  dir:   built into Incus' \
    '  btrfs: btrfs-progs (optional)' \
    '  lvm:   lvm2 + thin-provisioning-tools (optional)' \
    '  zfs:   compatible ZFS kernel module + utilities required' \
    '  ceph:  separately configured Ceph cluster required' \
    'No storage pool is required to keep Incus and its UI installed.'
printf '\n'
if [[ "$UI_MODE" == ondemand ]]; then
    printf '%s\n' 'Start UI when needed: incus webui'
else
    printf '%s\n' 'Open locally: https://127.0.0.1:8443'
    printf '%s\n' 'Remote access: ssh -L 8443:127.0.0.1:8443 USER@SERVER'
fi
printf '\n'
printf '%s\n' \
    'VMs require /dev/kvm for hardware acceleration.' \
    'Do not use Btrfs storage pools for VM root disks; Incus documents qgroup/write-amplification risks.' \
    'No test instances or images were created.'
printf '%s\n' '============================================================'
