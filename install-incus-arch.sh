#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive Incus installer for Arch Linux x86_64.
# Installs Incus, the official Arch incus-ui package, and QEMU/KVM support.
# Existing Incus pools, networks, profiles, instances and host networking are
# never removed or recreated by this installer.
# No disks are formatted and no storage pools or test instances are created.

readonly SCRIPT_VERSION="2.1.2"
readonly SUBID_REQUIRED_COUNT=10000000
readonly SUBID_SEARCH_FIRST=1000000
readonly SUBID_SEARCH_LAST=590000000

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
    (( ${#items[@]} > 0 )) || die "No choices available for: $title"
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

is_safe_loopback_listener() {
    local address="$1" port

    # Deliberately accept only literal loopback IPs. Hostnames such as
    # localhost, wildcard addresses, and all other interface addresses fail.
    if [[ "$address" =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$address" =~ ^\[::1\]:([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
    else
        return 1
    fi

    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

is_root_subid_range_sufficient() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    awk -F: -v required="$SUBID_REQUIRED_COUNT" '
        NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && ($3 + 0) > 0 {
            range_start[NR] = $2 + 0
            range_end[NR] = ($2 + 0) + ($3 + 0) - 1
            if (($1 == "root" || $1 == "0") && ($3 + 0) >= required) {
                candidate[NR] = 1
            }
        }
        END {
            for (i in candidate) {
                conflict = 0
                for (j in range_start) {
                    if (i != j && range_start[i] <= range_end[j] &&
                        range_end[i] >= range_start[j]) {
                        conflict = 1
                        break
                    }
                }
                if (!conflict) {
                    found = 1
                    break
                }
            }
            exit(found ? 0 : 1)
        }
    ' "$file"
}

subid_range_is_free() {
    local file="$1" start="$2" end="$3"
    [[ -f "$file" ]] || return 0

    awk -F: -v wanted_start="$start" -v wanted_end="$end" '
        NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && ($3 + 0) > 0 {
            range_start = $2 + 0
            range_end = range_start + ($3 + 0) - 1
            if (wanted_start <= range_end && wanted_end >= range_start) {
                overlap = 1
            }
        }
        END { exit(overlap ? 1 : 0) }
    ' "$file"
}

root_subid_ranges_conflict() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    awk -F: '
        NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && ($3 + 0) > 0 {
            owner[NR] = $1
            range_start[NR] = $2 + 0
            range_end[NR] = ($2 + 0) + ($3 + 0) - 1
        }
        END {
            for (i in range_start) {
                if (owner[i] != "root" && owner[i] != "0") {
                    continue
                }
                for (j in range_start) {
                    if (i != j && range_start[i] <= range_end[j] &&
                        range_end[i] >= range_start[j]) {
                        conflict = 1
                        break
                    }
                }
                if (conflict) break
            }
            exit(conflict ? 0 : 1)
        }
    ' "$file"
}

find_free_subid_start() {
    local file="$1" start end next_start
    start="$SUBID_SEARCH_FIRST"

    while (( start <= SUBID_SEARCH_LAST )); do
        end=$((start + SUBID_REQUIRED_COUNT - 1))
        if subid_range_is_free "$file" "$start" "$end"; then
            printf '%s' "$start"
            return 0
        fi

        next_start="$(awk -F: -v wanted_start="$start" -v wanted_end="$end" '
            NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && ($3 + 0) > 0 {
                range_start = $2 + 0
                range_end = range_start + ($3 + 0) - 1
                if (wanted_start <= range_end && wanted_end >= range_start &&
                    range_end > furthest_end) {
                    furthest_end = range_end
                }
            }
            END { if (furthest_end > 0) print furthest_end + 1 }
        ' "$file")"
        if [[ -n "$next_start" ]] && (( next_start > start )); then
            start="$next_start"
        else
            start=$((start + 1))
        fi
    done

    return 1
}

root_subid_range_summary() {
    local file="$1"
    awk -F: -v required="$SUBID_REQUIRED_COUNT" '
        ($1 == "root" || $1 == "0") && $2 ~ /^[0-9]+$/ &&
        $3 ~ /^[0-9]+$/ && ($3 + 0) >= required {
            printf "%s-%s", $2, ($2 + 0) + ($3 + 0) - 1
            exit
        }
    ' "$file"
}

ensure_root_idmap() {
    local subid_source file start end
    local changed=0

    command -v usermod >/dev/null || die "usermod is unavailable; the shadow package is required."
    command -v newuidmap >/dev/null || die "newuidmap is missing after installing shadow."
    command -v newgidmap >/dev/null || die "newgidmap is missing after installing shadow."

    # Do not write local files when NSS is configured to use an external
    # subordinate-ID provider; usermod would not configure that provider.
    subid_source="$(awk '$1 == "subid:" { print $2; exit }' /etc/nsswitch.conf 2>/dev/null || true)"
    if [[ -n "$subid_source" && "$subid_source" != files ]]; then
        die "NSS subordinate-ID provider is '$subid_source', not 'files'. Configure root's UID/GID ranges with that provider; local files were not changed."
    fi

    for file in /etc/subuid /etc/subgid; do
        if [[ ! -e "$file" ]]; then
            install -m 0644 /dev/null "$file"
        fi
        [[ -f "$file" ]] || die "$file exists but is not a regular file; refusing to modify it."
        if root_subid_ranges_conflict "$file"; then
            die "Existing root subordinate-ID ranges overlap another allocation in $file. The installer will not rewrite existing mappings; resolve the conflict manually first."
        fi
    done

    if ! is_root_subid_range_sufficient /etc/subuid; then
        start="$(find_free_subid_start /etc/subuid)" ||
            die "Could not find a free contiguous 10-million UID range in /etc/subuid. No existing ranges were changed."
        end=$((start + SUBID_REQUIRED_COUNT - 1))
        log "Adding root subordinate UID range ${start}-${end}."
        usermod --add-subuids "${start}-${end}" root
        changed=1
    else
        info "Root subordinate UID range is already sufficient; preserving it."
    fi

    if ! is_root_subid_range_sufficient /etc/subgid; then
        start="$(find_free_subid_start /etc/subgid)" ||
            die "Could not find a free contiguous 10-million GID range in /etc/subgid. Existing ranges were preserved."
        end=$((start + SUBID_REQUIRED_COUNT - 1))
        log "Adding root subordinate GID range ${start}-${end}."
        usermod --add-subgids "${start}-${end}" root
        changed=1
    else
        info "Root subordinate GID range is already sufficient; preserving it."
    fi

    is_root_subid_range_sufficient /etc/subuid ||
        die "Root still has no contiguous subordinate UID range of at least 10 million IDs."
    is_root_subid_range_sufficient /etc/subgid ||
        die "Root still has no contiguous subordinate GID range of at least 10 million IDs."

    if (( changed )); then
        log "Root subordinate UID/GID mapping is configured."
        IDMAP_CHANGED=1
    else
        log "Root subordinate UID/GID mapping is already configured."
    fi
}

save_api_config_backup() {
    local old_value="$1" backup_dir backup_file
    [[ -n "$old_value" ]] || return 0

    backup_dir=/var/lib/incus-installer/backups
    install -d -m 0700 "$backup_dir"
    backup_file="$backup_dir/core-https-address-$(date +%Y%m%d-%H%M%S)-$$.txt"
    ( umask 077; printf 'core.https_address=%s\n' "$old_value" > "$backup_file" )
    chmod 0600 "$backup_file"
    printf '%s' "$backup_file"
}

restart_incus_and_wait() {
    systemctl restart incus.service
    incus info >/dev/null 2>&1 || die "Incus did not respond after restarting incus.service."
    IDMAP_RELOAD_REQUIRED=0
}

json_array_count() {
    jq -er 'if type == "array" then length else error("expected JSON array") end'
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "This installer is for Arch Linux."
[[ "$(uname -m)" == x86_64 ]] || die "This installer currently targets Arch Linux x86_64."
[[ -t 0 && -t 1 ]] || die "Interactive terminal required; run this script directly in a TTY."
command -v pacman >/dev/null || die "pacman is unavailable."
command -v systemctl >/dev/null || die "systemd is required."

IDMAP_CHANGED=0
IDMAP_RELOAD_REQUIRED=0
ACTIVATION_MODE="socket"

printf '\n============================================================\n'
printf '       INCUS + OFFICIAL UI + QEMU/KVM INSTALLER\n'
printf '                    version %s\n' "$SCRIPT_VERSION"
printf '============================================================\n'
printf '%s\n' \
    'This installer will:' \
    '  - Install/update Incus and the official Arch incus-ui package.' \
    '  - Configure root subordinate UID/GID ranges for unprivileged containers.' \
    '  - Use Incus systemd socket activation.' \
    '  - Install QEMU/KVM, UEFI firmware and virtual TPM support.' \
    '  - Optionally install Btrfs and LVM storage utilities.' \
    '  - Let YOU decide whether to run incus admin init.' \
    '  - Keep the Incus HTTPS API disabled or bound to literal loopback only.'
printf '\n%s\n' \
    'It will NOT format disks, create storage pools, create instances,' \
    'change host networking/firewall rules, or grant incus-admin silently.'
printf '\n'
ask_yes_no "Continue?" y || exit 0

# ---------------------------------------------------------------------------
# 2. Packages
# ---------------------------------------------------------------------------
BASE_PACKAGES=(incus incus-ui qemu-system-x86 edk2-ovmf cdrtools swtpm jq shadow iproute2 coreutils kmod)
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

for cmd in incus jq usermod newuidmap newgidmap ss; do
    command -v "$cmd" >/dev/null || die "Required command missing after package installation: $cmd"
done

pacman -Q incus incus-ui qemu-system-x86 edk2-ovmf cdrtools swtpm shadow iproute2 coreutils kmod
for pkg in "${STORAGE_PACKAGES[@]}"; do pacman -Q "$pkg"; done

# Verify the UI using the installed package manifest, not a guessed path.
UI_INDEX="$(pacman -Ql incus-ui | awk '$2 ~ /^\/usr\/share\/incus-ui\/index\.html$/ { print $2; exit }')"
[[ -n "$UI_INDEX" && -s "$UI_INDEX" ]] ||
    die "incus-ui is installed but its index.html was not found in the package manifest."
UI_DIR="$(dirname "$UI_INDEX")"
[[ -d "$UI_DIR/assets" ]] || die "Incus UI assets directory is missing: $UI_DIR/assets"
if ! incus webui --help >/dev/null 2>&1; then
    die "The installed Incus CLI does not expose the 'incus webui' command."
fi
log "Incus UI package files and CLI command verified."

# ---------------------------------------------------------------------------
# 3. Root subordinate UID/GID mappings
# ---------------------------------------------------------------------------
ensure_root_idmap

# ---------------------------------------------------------------------------
# 4. systemd socket activation
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl cat incus.socket >/dev/null 2>&1 || die "incus.socket unit is missing."

# Use either socket activation or direct service activation, never both as
# independently enabled boot paths. Switching an already-running direct
# service can interrupt workloads, so require an explicit decision.
SERVICE_WAS_ACTIVE=0
SOCKET_WAS_ACTIVE=0
systemctl is-active --quiet incus.service && SERVICE_WAS_ACTIVE=1 || true
systemctl is-active --quiet incus.socket && SOCKET_WAS_ACTIVE=1 || true
SERVICE_ENABLE_STATE="$(systemctl is-enabled incus.service 2>/dev/null || true)"

if (( SERVICE_WAS_ACTIVE == 1 && SOCKET_WAS_ACTIVE == 0 )); then
    warn "Incus is currently running without socket activation. Switching now requires stopping and starting the daemon and may interrupt running workloads."
    if ask_yes_no "Switch the active Incus installation to incus.socket now?" n; then
        case "$SERVICE_ENABLE_STATE" in
            enabled|enabled-runtime|linked|linked-runtime) systemctl disable incus.service ;;
        esac
        systemctl stop incus.service
        systemctl enable --now incus.socket
        ACTIVATION_MODE=socket
        SERVICE_WAS_ACTIVE=0
    else
        ACTIVATION_MODE=service
        info "Preserving the currently active incus.service activation mode. No service/socket transition was made."
    fi
else
    case "$SERVICE_ENABLE_STATE" in
        enabled|enabled-runtime|linked|linked-runtime)
            systemctl disable incus.service
            info "Disabled standalone incus.service boot enablement; incus.socket is the activation unit."
            ;;
    esac
    systemctl enable --now incus.socket
    ACTIVATION_MODE=socket
fi

if (( IDMAP_CHANGED == 1 && SERVICE_WAS_ACTIVE == 1 )); then
    warn "The daemon was already running when subordinate-ID mappings changed. A restart is needed for Incus to reload them and may interrupt running workloads."
    if ask_yes_no "Restart Incus now to apply the new UID/GID mappings?" n; then
        systemctl restart incus.service
        IDMAP_RELOAD_REQUIRED=0
    else
        IDMAP_RELOAD_REQUIRED=1
        warn "UID/GID files are updated, but the running daemon has not reloaded them yet."
    fi
fi

incus info >/dev/null 2>&1 || die "Incus daemon is not responding through the local Unix socket."
if [[ "$ACTIVATION_MODE" == socket ]]; then
    systemctl is-active --quiet incus.socket || die "incus.socket is not active."
    log "Incus daemon is responding through systemd socket activation."
else
    systemctl is-active --quiet incus.service || die "Existing incus.service activation is not active."
    log "Existing direct incus.service activation was preserved."
fi

# ---------------------------------------------------------------------------
# 5. Incus initialization: always a separate explicit decision
# ---------------------------------------------------------------------------
STORAGE_JSON="$(incus storage list --format json)"
NETWORK_JSON="$(incus network list --format json)"
PROFILE_JSON="$(incus profile list --format json)"
STORAGE_COUNT="$(printf '%s' "$STORAGE_JSON" | json_array_count)"
NETWORK_COUNT="$(printf '%s' "$NETWORK_JSON" | json_array_count)"
PROFILE_COUNT="$(printf '%s' "$PROFILE_JSON" | json_array_count)"

printf '\nCurrent Incus state:\n'
printf '  Storage pools: %s\n  Networks: %s\n  Profiles: %s\n\n' \
    "$STORAGE_COUNT" "$NETWORK_COUNT" "$PROFILE_COUNT"

if ask_yes_no "Run Incus initialization wizard now?" n; then
    incus admin init
    log "Incus initialization wizard finished."
else
    info "Skipped Incus initialization."
fi

# Refresh state; no pool/network/profile is created or modified by this script.
STORAGE_JSON="$(incus storage list --format json)"
NETWORK_JSON="$(incus network list --format json)"
PROFILE_JSON="$(incus profile list --format json)"
STORAGE_COUNT="$(printf '%s' "$STORAGE_JSON" | json_array_count)"
NETWORK_COUNT="$(printf '%s' "$NETWORK_JSON" | json_array_count)"
PROFILE_COUNT="$(printf '%s' "$PROFILE_JSON" | json_array_count)"

if (( STORAGE_COUNT == 0 )); then
    log "No storage pools configured; this is allowed."
else
    log "Found $STORAGE_COUNT existing storage pool(s); none were modified by the installer."
fi

# ---------------------------------------------------------------------------
# 6. QEMU/KVM packages
# ---------------------------------------------------------------------------
# qemu-system-x86, edk2-ovmf, cdrtools and swtpm were installed by pacman
# above. Do not launch QEMU, probe /dev/kvm, load modules, or alter boot
# module configuration here. Hardware acceleration is host-dependent.
log "QEMU/KVM, OVMF and virtual TPM packages are installed."

# ---------------------------------------------------------------------------
# 7. UI/API mode and strict listener validation
# ---------------------------------------------------------------------------
CURRENT_API="$(incus config get core.https_address 2>/dev/null || true)"
printf '\nIncus UI access modes:\n'
printf '  1) On-demand: incus webui (no persistent HTTPS API listener)\n'
printf '  2) Persistent HTTPS bound only to 127.0.0.1:8443\n\n'

UI_CHOICE="$(choose_item "Choose UI access mode:" \
    "On-demand incus webui (no persistent HTTPS listener)" \
    "Persistent localhost HTTPS (127.0.0.1:8443)")"

case "$UI_CHOICE" in
    "On-demand incus webui (no persistent HTTPS listener)")
        if [[ -n "$CURRENT_API" ]]; then
            if is_safe_loopback_listener "$CURRENT_API"; then
                info "Current API listener is loopback-only: $CURRENT_API"
            else
                warn "Current API listener is not an explicitly accepted loopback address: $CURRENT_API"
            fi
            ask_yes_no "Remove the existing core.https_address setting?" n ||
                die "Existing API setting was preserved. Re-run and choose persistent localhost HTTPS, or explicitly approve removing it."
            API_BACKUP="$(save_api_config_backup "$CURRENT_API")"
            incus config unset core.https_address
            restart_incus_and_wait
            [[ -z "$API_BACKUP" ]] || info "Previous API setting backed up to $API_BACKUP"
        fi
        UI_MODE=ondemand
        ;;
    "Persistent localhost HTTPS (127.0.0.1:8443)")
        if [[ "$CURRENT_API" != "127.0.0.1:8443" ]]; then
            if [[ -n "$CURRENT_API" ]]; then
                if is_safe_loopback_listener "$CURRENT_API"; then
                    info "Current API listener is loopback-only but differs from the selected address: $CURRENT_API"
                else
                    warn "Current API listener is not an explicitly accepted loopback address: $CURRENT_API"
                fi
                ask_yes_no "Replace the existing core.https_address with 127.0.0.1:8443?" n ||
                    die "Existing API setting was preserved. Re-run to choose another mode or approve this change."
                API_BACKUP="$(save_api_config_backup "$CURRENT_API")"
            else
                API_BACKUP=""
            fi
            incus config set core.https_address=127.0.0.1:8443
            restart_incus_and_wait
            [[ -z "$API_BACKUP" ]] || info "Previous API setting backed up to $API_BACKUP"
        fi
        UI_MODE=persistent
        ;;
    *) die "Invalid UI access mode." ;;
esac

FINAL_API="$(incus config get core.https_address 2>/dev/null || true)"
if [[ -n "$FINAL_API" ]] && ! is_safe_loopback_listener "$FINAL_API"; then
    die "Security check failed: core.https_address is not a literal loopback listener: $FINAL_API"
fi

if [[ "$UI_MODE" == ondemand ]]; then
    [[ -z "$FINAL_API" ]] || die "On-demand mode selected, but core.https_address is still configured: $FINAL_API"
else
    [[ "$FINAL_API" == "127.0.0.1:8443" ]] ||
        die "Persistent UI mode requires core.https_address=127.0.0.1:8443; found: ${FINAL_API:-disabled}"

    LISTENER_READY=0
    for _ in {1..10}; do
        incus info >/dev/null 2>&1 || true
        if ss -H -ltn | awk '$4 == "127.0.0.1:8443" { found = 1 } END { exit(found ? 0 : 1) }'; then
            LISTENER_READY=1
            break
        fi
        sleep 1
    done
    (( LISTENER_READY == 1 )) ||
        die "Incus is configured for 127.0.0.1:8443 but no matching TCP listener appeared."
    log "HTTPS listener verified on 127.0.0.1:8443 only."
fi

# ---------------------------------------------------------------------------
# 8. Explicit opt-in for root-equivalent administration
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 9. Final independent verification
# ---------------------------------------------------------------------------
if [[ "$ACTIVATION_MODE" == socket ]]; then
    systemctl is-active --quiet incus.socket || die "incus.socket is not active."
else
    systemctl is-active --quiet incus.service || die "incus.service is not active."
fi
incus info >/dev/null 2>&1 || die "Incus daemon verification failed."
[[ -s "$UI_INDEX" && -d "$UI_DIR/assets" ]] || die "Incus UI files failed final verification."
incus webui --help >/dev/null 2>&1 || die "Incus webui command failed final verification."
is_root_subid_range_sufficient /etc/subuid || die "Root subordinate UID range verification failed."
is_root_subid_range_sufficient /etc/subgid || die "Root subordinate GID range verification failed."

printf '\n============================================================\n'
printf '                 INSTALLATION COMPLETE\n'
printf '============================================================\n'
printf 'Installer version:   %s\n' "$SCRIPT_VERSION"
printf 'Incus version:       '; incus version | sed -n '1p'
printf 'Incus UI package:    '; pacman -Q incus-ui | awk '{print $2}'
printf 'UI index:            %s\n' "$UI_INDEX"
printf 'Root subuid:         %s\n' "$(root_subid_range_summary /etc/subuid)"
printf 'Root subgid:         %s\n' "$(root_subid_range_summary /etc/subgid)"
printf 'Storage pools:       %s (installer created none)\n' "$STORAGE_COUNT"
printf 'Networks:            %s\n' "$NETWORK_COUNT"
printf 'Profiles:            %s\n' "$PROFILE_COUNT"
printf 'QEMU/KVM packages:   installed (no runtime probe)\n'
printf 'API listener:        %s\n' "${FINAL_API:-disabled}"
printf 'UI mode:             %s\n' "$UI_MODE"
printf 'Daemon activation:   %s\n' "$ACTIVATION_MODE"
if (( IDMAP_RELOAD_REQUIRED == 1 )); then
    printf '%s\n' 'ID map reload:        pending (restart incus.service before creating unprivileged instances)'
else
    printf '%s\n' 'ID map reload:        verified/reloaded'
fi
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
printf '%s\n' 'VM hardware acceleration depends on host virtualization support and /dev/kvm.'
printf '%s\n' 'QEMU, edk2-ovmf, cdrtools and swtpm are installed as packages only.'
printf '%s\n' 'No QEMU process, test instance, image, or storage pool was created.'
'
printf '%s\n' '============================================================'