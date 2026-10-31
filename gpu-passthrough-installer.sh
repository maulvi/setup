#!/usr/bin/env bash
set -Eeuo pipefail

# Dynamic libvirt GPU passthrough installer for Arch/CachyOS.
# Mode 1: single GPU (stop display service while guest runs).
# Mode 2: multi GPU (leave host/display GPU and desktop untouched).

HOOK_ROOT=/etc/libvirt/hooks
HOOK_FILE=99-gpu-passthrough.sh
BACKUP_ROOT=/etc/libvirt/hooks/backup-gpu-passthrough

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
for cmd in lspci virsh modprobe systemctl readlink; do
  command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
virsh uri >/dev/null 2>&1 || die "Cannot connect to libvirt."

mapfile -t GPU_LINES < <(lspci -Dnn | grep -E 'VGA compatible controller|3D controller|Display controller' || true)
(("\${#GPU_LINES[@]}" > 0)) || die "No display-class PCI devices found."
GPU_BDFS=()
for line in "\${GPU_LINES[@]}"; do GPU_BDFS+=("\${line%% *}"); done

printf '\n=== Dynamic GPU passthrough installer ===\n'
printf 'Detected display devices:\n'
for i in "\${!GPU_LINES[@]}"; do printf '  %d) %s\n' "$((i+1))" "\${GPU_LINES[$i]}"; done

while :; do
  read -rp $'\nMode: 1) Single-GPU  2) Multi-GPU [1/2]: ' choice
  case "$choice" in
    1) MODE=single; break ;;
    2) (("\${#GPU_BDFS[@]}" >= 2)) || { warn "Need at least two GPUs for multi-GPU mode."; continue; }; MODE=multi; break ;;
    *) warn "Choose 1 or 2." ;;
  esac
done

select_gpu() {
  local prompt="$1" exclude="\${2:-}" idx
  local -a options=()
  printf '\n%s\n' "$prompt"
  for idx in "\${!GPU_LINES[@]}"; do
    [[ "\${GPU_BDFS[$idx]}" == "$exclude" ]] && continue
    options+=("$idx")
    printf '  %d) %s\n' "\${#options[@]}" "\${GPU_LINES[$idx]}"
  done
  (("\${#options[@]}" > 0)) || die "No GPU available for selection."
  while :; do
    read -rp 'Select number: ' n
    [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=\${#options[@]})) || { warn "Invalid selection."; continue; }
    SELECTED_BDF="\${GPU_BDFS[\${options[$((n-1))]}]}"
    return
  done
}

HOST_BDF=
if [[ "$MODE" == multi ]]; then
  select_gpu "Select host/display GPU (stays with CachyOS):"
  HOST_BDF="$SELECTED_BDF"
  HOST_DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$HOST_BDF/driver" 2>/dev/null || true)")"
  [[ -n "$HOST_DRIVER" && "$HOST_DRIVER" != vfio-pci ]] || die "Host GPU has no active non-VFIO driver."
  select_gpu "Select GPU to pass through:" "$HOST_BDF"
  TARGET_BDF="$SELECTED_BDF"
else
  select_gpu "Select GPU to pass through:"
  TARGET_BDF="$SELECTED_BDF"
fi

read -rp 'VM domain name [win10]: ' VM_NAME
VM_NAME="\${VM_NAME:-win10}"
virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM '$VM_NAME' not found."

DRIVER_PATH="$(readlink -f "/sys/bus/pci/devices/$TARGET_BDF/driver" 2>/dev/null || true)"
[[ -n "$DRIVER_PATH" ]] || die "Selected GPU has no active host driver."
DRIVER="\${DRIVER_PATH##*/}"
[[ "$DRIVER" != vfio-pci ]] || die "Selected GPU is already bound to vfio-pci."
MODULE_PATH="$(readlink -f "/sys/bus/pci/devices/$TARGET_BDF/driver/module" 2>/dev/null || true)"
MODULE="\${MODULE_PATH##*/}"
[[ -n "$MODULE" ]] || MODULE="$DRIVER"

SLOT="\${TARGET_BDF%.*}"
mapfile -t FUNCTIONS < <(lspci -Dnn | awk -v p="$SLOT." 'index($1,p)==1 {print $1}')
(("\${#FUNCTIONS[@]}" > 0)) || die "Could not enumerate PCI functions for GPU slot."

for fn in "\${FUNCTIONS[@]}"; do
  group="/sys/bus/pci/devices/$fn/iommu_group/devices"
  [[ -d "$group" ]] || die "No IOMMU group for $fn; enable IOMMU and reboot."
  for dev in "$group"/*; do
    [[ -e "$dev" ]] || continue
    other="\${dev##*/}"
    [[ "\${other%.*}" == "$SLOT" ]] || { lspci -nn -s "$other"; die "IOMMU group contains a device outside the selected GPU slot."; }
  done
done

case "$MODULE" in
  nvidia) UNLOAD=(nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia); LOAD=(nvidia nvidia_modeset nvidia_uvm nvidia_drm) ;;
  *) UNLOAD=("$MODULE"); LOAD=("$MODULE") ;;
esac

DISPLAY_SERVICE=
if [[ "$MODE" == single ]]; then
  for unit in display-manager.service ly@tty0.service gdm.service sddm.service lightdm.service; do
    if systemctl is-active --quiet "$unit"; then DISPLAY_SERVICE="$unit"; break; fi
  done
  if [[ -z "$DISPLAY_SERVICE" ]]; then read -rp 'Display service to stop/restore: ' DISPLAY_SERVICE
  else read -rp "Display service [$DISPLAY_SERVICE]: " override; DISPLAY_SERVICE="\${override:-$DISPLAY_SERVICE}"; fi
  [[ -n "$DISPLAY_SERVICE" ]] || die "Display service is required in single-GPU mode."
  systemctl cat "$DISPLAY_SERVICE" >/dev/null 2>&1 || die "Unknown service: $DISPLAY_SERVICE"
fi

printf '\nMode: %s\nVM: %s\nPassthrough GPU: %s (%s)\nPCI functions: %s\n' "$MODE" "$VM_NAME" "$TARGET_BDF" "$DRIVER" "\${FUNCTIONS[*]}"
if [[ "$MODE" == multi ]]; then
  printf 'Host/display GPU: %s (%s)\nLy/XFCE: will remain running\n' "$HOST_BDF" "$HOST_DRIVER"
else
  printf 'Display service: %s (stopped only while VM runs)\n' "$DISPLAY_SERVICE"
fi
read -rp 'Install hooks? [y/N]: ' confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }

VM_DIR="$HOOK_ROOT/qemu.d/$VM_NAME"
PREP="$VM_DIR/prepare/begin"
REL="$VM_DIR/release/end"
mkdir -p "$PREP" "$REL"

if [[ ! -e "$HOOK_ROOT/qemu" ]]; then
  cat > "$HOOK_ROOT/qemu" <<'DISPATCH'
#!/usr/bin/env bash
set -e
GUEST="$1"; HOOK="$2"; STATE="$3"
PATH_HOOK="$(dirname "$0")/qemu.d/$GUEST/$HOOK/$STATE"
if [[ -f "$PATH_HOOK" ]]; then exec "$PATH_HOOK" "$@"
elif [[ -d "$PATH_HOOK" ]]; then
  while IFS= read -r f; do [[ -x "$f" ]] && "$f" "$@"; done < <(find -L "$PATH_HOOK" -maxdepth 1 -type f -executable | sort)
fi
DISPATCH
  chmod 755 "$HOOK_ROOT/qemu"
else
  grep -q qemu.d "$HOOK_ROOT/qemu" || die "Existing qemu dispatcher is not qemu.d-compatible; refusing to overwrite."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP"
for old in "$PREP"/* "$REL"/*; do
  [[ -f "$old" ]] || continue
  if [[ "\${old##*/}" == "$HOOK_FILE" ]] || grep -Eq 'nodedev-(detach|reattach)|vfio-pci|modprobe -r|vtconsole|efi-framebuffer' "$old"; then
    cp -a "$old" "$BACKUP/"
    rm -f "$old"
    warn "Backed up previous GPU hook: \${old##*/}"
  fi
done

NODES=()
for fn in "\${FUNCTIONS[@]}"; do NODES+=("pci_\${fn//[:.]/_}"); done

{
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
  printf 'MODE=%q\nVM_NAME=%q\nDISPLAY_SERVICE=%q\nDRIVER=%q\n' "$MODE" "$VM_NAME" "$DISPLAY_SERVICE" "$MODULE"
  printf 'NODES=( '; printf '%q ' "\${NODES[@]}"; printf ')\n'
  printf 'FUNCTIONS=( '; printf '%q ' "\${FUNCTIONS[@]}"; printf ')\n'
  printf 'UNLOAD=( '; printf '%q ' "\${UNLOAD[@]}"; printf ')\n'
  cat <<'START'
RUN="/run/gpu-passthrough-$VM_NAME"
DETACHED=()
rollback() {
  rc=$?
  trap - ERR
  for ((i=\${#DETACHED[@]}-1;i>=0;i--)); do virsh nodedev-reattach "\${DETACHED[$i]}" || true; done
  modprobe "$DRIVER" 2>/dev/null || true
  if [[ "$MODE" == single && -e "$RUN.display" ]]; then systemctl start "$DISPLAY_SERVICE" || true; rm -f "$RUN.display"; fi
  exit "$rc"
}
trap rollback ERR

if [[ "$MODE" == single ]]; then
  if systemctl is-active --quiet "$DISPLAY_SERVICE"; then touch "$RUN.display"; systemctl stop "$DISPLAY_SERVICE"; fi
  : > "$RUN.vt"
  for vt in /sys/class/vtconsole/vtcon*; do
    [[ -w "$vt/bind" && "$(cat "$vt/bind")" == 1 ]] || continue
    echo "$vt" >> "$RUN.vt"; echo 0 > "$vt/bind"
  done
  if [[ -w /sys/bus/platform/drivers/efi-framebuffer/unbind && -e /sys/bus/platform/devices/efi-framebuffer.0/driver ]]; then
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind; touch "$RUN.fb"
  fi
fi

# Keep a shared module loaded if another PCI device (e.g. host GPU) uses it.
SHARED=0
for path in /sys/bus/pci/devices/*; do
  [[ -e "$path" ]] || continue
  bdf="\${path##*/}"; selected=0
  for fn in "\${FUNCTIONS[@]}"; do [[ "$bdf" == "$fn" ]] && selected=1 && break; done
  ((selected)) && continue
  modpath="$(readlink -f "$path/driver/module" 2>/dev/null || true)"
  [[ "\${modpath##*/}" == "$DRIVER" ]] && SHARED=1
done
if ((SHARED==0)); then
  for module in "\${UNLOAD[@]}"; do [[ -d "/sys/module/$module" ]] && modprobe -r "$module"; done
fi

modprobe vfio-pci
for node in "\${NODES[@]}"; do virsh nodedev-detach "$node" --driver vfio-pci; DETACHED+=("$node"); done
trap - ERR
START
} > "$PREP/$HOOK_FILE"

{
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
  printf 'MODE=%q\nVM_NAME=%q\nDISPLAY_SERVICE=%q\nDRIVER=%q\n' "$MODE" "$VM_NAME" "$DISPLAY_SERVICE" "$MODULE"
  printf 'NODES=( '; printf '%q ' "\${NODES[@]}"; printf ')\n'
  printf 'LOAD=( '; printf '%q ' "\${LOAD[@]}"; printf ')\n'
  cat <<'STOP'
RUN="/run/gpu-passthrough-$VM_NAME"
STATUS=0
for node in "\${NODES[@]}"; do virsh nodedev-reattach "$node" || STATUS=1; done
if [[ ! -d "/sys/module/$DRIVER" ]]; then for module in "\${LOAD[@]}"; do modprobe "$module" || STATUS=1; done; fi
if [[ "$MODE" == single ]]; then
  if [[ -e "$RUN.fb" ]]; then echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind || STATUS=1; rm -f "$RUN.fb"; fi
  if [[ -e "$RUN.vt" ]]; then while IFS= read -r vt; do [[ -w "$vt/bind" ]] && echo 1 > "$vt/bind" || STATUS=1; done < "$RUN.vt"; rm -f "$RUN.vt"; fi
  if [[ -e "$RUN.display" ]]; then systemctl start "$DISPLAY_SERVICE" || STATUS=1; rm -f "$RUN.display"; fi
fi
exit "$STATUS"
STOP
} > "$REL/$HOOK_FILE"

chmod 755 "$PREP/$HOOK_FILE" "$REL/$HOOK_FILE"
info "Installed hooks for VM $VM_NAME."
printf 'Mode: %s\nGPU: %s\n' "$MODE" "$TARGET_BDF"
[[ "$MODE" == multi ]] && printf 'Host GPU: %s (desktop and Ly remain running)\n' "$HOST_BDF" || printf 'Display service: %s\n' "$DISPLAY_SERVICE"
printf 'Prepare hook: %s\nRelease hook: %s\nBackup: %s\n' "$PREP/$HOOK_FILE" "$REL/$HOOK_FILE" "$BACKUP"
warn "Add every selected GPU PCI function (including audio) to VM Hardware > PCI Device. This script only installs host hooks."
warn "Review existing VM hooks before use; no permanent VFIO binding or boot config is changed."
