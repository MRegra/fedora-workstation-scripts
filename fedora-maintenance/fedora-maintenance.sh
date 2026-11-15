#!/usr/bin/env bash
# Modes accepted by main(); scripts/test-smoke.sh checks README ExecStart lines against it.
# smoke-modes: daily monthly major extended
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_FILE="${LOG_FILE:-/var/log/fedora-maintenance.log}"
KEEP_KERNELS="${KEEP_KERNELS:-3}"   # override: KEEP_KERNELS=2 ./fedora-maintenance.sh monthly
LOG_DAYS="${LOG_DAYS:-30}"          # keep rotated logs for N days (0 disables cleanup)
JOURNAL_DAYS="${JOURNAL_DAYS:-7}"   # journal retention in days (0 disables cleanup)
NOTIFY_USER="${NOTIFY_USER:-}"      # desktop notification target username (optional)
# Daily runs default to notify-only (list updates, install nothing) per
# Fedora's own guidance for a single workstation; AUTO_INSTALL=1 restores the
# old unattended-install behavior. Only the `daily` mode is affected.
AUTO_INSTALL="${AUTO_INSTALL:-0}"

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
DRY_RUN=0                           # set by --dry-run: list pending actions, change nothing

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
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "  WOULD RUN: $*"
    log "DRY-RUN: $desc | cmd: $*"
    return 0
  fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "  WOULD RUN: $*"
    log "DRY-RUN: $desc | cmd: $*"
    return 0
  fi
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

# Notify-only path for the default (AUTO_INSTALL=0) daily run: list available
# updates without installing anything. `dnf check-update` exits 0 (no
# updates), 100 (updates available) or 1+ (error) - 100 is not a failure here.
check_updates_daily() {
  step "Check for updates (notify-only; set AUTO_INSTALL=1 to install unattended)"
  local output rc pkg_lines pkg_count summary
  # --dry-run: no metadata refresh and no desktop notification either.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "  WOULD RUN: dnf -y check-update --refresh (and notify if updates are available)"
    log "DRY-RUN: check for updates | cmd: dnf -y check-update --refresh"
    return 0
  fi
  output="$(dnf -y check-update --refresh 2>&1)"
  rc="$?"
  printf '%s\n' "$output" >>"$LOG_FILE"

  case "$rc" in
    0)
      ok
      say "  No updates available"
      log "No updates available"
      ;;
    100)
      ok
      pkg_lines="$(printf '%s\n' "$output" | awk 'NF && $1 ~ /^[A-Za-z0-9]/ {print $1}')"
      pkg_count="$(printf '%s\n' "$pkg_lines" | sed '/^$/d' | wc -l | tr -d ' ')"
      say "  ${pkg_count} update(s) available (not installed; set AUTO_INSTALL=1 to install unattended)"
      log "${pkg_count} update(s) available: $(printf '%s\n' "$pkg_lines" | tr '\n' ' ')"
      summary="$(printf '%s\n' "$pkg_lines" | head -n 10 | paste -sd ',' - | sed 's/,/, /g')"
      [[ "$pkg_count" -gt 10 ]] && summary="${summary}, and $((pkg_count - 10)) more"
      notify_user "ok" "${pkg_count} update(s) available: ${summary}. Run with AUTO_INSTALL=1 to install unattended, or update manually."
      ;;
    *)
      say "  FAILED (see log: $LOG_FILE)"
      log "FAILED: dnf check-update exited ${rc}"
      return 1
      ;;
  esac
}

# Entry point for the `daily` mode: AUTO_INSTALL=1 restores the old
# unattended install behavior; the default is notify-only.
daily_mode() {
  if [[ "$AUTO_INSTALL" == "1" ]]; then
    dnf_update_daily
    flatpak_update
  else
    check_updates_daily
  fi
  cleanup_system
  maybe_reboot_hint
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

  # requirements.txt pins playwright with no upper bound, so an upgrade can
  # move it to a release that expects a newer Chromium build than the one
  # already cached under the user's ~/.cache/ms-playwright. install-tools.sh
  # always pairs the pip install with this command (see its "Playwright
  # browser" step); do the same here so the browser phase doesn't go stale.
  if grep -q '^playwright' "$req_file"; then
    run_cmd_optional "Playwright browser update (bug-bounty-agent, user: ${MAINTENANCE_USER})" \
      runuser -u "$MAINTENANCE_USER" -- python3 -m playwright install chromium
  fi
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
  local list_output list_rc=0
  list_output="$(ollama list 2>>"$LOG_FILE")" || list_rc="$?"
  if [[ "$list_rc" -ne 0 ]]; then
    step "Ollama model update (local-ai-agent)"
    say "  SKIP (ollama list failed; daemon not running? see log: $LOG_FILE)"
    log "ollama list exited ${list_rc}; skipping model update (daemon down or OLLAMA_HOST unreachable?)"
    return 0
  fi

  local models
  models="$(printf '%s\n' "$list_output" | awk 'NR>1 && NF{print $1}')"
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
      elif [[ "$DRY_RUN" -eq 1 ]]; then
        # shellcheck disable=SC2086  # intentional word splitting, see dnf -y remove below
        say "  WOULD REMOVE: $(printf '%s ' $old_kernels)"
        log "DRY-RUN: would remove old kernels: ${old_kernels}"
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
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "  WOULD RUN: dnf -y system-upgrade reboot (system would reboot now)"
    log "DRY-RUN: would trigger reboot into system upgrade environment"
    return 0
  fi
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
  sudo $0 daily [--dry-run]
  sudo $0 monthly [--dry-run]
  sudo $0 major [--dry-run]
  sudo $0 extended [--dry-run]

Modes:
  daily    - notify-only by default: lists available updates + cleanup (set
             AUTO_INSTALL=1 to install them unattended, the old behavior)
  monthly  - daily (unattended install) + firmware updates (fwupdmgr) + cleanup
  major    - major Fedora version upgrade (assumes next version) + cleanup beforehand
  extended - monthly (dnf + firmware + flatpak) + opt-in pip update
             (bug-bounty-agent) + opt-in Ollama model update (local-ai-agent)
             + cleanup. Each extra step is off by default; enable with
             UPDATE_PIP=1 / UPDATE_OLLAMA=1.

Flags:
  --dry-run   List the dnf/flatpak/firmware/kernel-prune/upgrade actions this
              mode would take, without running any of them. Exits 0. No
              package install/remove/update, no firmware flash, no reboot.
              The log file is still created/rotated the same way a real
              run's is (see Log below).

Env vars:
  AUTO_INSTALL=1      Install daily updates unattended instead of notify-only (default: 0)
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
  local mode="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help | help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      *)
        [[ -z "$mode" ]] && mode="$arg"
        ;;
    esac
  done
  [[ -n "$mode" ]] || { usage; exit 1; }

  MODE="$mode"
  need_root "$@"
  mkdir -p "$(dirname "$LOG_FILE")"
  manage_logs
  trap on_exit EXIT

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "Fedora maintenance: mode=${mode} (dry run, nothing will be changed)"
    log "========== START: mode=${mode} dry-run=1 =========="
  else
    say "Fedora maintenance: mode=${mode}"
    log "========== START: mode=${mode} =========="
  fi
  log "Host: $(hostname) | Fedora: $(cat /etc/fedora-release 2>/dev/null || true) | Kernel: $(uname -r)"

  case "$mode" in
    daily)
      daily_mode
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

# Guarded so scripts/test-dry-run.sh and
# scripts/test-fedora-maintenance-daily.sh can `source` this file (to stub
# functions/env like LOG_FILE and unit-test daily_mode/check_updates_daily
# with faked dnf/notify_user) without running main() for real.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
