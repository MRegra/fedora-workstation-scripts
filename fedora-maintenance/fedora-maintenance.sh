#!/usr/bin/env bash
# Modes accepted by main(); scripts/test-smoke.sh checks README ExecStart lines against it.
# smoke-modes: daily monthly major extended
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_FILE="/var/log/fedora-maintenance.log"
KEEP_KERNELS="${KEEP_KERNELS:-3}"   # override: KEEP_KERNELS=2 ./fedora-maintenance.sh monthly
LOG_DAYS="${LOG_DAYS:-30}"          # keep rotated logs for N days (0 disables cleanup)
JOURNAL_DAYS="${JOURNAL_DAYS:-7}"   # journal retention in days (0 disables cleanup)
NOTIFY_USER="${NOTIFY_USER:-}"      # desktop notification target username (optional)

# extended mode only (opt-in, each independently toggleable: default off so
# `extended` without overrides stays a dry documented no-op for these two steps):
UPDATE_PIP="${UPDATE_PIP:-0}"        # 1 = upgrade bug-bounty-agent's pip --user deps
UPDATE_OLLAMA="${UPDATE_OLLAMA:-0}"  # 1 = re-pull every locally installed Ollama model
# user whose `pip install --user` environment to upgrade (pip runs as root
# otherwise, installing into /root instead of the desktop account). Falls
# back to NOTIFY_USER since on this single-user workstation it's the same
# account; override explicitly if that ever changes.
MAINTENANCE_USER="${MAINTENANCE_USER:-${NOTIFY_USER:-}}"

CURRENT_STEP=""
MODE=""

log() {
  local msg="$1"
  echo "[$(date -Is)] $msg" >>"$LOG_FILE"
}

say() {
  printf '%s\n' "$1"
}

step() {
  CURRENT_STEP="$1"
  say "- $CURRENT_STEP"
  log "STEP: $CURRENT_STEP"
}

ok() {
  say "  OK"
  log "STEP OK: $CURRENT_STEP"
}

die() {
  say "  ERROR: $1"
  log "ERROR: $1"
  exit 1
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root: sudo $0 ${*:-}"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

notify_user() {
  local status="$1"
  local message="$2"

  [[ -n "$NOTIFY_USER" ]] || { log "notification skipped: NOTIFY_USER not set"; return 0; }
  if command_exists notify-send; then
    :
  elif [[ -x /usr/bin/notify-send ]]; then
    :
  else
    log "notify-send not found; skipping notification"
    return 0
  fi

  local uid runtime bus urgency notify_cmd display wayland
  uid="$(id -u "$NOTIFY_USER" 2>/dev/null)" || { log "notify user not found: $NOTIFY_USER"; return 0; }
  runtime="/run/user/${uid}"
  bus="${runtime}/bus"
  [[ -S "$bus" ]] || { log "no user bus for notifications at ${bus}"; return 0; }

  urgency="low"
  [[ "$status" == "fail" ]] && urgency="critical"
  notify_cmd="$(command -v notify-send || true)"
  [[ -n "$notify_cmd" ]] || notify_cmd="/usr/bin/notify-send"
  display="${DISPLAY:-:0}"
  [[ -S "${runtime}/wayland-0" ]] && wayland="wayland-0"

  local icon timeout
  icon="system-software-update"
  timeout="10000"

  if XDG_RUNTIME_DIR="$runtime" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
    DISPLAY="$display" \
    WAYLAND_DISPLAY="$wayland" \
    runuser -u "$NOTIFY_USER" -- "$notify_cmd" -u "$urgency" -t "$timeout" -i "$icon" \
      -a "Fedora Maintenance" \
      "Fedora maintenance" "$message"; then
    log "notification sent to ${NOTIFY_USER}: ${message}"
  else
    if XDG_RUNTIME_DIR="$runtime" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
      DISPLAY="$display" \
      WAYLAND_DISPLAY="$wayland" \
      sudo --preserve-env=DBUS_SESSION_BUS_ADDRESS,XDG_RUNTIME_DIR,DISPLAY,WAYLAND_DISPLAY \
        -u "$NOTIFY_USER" "$notify_cmd" -u "$urgency" -t "$timeout" -i "$icon" \
          -a "Fedora Maintenance" \
          "Fedora maintenance" "$message"; then
      log "notification sent to ${NOTIFY_USER}: ${message}"
    else
      log "notification failed for ${NOTIFY_USER}: ${message}"
    fi
  fi
}

on_exit() {
  local rc="$?"
  if [[ "$rc" -eq 0 ]]; then
    notify_user "ok" "Completed (${MODE})"
  else
    notify_user "fail" "Failed (${MODE}) - see ${LOG_FILE}"
  fi
}

run_cmd_required() {
  local desc="$1"
  shift
  step "$desc"
  if "$@" >>"$LOG_FILE" 2>&1; then
    ok
  else
    say "  FAILED (see log: $LOG_FILE)"
    log "FAILED: $desc | cmd: $*"
    return 1
  fi
}

run_cmd_optional() {
  local desc="$1"
  shift
  step "$desc"
  if "$@" >>"$LOG_FILE" 2>&1; then
    ok
  else
    say "  WARN (see log: $LOG_FILE)"
    log "WARN: $desc | cmd: $*"
    return 0
  fi
}

dnf_update_daily() {
  run_cmd_required "DNF upgrade (refresh)" dnf -y upgrade --refresh
}

flatpak_update() {
  if command_exists flatpak; then
    run_cmd_optional "Flatpak update" flatpak -y update
    run_cmd_optional "Flatpak uninstall unused" flatpak -y uninstall --unused
  else
    step "Flatpak maintenance"
    say "  SKIP (flatpak not found)"
    log "flatpak not found; skipping flatpak maintenance"
  fi
}

firmware_update_monthly() {
  if command_exists fwupdmgr; then
    run_cmd_optional "Firmware refresh" fwupdmgr refresh --force
    run_cmd_optional "Firmware list updates" fwupdmgr get-updates

    # If no updates are available, fwupdmgr exits non-zero sometimes; don't fail the whole script.
    run_cmd_optional "Firmware apply updates" fwupdmgr -y update
  else
    step "Firmware updates"
    say "  SKIP (fwupdmgr not found)"
    log "fwupdmgr not found; skipping firmware updates. (Install with: sudo dnf install -y fwupd)"
  fi
}

pip_update_extended() {
  if [[ "$UPDATE_PIP" != "1" ]]; then
    step "Pip update (bug-bounty-agent)"
    say "  SKIP (disabled; set UPDATE_PIP=1 to enable)"
    log "pip update skipped: UPDATE_PIP not 1"
    return 0
  fi

  local req_file="${REPO_ROOT}/bug-bounty-agent/requirements.txt"
  if [[ ! -f "$req_file" ]]; then
    step "Pip update (bug-bounty-agent)"
    say "  SKIP (requirements.txt not found: $req_file)"
    log "bug-bounty-agent/requirements.txt not found at ${req_file}; skipping pip update"
    return 0
  fi

  if ! command_exists pip3; then
    step "Pip update (bug-bounty-agent)"
    say "  SKIP (pip3 not found)"
    log "pip3 not found; skipping pip update"
    return 0
  fi

  if [[ -z "$MAINTENANCE_USER" ]]; then
    step "Pip update (bug-bounty-agent)"
    say "  SKIP (MAINTENANCE_USER/NOTIFY_USER not set)"
    log "MAINTENANCE_USER and NOTIFY_USER both unset; skipping pip update (would otherwise install into /root's pip --user site)"
    return 0
  fi

  if ! id "$MAINTENANCE_USER" >/dev/null 2>&1; then
    step "Pip update (bug-bounty-agent)"
    say "  SKIP (user not found: $MAINTENANCE_USER)"
    log "MAINTENANCE_USER '${MAINTENANCE_USER}' not found; skipping pip update"
    return 0
  fi

  run_cmd_optional "Pip update (bug-bounty-agent, user: ${MAINTENANCE_USER})" \
    runuser -u "$MAINTENANCE_USER" -- pip3 install --user --upgrade -r "$req_file"
}

ollama_update_extended() {
  if [[ "$UPDATE_OLLAMA" != "1" ]]; then
    step "Ollama model update (local-ai-agent)"
    say "  SKIP (disabled; set UPDATE_OLLAMA=1 to enable)"
    log "ollama model update skipped: UPDATE_OLLAMA not 1"
    return 0
  fi

  if ! command_exists ollama; then
    step "Ollama model update (local-ai-agent)"
    say "  SKIP (ollama not found)"
    log "ollama not found; skipping model update"
    return 0
  fi

  # `ollama pull` talks to the local daemon's API; it doesn't matter which
  # user runs the CLI, so this can run as root like the other steps.
  local models
  models="$(ollama list 2>>"$LOG_FILE" | awk 'NR>1 && NF{print $1}')" || models=""
  if [[ -z "$models" ]]; then
    step "Ollama model update (local-ai-agent)"
    say "  SKIP (no local models installed)"
    log "no ollama models found via 'ollama list'; skipping model update"
    return 0
  fi

  local model
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    run_cmd_optional "Pull latest Ollama model: ${model}" ollama pull "$model"
  done <<<"$models"
}

cleanup_system() {
  run_cmd_optional "DNF autoremove" dnf -y autoremove
  run_cmd_optional "DNF clean all" dnf -y clean all

  # Optional: clear user cache for root (harmless)
  run_cmd_optional "Clean root cache" rm -rf /root/.cache/* 2>/dev/null

  if [[ "$JOURNAL_DAYS" -gt 0 ]] && command_exists journalctl; then
    run_cmd_optional "Journal cleanup (keep ${JOURNAL_DAYS}d)" \
      journalctl --vacuum-time="${JOURNAL_DAYS}d"
  else
    step "Journal cleanup"
    say "  SKIP (disabled or journalctl not found)"
    log "journal cleanup skipped"
  fi

  # Remove old kernels (keep last N) safely using repoquery if available
  if command_exists dnf; then
    step "Prune old kernels (keep ${KEEP_KERNELS})"
    local output rc old_kernels
    output="$(dnf -q repoquery --installonly --latest-limit="-${KEEP_KERNELS}" \
      kernel kernel-core kernel-modules kernel-modules-extra 2>&1)"
    rc="$?"
    printf '%s\n' "$output" >>"$LOG_FILE"
    if [[ "$rc" -ne 0 ]]; then
      say "  WARN (repoquery failed; see log: $LOG_FILE)"
      log "WARN: repoquery failed for old-kernel pruning"
    else
      old_kernels="$(printf '%s\n' "$output" | awk 'NF{print $1}')"
      if [[ -z "$old_kernels" ]]; then
        say "  OK (nothing to remove)"
        log "No old kernels to remove"
      else
        # shellcheck disable=SC2086  # intentional word splitting: a space/newline
        # separated list of kernel package names must expand to multiple args.
        if dnf -y remove $old_kernels >>"$LOG_FILE" 2>&1; then
          ok
        else
          say "  WARN (see log: $LOG_FILE)"
          log "WARN: Failed removing old kernels"
        fi
      fi
    fi
  else
    step "Prune old kernels"
    say "  SKIP (dnf not found)"
    log "dnf not found; skipping old-kernel pruning."
  fi
}

maybe_reboot_hint() {
  # We won't force reboot automatically, but we'll detect if it's likely needed.
  local needs_cmd=""
  if command_exists needs-restarting; then
    needs_cmd="needs-restarting"
  elif [[ -x /usr/bin/needs-restarting ]]; then
    needs_cmd="/usr/bin/needs-restarting"
  elif [[ -x /usr/sbin/needs-restarting ]]; then
    needs_cmd="/usr/sbin/needs-restarting"
  elif command_exists dnf; then
    needs_cmd="dnf needs-restarting"
  elif command_exists dnf5; then
    needs_cmd="dnf5 needs-restarting"
  fi

  if [[ -n "$needs_cmd" ]]; then
    local rc
    $needs_cmd -r >/dev/null 2>&1
    rc="$?"
    step "Reboot recommendation"
    if [[ "$rc" -eq 1 ]]; then
      say "  RECOMMENDED (needs-restarting)"
      log "Reboot recommended (needs-restarting indicates it)."
    elif [[ "$rc" -eq 0 ]]; then
      say "  NOT REQUIRED"
      log "No reboot required per needs-restarting."
    else
      say "  UNKNOWN (needs-restarting error)"
      log "needs-restarting returned unexpected status: ${rc}"
    fi
  else
    step "Reboot recommendation"
    say "  UNKNOWN (needs-restarting not found)"
    log "needs-restarting not found (dnf-utils/dnf-plugins-core). Reboot is still recommended after kernel updates."
  fi
}

major_version_upgrade() {
  command_exists dnf || die "dnf not found"

  local current_ver target_ver
  current_ver="$(rpm -E %fedora)"
  log "Current Fedora version: ${current_ver}"

  # Determine next Fedora version number (simple default)
  target_ver="$((current_ver + 1))"

  step "Prepare major upgrade to Fedora ${target_ver}"
  run_cmd_required "Install system-upgrade plugin" dnf -y install dnf-plugin-system-upgrade

  run_cmd_required "Download upgrade packages (releasever=${target_ver})" \
    dnf -y system-upgrade download --releasever="${target_ver}" --allowerasing

  step "Reboot into upgrade environment"
  say "  NOTE: System will reboot now if this succeeds."
  log "Triggering reboot into system upgrade environment"
  dnf -y system-upgrade reboot >>"$LOG_FILE" 2>&1
}

manage_logs() {
  # Rotate current log if it exists and is non-empty.
  if [[ -s "$LOG_FILE" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    mv "$LOG_FILE" "${LOG_FILE}.${ts}"
  fi
  touch "$LOG_FILE"

  if [[ "$LOG_DAYS" -gt 0 ]]; then
    find "$(dirname "$LOG_FILE")" -maxdepth 1 -type f \
      -name "$(basename "$LOG_FILE").*" -mtime "+${LOG_DAYS}" -delete 2>/dev/null || true
  fi
}

usage() {
  cat <<EOF
Fedora Maintenance Script

Usage:
  sudo $0 daily
  sudo $0 monthly
  sudo $0 major
  sudo $0 extended

Modes:
  daily    - dnf upgrade --refresh + flatpak + cleanup
  monthly  - daily + firmware updates (fwupdmgr) + cleanup
  major    - major Fedora version upgrade (assumes next version) + cleanup beforehand
  extended - monthly (dnf + firmware + flatpak) + opt-in pip update
             (bug-bounty-agent) + opt-in Ollama model update (local-ai-agent)
             + cleanup. Each extra step is off by default; enable with
             UPDATE_PIP=1 / UPDATE_OLLAMA=1.

Env vars:
  KEEP_KERNELS=3      How many kernels to keep when pruning old ones (default: 3)
  LOG_DAYS=30         How many days to keep rotated logs (0 disables cleanup)
  JOURNAL_DAYS=7      Journal retention in days (0 disables cleanup)
  NOTIFY_USER=you     Desktop notification target (optional)
  UPDATE_PIP=1        extended mode: upgrade bug-bounty-agent's pip --user deps (default: 0)
  UPDATE_OLLAMA=1     extended mode: re-pull every locally installed Ollama model (default: 0)
  MAINTENANCE_USER=you  User whose pip --user environment to upgrade (default: NOTIFY_USER)

Log:
  $LOG_FILE
EOF
}

main() {
  local mode="${1:-}"
  [[ -n "$mode" ]] || { usage; exit 1; }

  if [[ "$mode" == "-h" || "$mode" == "--help" || "$mode" == "help" ]]; then
    usage
    exit 0
  fi

  MODE="$mode"
  need_root "$@"
  mkdir -p "$(dirname "$LOG_FILE")"
  manage_logs
  trap on_exit EXIT

  say "Fedora maintenance: mode=${mode}"
  log "========== START: mode=${mode} =========="
  log "Host: $(hostname) | Fedora: $(cat /etc/fedora-release 2>/dev/null || true) | Kernel: $(uname -r)"

  case "$mode" in
    daily)
      dnf_update_daily
      flatpak_update
      cleanup_system
      maybe_reboot_hint
      ;;
    monthly)
      dnf_update_daily
      firmware_update_monthly
      flatpak_update
      cleanup_system
      maybe_reboot_hint
      ;;
    major)
      # Do a normal update + cleanup first, then upgrade.
      dnf_update_daily
      flatpak_update
      cleanup_system
      major_version_upgrade
      ;;
    extended)
      # monthly (dnf + firmware + flatpak), plus the owner's other dev-stack
      # ecosystems (opt-in, see usage()).
      dnf_update_daily
      firmware_update_monthly
      flatpak_update
      pip_update_extended
      ollama_update_extended
      cleanup_system
      maybe_reboot_hint
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  log "========== END: mode=${mode} =========="
}

main "$@"
