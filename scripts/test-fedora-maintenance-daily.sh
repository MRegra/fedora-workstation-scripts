#!/usr/bin/env bash
# Regression test for F-2584: `fedora-maintenance.sh daily` must default to
# notify-only (list available updates, install nothing) and only fall back to
# the old unattended-install behavior when AUTO_INSTALL=1 is set.
#
# Sources fedora-maintenance.sh (guarded at the bottom so sourcing does not
# invoke main() for real) with a faked `dnf` on PATH that records every
# invocation, then calls daily_mode() directly (with cleanup_system and
# maybe_reboot_hint stubbed out - they are unrelated to this item) and
# asserts whether `dnf -y upgrade` (the install command) ran.
#
# Usage: bash scripts/test-fedora-maintenance-daily.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../fedora-maintenance/fedora-maintenance.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

status=0
pass() { printf 'ok     %s\n' "$1"; }
bad()  { printf 'NOT OK %s\n' "$1"; status=1; }

# Fake dnf: logs every invocation to $DNF_CALLS. Answers `check-update` with
# one sample package and exit 100 (updates available, not a failure);
# answers anything else (e.g. `-y upgrade`, the install path) with exit 0.
cat >"$WORK/dnf" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$DNF_CALLS"
for a in "$@"; do
  if [[ "$a" == "check-update" ]]; then
    echo "kernel.x86_64  6.1.0-1.fc44  updates"
    exit 100
  fi
done
exit 0
EOF
chmod +x "$WORK/dnf"

run_case() {
  local auto_install="$1" want_install="$2"
  local dnf_calls log out rc installed
  dnf_calls="$(mktemp -p "$WORK")"
  log="$(mktemp -p "$WORK")"
  out="$(PATH="$WORK:$PATH" DNF_CALLS="$dnf_calls" AUTO_INSTALL="$auto_install" \
    LOG_FILE="$log" NOTIFY_USER="" bash -c '
      source "'"$SCRIPT"'"
      cleanup_system() { :; }
      maybe_reboot_hint() { :; }
      daily_mode
    ' 2>&1)"
  rc=$?
  installed=0
  grep -q -- '-y upgrade' "$dnf_calls" 2>/dev/null && installed=1
  if [[ "$rc" -ne 0 ]]; then
    bad "AUTO_INSTALL='$auto_install': daily_mode exited $rc: $out"
    return
  fi
  if [[ "$installed" -eq "$want_install" ]]; then
    pass "AUTO_INSTALL='$auto_install': install invoked=$installed (expected $want_install)"
  else
    bad "AUTO_INSTALL='$auto_install': install invoked=$installed (expected $want_install): $out"
  fi
}

run_case ""  0   # default (unset): notify-only, never installs
run_case "0" 0   # explicit opt-out: notify-only, never installs
run_case "1" 1   # explicit opt-in: old unattended-install behavior

if [[ "$status" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
