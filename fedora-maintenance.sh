#!/usr/bin/env bash
set -euo pipefail

# Fedora maintenance script
# - Updates (dnf + optional flatpak)
# - Cleanup (autoremove, clean cache, journal vacuum)
# - Reboot recommendation with reasons (kernel/core libs)

LOG_DIR="${HOME}/.logs/fedora-maintenance"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%F)_maintenance.log"

notify() {
  # notify-send is best-effort (won't fail script if missing)
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" || true
  fi
}

run() {
  echo -e "\n==> $*"
  "$@"
}

{
  echo "=== Fedora Maintenance: $(date) ==="

  # 1) DNF update
  notify "Fedora maintenance" "Starting updates…"
  run sudo dnf -y upgrade --refresh

  # 2) Flatpak update (if you use Flatpak)
  if command -v flatpak >/dev/null 2>&1; then
    run flatpak -y update || true
    run flatpak -y uninstall --unused || true
  fi

  # 3) Cleanup packages + cache
  run sudo dnf -y autoremove
  run sudo dnf clean all

  # 4) Journal cleanup (keep last 7 days)
  # Change 7d -> 14d, or use --vacuum-size=500M if you prefer.
  run sudo journalctl --vacuum-time=7d

  # 5) Reboot recommendation (with reasons)
  REBOOT_REASONS=()

  # Kernel check: compare running kernel to newest installed kernel package
  RUNNING_KERNEL="$(uname -r)"
  LATEST_KERNEL_PKG="$(rpm -q --last kernel 2>/dev/null | awk 'NR==1 {print $1}' || true)"

  if [[ -n "$LATEST_KERNEL_PKG" ]]; then
    LATEST_KERNEL="${LATEST_KERNEL_PKG#kernel-}"
    if [[ "$RUNNING_KERNEL" != "$LATEST_KERNEL" ]]; then
      REBOOT_REASONS+=("Kernel updated (running: $RUNNING_KERNEL, installed: $LATEST_KERNEL)")
    fi
  fi

  # needs-restarting check (glibc/systemd and other core libs)
  if command -v needs-restarting >/dev/null 2>&1; then
    if ! sudo needs-restarting -r >/dev/null 2>&1; then
      REBOOT_REASONS+=("Core system libraries updated (glibc/systemd/others)")
    fi
  else
    echo "Note: 'needs-restarting' not installed. Install with: sudo dnf install -y dnf-utils"
  fi

  if (( ${#REBOOT_REASONS[@]} > 0 )); then
    echo "Reboot recommended for:"
    for r in "${REBOOT_REASONS[@]}"; do
      echo " - $r"
    done

    # Notification (compact, readable)
    NOTIFY_BODY="$(printf '%s\n' "${REBOOT_REASONS[@]}")"
    notify "🔁 Reboot recommended" "$NOTIFY_BODY"
  else
    echo "No reboot required."
  fi

  notify "Fedora maintenance" "Done ✅"
  echo "=== Done: $(date) ==="
} | tee -a "$LOG_FILE"
