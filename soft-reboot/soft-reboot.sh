#!/usr/bin/env bash
# Replicates common reboot "cleanup" effects without rebooting.
# Run as root: sudo ./soft-reboot.sh
set -Eeuo pipefail

LOG_FILE="/var/log/soft-reboot.log"
TMP_AGE_DAYS="${TMP_AGE_DAYS:-7}"       # stale /tmp files older than N days are removed
COMPACT_SWAP="${COMPACT_SWAP:-auto}"    # auto|yes|no — auto only compacts if swap > 20% used
DROP_CACHES="${DROP_CACHES:-1}"         # 1=page cache, 2=dentries+inodes, 3=all (1 is safest)
NOTIFY_USER="${NOTIFY_USER:-}"

say()  { printf '%s\n' "$1"; }
log()  { echo "[$(date -Is)] $1" >>"$LOG_FILE"; }
step() { say "-- $1"; log "STEP: $1"; }
ok()   { say "   OK"; log "OK: ${CURRENT_STEP:-}"; }
warn() { say "   WARN: $1"; log "WARN: $1"; }

CURRENT_STEP=""

command_exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { say "Run as root: sudo $0"; exit 1; }
}

notify_user() {
  [[ -n "$NOTIFY_USER" ]] || return 0
  local uid runtime bus
  uid="$(id -u "$NOTIFY_USER" 2>/dev/null)" || return 0
  runtime="/run/user/${uid}"
  bus="${runtime}/bus"
  [[ -S "$bus" ]] || return 0
  XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
    runuser -u "$NOTIFY_USER" -- notify-send -u low -t 8000 -i system-run \
      "Soft reboot" "$1" 2>/dev/null || true
}

# 1. Flush filesystem buffers so nothing is stuck in memory
flush_buffers() {
  CURRENT_STEP="Flush filesystem buffers"
  step "$CURRENT_STEP"
  sync
  ok
}

# 2. Drop page/dentry/inode caches
drop_caches() {
  CURRENT_STEP="Drop kernel caches (level ${DROP_CACHES})"
  step "$CURRENT_STEP"
  echo "$DROP_CACHES" > /proc/sys/vm/drop_caches
  ok
}

# 3. Compact swap — move swap pages back to RAM and reset swap
compact_swap() {
  CURRENT_STEP="Compact swap"
  step "$CURRENT_STEP"

  local swap_total swap_used pct
  swap_total=$(free -m | awk '/Swap:/ {print $2}')
  swap_used=$(free -m  | awk '/Swap:/ {print $3}')

  if [[ "$swap_total" -eq 0 ]]; then
    say "   SKIP (no swap configured)"
    log "No swap configured; skipping."
    return 0
  fi

  pct=$(( swap_used * 100 / swap_total ))
  log "Swap: ${swap_used}MB used / ${swap_total}MB total (${pct}%)"

  local should_compact=false
  case "$COMPACT_SWAP" in
    yes)  should_compact=true ;;
    no)   should_compact=false ;;
    auto) [[ "$pct" -gt 20 ]] && should_compact=true ;;
  esac

  if ! $should_compact; then
    say "   SKIP (swap usage ${pct}% — below threshold or disabled)"
    log "Swap compaction skipped (pct=${pct}%, mode=${COMPACT_SWAP})"
    return 0
  fi

  say "   Swap is ${pct}% used — compacting (swapoff + swapon)"
  log "Compacting swap: swapoff -a"
  if swapoff -a >>"$LOG_FILE" 2>&1 && swapon -a >>"$LOG_FILE" 2>&1; then
    ok
  else
    warn "swapoff/swapon failed — swap may be in use by locked pages"
  fi
}

# 4. Restart services running stale binaries after package updates
restart_stale_services() {
  CURRENT_STEP="Restart services with stale binaries"
  step "$CURRENT_STEP"

  local needs_cmd=""
  command_exists needs-restarting    && needs_cmd="needs-restarting"
  command_exists dnf                 && needs_cmd="dnf needs-restarting"
  [[ -x /usr/bin/needs-restarting ]] && needs_cmd="/usr/bin/needs-restarting"

  if [[ -z "$needs_cmd" ]]; then
    warn "needs-restarting not found. Install: sudo dnf install -y dnf-utils"
    return 0
  fi

  local stale_services
  stale_services="$($needs_cmd -s 2>/dev/null | grep -v '^#' | sort -u || true)"

  if [[ -z "$stale_services" ]]; then
    say "   OK (no stale services found)"
    log "No stale services to restart."
    return 0
  fi

  say "   Found stale services:"
  printf '%s\n' "$stale_services" | while read -r svc; do
    [[ -z "$svc" ]] && continue
    say "   -> restarting $svc"
    if systemctl restart "$svc" >>"$LOG_FILE" 2>&1; then
      log "Restarted: $svc"
    else
      warn "Failed to restart $svc (may not be a systemd unit)"
    fi
  done
}

# 5. Reset and report failed systemd units
handle_failed_units() {
  CURRENT_STEP="Failed systemd units"
  step "$CURRENT_STEP"

  local failed
  failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)"

  if [[ -z "$failed" ]]; then
    say "   OK (no failed units)"
    log "No failed systemd units."
    return 0
  fi

  say "   Failed units found:"
  printf '%s\n' "$failed" | while read -r unit; do
    [[ -z "$unit" ]] && continue
    say "   -> $unit"
    log "Failed unit: $unit"
  done

  systemctl reset-failed >>"$LOG_FILE" 2>&1 || true
  say "   Reset-failed cleared. Review logs if these are recurring."
  log "systemctl reset-failed executed"
}

# 6. Reload systemd daemon (picks up changed unit files)
reload_systemd() {
  CURRENT_STEP="Reload systemd daemon"
  step "$CURRENT_STEP"
  systemctl daemon-reload >>"$LOG_FILE" 2>&1
  ok
}

# 7. Clean stale /tmp files
clean_tmp() {
  CURRENT_STEP="Clean stale /tmp (older than ${TMP_AGE_DAYS} days)"
  step "$CURRENT_STEP"
  local count
  count=$(find /tmp -mindepth 1 -maxdepth 1 -atime "+${TMP_AGE_DAYS}" 2>/dev/null | wc -l)
  if [[ "$count" -eq 0 ]]; then
    say "   OK (nothing stale)"
    log "No stale /tmp files to remove."
    return 0
  fi
  find /tmp -mindepth 1 -maxdepth 1 -atime "+${TMP_AGE_DAYS}" -exec rm -rf {} + 2>/dev/null || true
  say "   Removed ${count} stale /tmp entr(ies)"
  log "Removed ${count} stale /tmp entries (atime > ${TMP_AGE_DAYS}d)"
}

# 8. Check if a real reboot is still needed (kernel update pending, etc.)
reboot_still_needed() {
  CURRENT_STEP="Reboot still required?"
  step "$CURRENT_STEP"

  local needs_cmd=""
  command_exists needs-restarting    && needs_cmd="needs-restarting"
  [[ -x /usr/bin/needs-restarting ]] && needs_cmd="/usr/bin/needs-restarting"

  if [[ -z "$needs_cmd" ]]; then
    say "   UNKNOWN (needs-restarting not available)"
    return 0
  fi

  local rc
  $needs_cmd -r >/dev/null 2>&1 && rc=$? || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    say "   YES — a kernel or core library update requires a real reboot."
    say "   Tip: 'systemctl soft-reboot' restarts userspace without kernel reload (Fedora 39+)."
    log "Reboot still required (needs-restarting -r)"
    notify_user "Soft reboot done — but a real reboot is still recommended (kernel update pending)."
  else
    say "   NO — no reboot required."
    log "No reboot required."
    notify_user "Soft reboot complete. No reboot needed."
  fi
}

main() {
  need_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  say "=== Soft Reboot ==="
  log "========== START =========="
  log "Host: $(hostname) | Kernel: $(uname -r)"

  flush_buffers
  drop_caches
  compact_swap
  restart_stale_services
  handle_failed_units
  reload_systemd
  clean_tmp
  reboot_still_needed

  say "=== Done. Log: $LOG_FILE ==="
  log "========== END =========="
}

main "$@"
