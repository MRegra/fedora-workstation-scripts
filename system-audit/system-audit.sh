#!/usr/bin/env bash
# Read-only system performance and security audit.
# Usage:
#   ./system-audit.sh               — run audit (compares against baseline if one exists)
#   ./system-audit.sh --save-baseline  — run audit then save current state as baseline
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
IS_ROOT=false
[[ "${EUID:-$(id -u)}" -eq 0 ]] && IS_ROOT=true

if $IS_ROOT; then
  LOG_DIR="/var/log/system-audit"
  BASELINE_DIR="/var/lib/system-audit"
else
  LOG_DIR="${HOME}/.local/share/system-audit/logs"
  BASELINE_DIR="${HOME}/.local/share/system-audit"
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/audit-${TIMESTAMP}.log"
BASELINE_FILE="${BASELINE_DIR}/baseline.json"
SAVE_BASELINE=false
[[ "${1:-}" == "--save-baseline" ]] && SAVE_BASELINE=true

ALERT_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Output helpers — color on TTY, plain in log
# ---------------------------------------------------------------------------
RED="\033[0;31m"; YEL="\033[0;33m"; GRN="\033[0;32m"
CYN="\033[0;36m"; BLD="\033[1m"; RST="\033[0m"

_color() { [[ -t 1 ]] && printf '%b' "$1" || true; }

_log_plain() { echo "$1" >>"$LOG_FILE"; }

pass()  { PASS_COUNT=$((PASS_COUNT+1));   _color "$GRN"; printf '  [PASS]  %s\n' "$1"; _color "$RST"; _log_plain "  [PASS]  $1"; }
warn()  { WARN_COUNT=$((WARN_COUNT+1));   _color "$YEL"; printf '  [WARN]  %s\n' "$1"; _color "$RST"; _log_plain "  [WARN]  $1"; }
alert() { ALERT_COUNT=$((ALERT_COUNT+1)); _color "$RED"; printf ' [ALERT]  %s\n' "$1"; _color "$RST"; _log_plain " [ALERT]  $1"; }
info()  { printf '          %s\n' "$1"; _log_plain "          $1"; }
skip()  { printf '  [SKIP]  %s\n' "$1"; _log_plain "  [SKIP]  $1"; }

section() {
  local title="$1"
  printf '\n'; _color "$BLD$CYN"; printf '=== %s ===\n' "$title"; _color "$RST"
  _log_plain ""
  _log_plain "=== $title ==="
}

# Wrap each section so one failing probe doesn't abort the whole audit.
# Usage: guard section_function_name
guard() {
  local fn="$1"
  if ! "$fn" 2>>"$LOG_FILE"; then
    warn "Section '${fn}' encountered an error — see log: ${LOG_FILE}"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Baseline helpers
# ---------------------------------------------------------------------------
BL_PORTS="" BL_SUID="" BL_SHELL_USERS=""

load_baseline() {
  [[ -f "$BASELINE_FILE" ]] || return 0
  BL_PORTS="$(python3 -c "import json,sys; d=json.load(open('$BASELINE_FILE')); print('\n'.join(d.get('ports',[])))" 2>/dev/null || true)"
  BL_SUID="$(python3  -c "import json,sys; d=json.load(open('$BASELINE_FILE')); print('\n'.join(d.get('suid',[])))"  2>/dev/null || true)"
  BL_SHELL_USERS="$(python3 -c "import json,sys; d=json.load(open('$BASELINE_FILE')); print('\n'.join(d.get('shell_users',[])))" 2>/dev/null || true)"
}

NEW_PORTS="" NEW_SUID="" NEW_SHELL_USERS=""

save_baseline() {
  mkdir -p "$BASELINE_DIR"
  python3 - <<PYEOF
import json
data = {
    "timestamp": "${TIMESTAMP}",
    "ports": [l for l in """${NEW_PORTS}""".strip().splitlines() if l.strip()],
    "suid":  [l for l in """${NEW_SUID}""".strip().splitlines()  if l.strip()],
    "shell_users": [l for l in """${NEW_SHELL_USERS}""".strip().splitlines() if l.strip()],
}
json.dump(data, open("${BASELINE_FILE}", "w"), indent=2)
print("Baseline saved to ${BASELINE_FILE}")
PYEOF
}

diff_check() {
  local label="$1" current="$2" baseline="$3"
  [[ -z "$baseline" ]] && return 0
  local added removed
  added="$(comm  -13 <(echo "$baseline" | sort) <(echo "$current" | sort) | grep -v '^$' || true)"
  removed="$(comm -23 <(echo "$baseline" | sort) <(echo "$current" | sort) | grep -v '^$' || true)"
  if [[ -n "$added" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && alert "${label} NEW: ${line}"; done <<< "$added"
  fi
  if [[ -n "$removed" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && warn "${label} REMOVED: ${line}"; done <<< "$removed"
  fi
}

# ---------------------------------------------------------------------------
# SECTION 0 — Header
# ---------------------------------------------------------------------------
header() {
  local mode="user"
  $IS_ROOT && mode="root"
  _color "$BLD"
  printf '\n============================\n'
  printf '  SYSTEM AUDIT REPORT\n'
  printf '============================\n'
  _color "$RST"
  info "Date    : $(date)"
  info "Host    : $(hostname)"
  info "Kernel  : $(uname -r)"
  info "Fedora  : $(cat /etc/fedora-release 2>/dev/null || echo unknown)"
  info "Uptime  : $(uptime -p 2>/dev/null || uptime)"
  info "Mode    : ${mode}"
  _log_plain ""
}

# ---------------------------------------------------------------------------
# SECTION 1a — CPU Load
# ---------------------------------------------------------------------------
perf_cpu() {
  section "PERFORMANCE — CPU"
  local ncpu load1 load5 load15
  ncpu="$(nproc)"
  read -r load1 load5 load15 _ < /proc/loadavg
  info "CPUs: ${ncpu}  |  Load avg: ${load1} (1m)  ${load5} (5m)  ${load15} (15m)"

  local threshold_warn threshold_alert
  threshold_warn="$ncpu"
  threshold_alert="$(echo "$ncpu * 2" | bc 2>/dev/null || echo $((ncpu * 2)))"

  if awk "BEGIN{exit !($load1 >= $threshold_alert)}"; then
    alert "Load avg 1m (${load1}) >= 2x CPU count (${threshold_alert}) — system overloaded"
  elif awk "BEGIN{exit !($load1 >= $threshold_warn)}"; then
    warn "Load avg 1m (${load1}) >= CPU count (${threshold_warn})"
  else
    pass "Load avg OK (${load1} < ${threshold_warn} CPUs)"
  fi
}

# ---------------------------------------------------------------------------
# SECTION 1b — Top Processes
# ---------------------------------------------------------------------------
perf_top_procs() {
  section "PERFORMANCE — Top Processes"
  info "--- Top 5 by CPU ---"
  ps aux --sort=-%cpu 2>/dev/null | awk 'NR==1 || NR<=6 {printf "          %-10s %5s %5s %s\n",$1,$3,$4,substr($0,index($0,$11))}' | head -6 | tail -5 | while IFS= read -r line; do info "$line"; done
  info "--- Top 5 by RAM ---"
  ps aux --sort=-%mem 2>/dev/null | awk 'NR==1 || NR<=6 {printf "          %-10s %5s %5s %s\n",$1,$3,$4,substr($0,index($0,$11))}' | head -6 | tail -5 | while IFS= read -r line; do info "$line"; done
}

# ---------------------------------------------------------------------------
# SECTION 1c — Disk Usage
# ---------------------------------------------------------------------------
perf_disk() {
  section "PERFORMANCE — Disk Usage"
  local has_alert=false has_warn=false
  while IFS= read -r line; do
    local pct mount
    pct="$(echo "$line" | awk '{print $2}' | tr -d '%')"
    mount="$(echo "$line" | awk '{print $1}')"
    [[ "$pct" =~ ^[0-9]+$ ]] || { info "$line"; continue; }
    if [[ "$pct" -ge 90 ]]; then
      alert "Disk ${mount}: ${pct}% used"
      has_alert=true
    elif [[ "$pct" -ge 80 ]]; then
      warn "Disk ${mount}: ${pct}% used"
      has_warn=true
    else
      pass "Disk ${mount}: ${pct}% used"
    fi
  done < <(df --output=target,pcent,size,used,avail -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2)
}

# ---------------------------------------------------------------------------
# SECTION 1d — Temperature
# ---------------------------------------------------------------------------
perf_temps() {
  section "PERFORMANCE — Temperature"
  local found=false

  if command_exists sensors; then
    found=true
    local has_warn=false has_alert=false
    while IFS= read -r line; do
      local temp
      temp="$(echo "$line" | grep -oP '[\+\-]?\d+\.\d+(?=°C)' | head -1 || true)"
      [[ -z "$temp" ]] && continue
      local rounded
      rounded="$(printf '%.0f' "$temp" 2>/dev/null || echo "${temp%%.*}")"
      if [[ "$rounded" -ge 85 ]]; then
        alert "$line"
        has_alert=true
      elif [[ "$rounded" -ge 70 ]]; then
        warn "$line"
        has_warn=true
      else
        info "$line"
      fi
    done < <(sensors 2>/dev/null | grep -E '°C')
    if ! $has_alert && ! $has_warn; then pass "All temperatures within safe range"; fi
  fi

  if ! $found; then
    # Fallback: sysfs thermal zones
    local zone_files
    zone_files="$(ls /sys/class/thermal/thermal_zone*/temp 2>/dev/null || true)"
    if [[ -n "$zone_files" ]]; then
      found=true
      while IFS= read -r zf; do
        local raw_temp celsius zone_name
        raw_temp="$(cat "$zf" 2>/dev/null || echo 0)"
        celsius=$(( raw_temp / 1000 ))
        zone_name="$(basename "$(dirname "$zf")")"
        if [[ "$celsius" -ge 85 ]]; then
          alert "${zone_name}: ${celsius}°C"
        elif [[ "$celsius" -ge 70 ]]; then
          warn "${zone_name}: ${celsius}°C"
        elif [[ "$celsius" -gt 0 ]]; then
          pass "${zone_name}: ${celsius}°C"
        fi
      done <<< "$zone_files"
    fi
  fi

  $found || skip "Temperature sensors not available (install lm_sensors: sudo dnf install lm_sensors)"
}

# ---------------------------------------------------------------------------
# SECTION 2a — Login Users & Shells
# ---------------------------------------------------------------------------
sec_users() {
  section "SECURITY — Users with Login Shells"
  local current_user
  current_user="$(id -un)"
  local shell_users
  shell_users="$(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown|git-shell)$/ && $7 != "" {print $1":"$3":"$7}' /etc/passwd 2>/dev/null || true)"
  NEW_SHELL_USERS="$shell_users"

  diff_check "Shell-user" "$shell_users" "$BL_SHELL_USERS"

  local unexpected=false
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local uname uid shell
    uname="$(echo "$entry" | cut -d: -f1)"
    uid="$(echo "$entry"   | cut -d: -f2)"
    shell="$(echo "$entry" | cut -d: -f3)"

    if [[ "$uname" != "root" && "$uname" != "$current_user" && "$uid" -lt 1000 ]]; then
      alert "System account has login shell: ${uname} (uid=${uid}, shell=${shell})"
      unexpected=true
    elif [[ "$uname" != "root" && "$uname" != "$current_user" && "$uid" -ge 1000 ]]; then
      warn "Extra user has login shell: ${uname} (uid=${uid}, shell=${shell})"
      unexpected=true
    else
      info "  ${uname} (uid=${uid}, shell=${shell})"
    fi
  done <<< "$shell_users"

  $unexpected || pass "Only expected accounts have login shells"
}

# ---------------------------------------------------------------------------
# SECTION 2b — Active Sessions
# ---------------------------------------------------------------------------
sec_sessions() {
  section "SECURITY — Active Sessions"
  local current_user sessions other_users
  current_user="$(id -un)"
  sessions="$(who 2>/dev/null || true)"

  if [[ -z "$sessions" ]]; then
    pass "No interactive sessions (running headless or no w output)"
    return
  fi

  info "Active sessions:"
  while IFS= read -r line; do info "  $line"; done <<< "$sessions"

  other_users="$(echo "$sessions" | awk '{print $1}' | sort -u | grep -v "^${current_user}$" || true)"
  if [[ -n "$other_users" ]]; then
    warn "Other users are logged in: $(echo "$other_users" | tr '\n' ' ')"
  else
    pass "Only current user (${current_user}) is logged in"
  fi
}

# ---------------------------------------------------------------------------
# SECTION 2c — Failed Logins
# ---------------------------------------------------------------------------
sec_failed_logins() {
  section "SECURITY — Failed Logins (last 24h)"

  local count=0
  if command_exists journalctl; then
    count="$(journalctl -u sshd -u systemd-logind --since "24 hours ago" --no-pager -q 2>/dev/null \
      | grep -ciE 'fail|invalid|authentication failure' || true)"
  fi

  local lastb_count=0
  if $IS_ROOT && command_exists lastb; then
    lastb_count="$(lastb --since "$(date -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)" --no-header 2>/dev/null \
      | grep -cv '^$' || true)"
    count=$(( count + lastb_count ))
  fi

  if [[ "$count" -ge 10 ]]; then
    alert "Failed login attempts last 24h: ${count} (brute-force risk?)"
  elif [[ "$count" -ge 1 ]]; then
    warn "Failed login attempts last 24h: ${count}"
  else
    pass "No failed login attempts in last 24h"
  fi

  $IS_ROOT || info "  (run as root for full lastb history)"
}

# ---------------------------------------------------------------------------
# SECTION 2d — Listening Ports
# ---------------------------------------------------------------------------
sec_ports() {
  section "SECURITY — Listening Ports"

  local ports
  if $IS_ROOT; then
    ports="$(ss -tlnup 2>/dev/null | tail -n +2 | awk '{print $4, $NF}' | sort || true)"
  else
    ports="$(ss -tln 2>/dev/null | tail -n +2 | awk '{print $4}' | sort || true)"
  fi

  NEW_PORTS="$ports"
  diff_check "Port" "$ports" "$BL_PORTS"

  if [[ -z "$ports" ]]; then
    pass "No listening TCP ports found"
    return
  fi

  info "Listening TCP ports:"
  while IFS= read -r line; do info "  $line"; done <<< "$ports"

  [[ -z "$BL_PORTS" ]] && info "  (save a baseline with --save-baseline to detect changes)"
}

# ---------------------------------------------------------------------------
# SECTION 2e — Suspicious Processes
# ---------------------------------------------------------------------------
sec_suspicious_procs() {
  section "SECURITY — Suspicious Processes"
  local found_any=false

  # Processes running from /tmp or /dev/shm
  local tmp_procs
  tmp_procs="$(find /proc/*/exe -maxdepth 0 2>/dev/null | while read -r exelink; do
    target="$(readlink "$exelink" 2>/dev/null || true)"
    if [[ "$target" == /tmp/* || "$target" == /dev/shm/* || "$target" == /run/user/*/tmp/* ]]; then
      pid="$(echo "$exelink" | cut -d/ -f3)"
      echo "PID ${pid}: ${target}"
    fi
  done || true)"

  if [[ -n "$tmp_procs" ]]; then
    while IFS= read -r line; do alert "Process in temp dir: $line"; done <<< "$tmp_procs"
    found_any=true
  fi

  # Processes with deleted executables (running binary was removed from disk)
  local deleted_procs
  deleted_procs="$(find /proc/*/exe -maxdepth 0 2>/dev/null | while read -r exelink; do
    target="$(readlink "$exelink" 2>/dev/null || true)"
    if [[ "$target" == *" (deleted)"* ]]; then
      pid="$(echo "$exelink" | cut -d/ -f3)"
      echo "PID ${pid}: ${target}"
    fi
  done | grep -v '^\s*$' | head -20 || true)"

  if [[ -n "$deleted_procs" ]]; then
    local count
    count="$(echo "$deleted_procs" | wc -l)"
    # A few deleted-exe entries are normal (runtime updates), many is suspicious
    if [[ "$count" -gt 10 ]]; then
      alert "Many processes (${count}) running deleted executables — check for stealthy malware or run soft-reboot.sh"
    else
      warn "${count} process(es) running deleted executables (normal after updates — run soft-reboot.sh to restart them)"
      while IFS= read -r line; do info "  $line"; done <<< "$deleted_procs"
    fi
    found_any=true
  fi

  # Processes with suspicious command lines (base64, curl piped to bash, etc.)
  if $IS_ROOT; then
    local suspicious_cmds
    suspicious_cmds="$(ps aux 2>/dev/null \
      | grep -E 'base64.*decode|curl.*[|].*bash|wget.*[|].*bash|bash.*-i.*>&|/dev/tcp|/dev/shm' \
      | grep -v grep || true)"
    if [[ -n "$suspicious_cmds" ]]; then
      while IFS= read -r line; do alert "Suspicious cmdline: $line"; done <<< "$suspicious_cmds"
      found_any=true
    fi
  fi

  $found_any || pass "No suspicious processes found"
}

# ---------------------------------------------------------------------------
# SECTION 2f — SUID/SGID Files
# ---------------------------------------------------------------------------
sec_suid() {
  section "SECURITY — SUID/SGID Files"

  local scan_paths=("/usr/bin" "/usr/sbin" "/bin" "/sbin" "/usr/libexec")
  $IS_ROOT && scan_paths=("/")

  local flags="-xdev \( -perm -4000 -o -perm -2000 \) -type f"
  local suid_files
  # shellcheck disable=SC2086
  suid_files="$(find "${scan_paths[@]}" $flags 2>/dev/null | sort || true)"

  NEW_SUID="$suid_files"
  diff_check "SUID/SGID" "$suid_files" "$BL_SUID"

  local count
  count="$(echo "$suid_files" | grep -c '.' || true)"

  if [[ -z "$BL_SUID" ]]; then
    info "Found ${count} SUID/SGID files (save baseline with --save-baseline to detect new additions)"
    while IFS= read -r f; do info "  $f"; done <<< "$suid_files"
  else
    pass "SUID/SGID file list matches baseline (${count} files)"
  fi
}

# ---------------------------------------------------------------------------
# SECTION 2g — Recent /etc Changes
# ---------------------------------------------------------------------------
sec_etc_changes() {
  section "SECURITY — Recent /etc Changes (last 24h)"

  local changed
  changed="$(find /etc -maxdepth 4 -mtime -1 -type f 2>/dev/null | sort || true)"

  if [[ -z "$changed" ]]; then
    pass "No /etc files modified in last 24h"
    return
  fi

  local count
  count="$(echo "$changed" | grep -c '.' || true)"

  # Flag sensitive paths
  local sensitive_pattern='/etc/passwd|/etc/shadow|/etc/group|/etc/sudoers|/etc/ssh/|/etc/pam.d|/etc/cron|/etc/systemd'
  local sensitive_hits
  sensitive_hits="$(echo "$changed" | grep -E "$sensitive_pattern" || true)"

  if [[ -n "$sensitive_hits" ]]; then
    while IFS= read -r f; do alert "Sensitive file changed: $f"; done <<< "$sensitive_hits"
  fi

  if [[ "$count" -ge 5 ]]; then
    warn "${count} /etc files changed in last 24h"
  else
    warn "${count} /etc file(s) changed in last 24h"
  fi

  while IFS= read -r f; do
    echo "$sensitive_hits" | grep -qF "$f" || info "  $f"
  done <<< "$changed"
}

# ---------------------------------------------------------------------------
# SECTION 2h — Cron Jobs
# ---------------------------------------------------------------------------
sec_cron() {
  section "SECURITY — Cron Jobs"
  local found_any=false
  local suspicious_pattern='/tmp|/dev/shm|base64|curl|wget|bash -c|bash -i|python -c'

  # Current user's crontab
  local user_crontab
  user_crontab="$(crontab -l 2>/dev/null || true)"
  if [[ -n "$user_crontab" ]]; then
    info "User crontab ($(id -un)):"
    while IFS= read -r line; do info "  $line"; done <<< "$user_crontab"
    local user_suspicious
    user_suspicious="$(echo "$user_crontab" | grep -E "$suspicious_pattern" || true)"
    if [[ -n "$user_suspicious" ]]; then
      while IFS= read -r line; do alert "Suspicious cron entry: $line"; done <<< "$user_suspicious"
      found_any=true
    fi
  else
    info "No crontab for current user"
  fi

  if $IS_ROOT; then
    # System crontabs
    local sys_cron_dirs=("/etc/cron.d" "/etc/cron.daily" "/etc/cron.hourly" "/etc/cron.weekly" "/etc/cron.monthly" "/var/spool/cron/crontabs")
    for d in "${sys_cron_dirs[@]}"; do
      [[ -d "$d" ]] || continue
      while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local content
        content="$(cat "$f" 2>/dev/null || true)"
        [[ -z "$content" ]] && continue
        local suspicious
        suspicious="$(echo "$content" | grep -vE '^#|^$' | grep -E "$suspicious_pattern" || true)"
        if [[ -n "$suspicious" ]]; then
          alert "Suspicious cron in ${f}:"
          while IFS= read -r line; do alert "  $line"; done <<< "$suspicious"
          found_any=true
        fi
      done < <(find "$d" -maxdepth 1 -type f 2>/dev/null)
    done
  fi

  $found_any || pass "No suspicious cron jobs found"
}

# ---------------------------------------------------------------------------
# SECTION 2i — Systemd Timers
# ---------------------------------------------------------------------------
sec_timers() {
  section "SECURITY — Systemd Timers"
  command_exists systemctl || { skip "systemctl not available"; return; }

  local timers
  timers="$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | awk '{print $NF}' | grep -v '^$' | sort || true)"

  if [[ -z "$timers" ]]; then
    info "No active systemd timers"
    return
  fi

  local suspicious=false
  while IFS= read -r timer; do
    [[ -z "$timer" ]] && continue
    local unit_file
    unit_file="$(systemctl cat "$timer" 2>/dev/null || true)"
    local sus_hits
    sus_hits="$(echo "$unit_file" | grep -E 'ExecStart.*(/tmp|/dev/shm|curl|wget|base64)' || true)"
    if [[ -n "$sus_hits" ]]; then
      alert "Suspicious timer ${timer}: ${sus_hits}"
      suspicious=true
    fi
  done <<< "$timers"

  info "Active timers: $(echo "$timers" | wc -l)"
  $suspicious || pass "No suspicious systemd timers found"
}

# ---------------------------------------------------------------------------
# SECTION 2j — SSH Authorized Keys
# ---------------------------------------------------------------------------
sec_ssh_keys() {
  section "SECURITY — SSH Authorized Keys"
  local found_any=false

  check_auth_keys() {
    local keyfile="$1"
    local owner="$2"
    [[ -f "$keyfile" ]] || return 0
    local content
    content="$(cat "$keyfile" 2>/dev/null || true)"
    [[ -z "$content" ]] && return 0

    local count
    count="$(echo "$content" | grep -cvE '^#|^$' || true)"
    if [[ "$owner" == "root" ]]; then
      alert "root has ${count} authorized SSH key(s) in ${keyfile}"
    else
      warn "${owner}: ${count} authorized SSH key(s) in ${keyfile}"
    fi
    while IFS= read -r line; do
      [[ "$line" =~ ^#|^$ ]] && continue
      info "  ${owner}: $(echo "$line" | awk '{print $1, $NF}')"
    done <<< "$content"
    found_any=true
  }

  if $IS_ROOT; then
    check_auth_keys "/root/.ssh/authorized_keys" "root"
    while IFS= read -r home; do
      [[ -d "$home" ]] || continue
      local user
      user="$(basename "$home")"
      check_auth_keys "${home}/.ssh/authorized_keys" "$user"
    done < <(awk -F: '$3 >= 1000 {print $6}' /etc/passwd 2>/dev/null)
  else
    check_auth_keys "${HOME}/.ssh/authorized_keys" "$(id -un)"
  fi

  $found_any || pass "No SSH authorized_keys found (typical for workstation)"
}

# ---------------------------------------------------------------------------
# SECTION 2k — Firewall
# ---------------------------------------------------------------------------
sec_firewall() {
  section "SECURITY — Firewall (firewalld)"

  if ! command_exists firewall-cmd; then
    alert "firewalld not installed — no firewall active"
    return
  fi

  local state
  state="$(firewall-cmd --state 2>/dev/null || echo "not running")"
  if [[ "$state" == "running" ]]; then
    pass "firewalld is running"
    if $IS_ROOT; then
      info "Default zone: $(firewall-cmd --get-default-zone 2>/dev/null || true)"
      info "Active zones:"
      firewall-cmd --get-active-zones 2>/dev/null | while IFS= read -r line; do info "  $line"; done || true
    fi
  else
    alert "firewalld state: ${state}"
  fi
}

# ---------------------------------------------------------------------------
# SECTION 2l — SELinux
# ---------------------------------------------------------------------------
sec_selinux() {
  section "SECURITY — SELinux"

  if ! command_exists getenforce; then
    alert "SELinux tools not found — SELinux may be absent or disabled"
    return
  fi

  local mode
  mode="$(getenforce 2>/dev/null || echo "Unknown")"
  case "$mode" in
    Enforcing)  pass "SELinux: Enforcing" ;;
    Permissive) warn "SELinux: Permissive — not enforcing policies" ;;
    Disabled)   alert "SELinux: Disabled — system is unprotected" ;;
    *)          warn "SELinux status unknown: ${mode}" ;;
  esac

  if command_exists sestatus && $IS_ROOT; then
    local denials
    denials="$(journalctl --since "24 hours ago" --no-pager -q 2>/dev/null \
      | grep -c 'avc:.*denied' || true)"
    if [[ "$denials" -gt 0 ]]; then
      warn "SELinux: ${denials} denial(s) in last 24h (check: journalctl | grep 'avc.*denied')"
    fi
  fi
}

# ---------------------------------------------------------------------------
# SECTION 3 — Summary
# ---------------------------------------------------------------------------
summary() {
  section "SUMMARY"
  _color "$GRN"; printf '  PASS  : %d\n' "$PASS_COUNT";  _color "$RST"
  _color "$YEL"; printf '  WARN  : %d\n' "$WARN_COUNT";  _color "$RST"
  _color "$RED"; printf '  ALERT : %d\n' "$ALERT_COUNT"; _color "$RST"
  _log_plain "  PASS  : $PASS_COUNT"
  _log_plain "  WARN  : $WARN_COUNT"
  _log_plain "  ALERT : $ALERT_COUNT"
  printf '\n'
  if [[ "$ALERT_COUNT" -gt 0 ]]; then
    _color "$RED$BLD"; printf '  Action needed — review ALERT items above.\n'; _color "$RST"
    _log_plain "  Action needed — review ALERT items above."
  elif [[ "$WARN_COUNT" -gt 0 ]]; then
    _color "$YEL"; printf '  System looks OK — review WARN items.\n'; _color "$RST"
    _log_plain "  System looks OK — review WARN items."
  else
    _color "$GRN$BLD"; printf '  All checks passed.\n'; _color "$RST"
    _log_plain "  All checks passed."
  fi
  printf '\n  Log: %s\n\n' "$LOG_FILE"
  _log_plain "  Log: $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  _log_plain "SYSTEM AUDIT — $(date) — host: $(hostname)"

  load_baseline

  guard header

  # Performance
  guard perf_cpu
  guard perf_top_procs
  guard perf_disk
  guard perf_temps

  # Security
  guard sec_users
  guard sec_sessions
  guard sec_failed_logins
  guard sec_ports
  guard sec_suspicious_procs
  guard sec_suid
  guard sec_etc_changes
  guard sec_cron
  guard sec_timers
  guard sec_ssh_keys
  guard sec_firewall
  guard sec_selinux

  guard summary

  if $SAVE_BASELINE; then
    section "BASELINE"
    save_baseline
    info "Baseline saved — future runs will diff against this snapshot."
    _log_plain "Baseline saved to $BASELINE_FILE"
  elif [[ -f "$BASELINE_FILE" ]]; then
    info "  (baseline from $(python3 -c "import json; d=json.load(open('$BASELINE_FILE')); print(d.get('timestamp','?'))" 2>/dev/null || echo '?') in use)"
  else
    info "  Tip: run with --save-baseline to record a trusted snapshot for change detection."
  fi
}

main "$@"
