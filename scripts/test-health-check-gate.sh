#!/usr/bin/env bash
# Regression test for F-2585: fedora-maintenance.sh must run
# system-health-check.sh at the end of daily/monthly (not major, which
# reboots), and must mark the resulting notification distinctly (via
# notify_user) from system-health-check's own hourly notification when the
# health check flags memory/swap pressure right after a maintenance run.
#
# Usage: bash scripts/test-health-check-gate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH_CHECK="$HERE/system-health/system-health-check.sh"
MAINTENANCE="$HERE/fedora-maintenance/fedora-maintenance.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

# fake_free <swap_used_mb> <ram_avail_mb> <tag>: prints a bin dir containing a
# `free` that reports controlled figures, so tests don't depend on this
# machine's real memory/swap state.
fake_free() {
  local swap_used="$1" ram_avail="$2" dir="$WORK/bin-$3"
  mkdir -p "$dir"
  cat >"$dir/free" <<EOF
#!/usr/bin/env bash
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:           16000        4000        4000         500        8000     ${ram_avail}"
echo "Swap:           8192        ${swap_used}        $((8192 - swap_used))"
EOF
  chmod +x "$dir/free"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# 1. system-health-check.sh --check-only: unit behaviour
# ---------------------------------------------------------------------------
bindir="$(fake_free 1600 2000 pressure)"
if out="$(PATH="$bindir:$PATH" "$HEALTH_CHECK" --check-only)"; then
  bad "--check-only exited 0 with swap pressure (expected 1); output: $out"
else
  if [[ "$out" == *"1600"* ]]; then
    pass "--check-only flags swap pressure and prints the reason"
  else
    bad "--check-only flagged pressure but the reason is missing the swap figure: $out"
  fi
fi

bindir="$(fake_free 100 500 lowram)"
if out="$(PATH="$bindir:$PATH" "$HEALTH_CHECK" --check-only)"; then
  bad "--check-only exited 0 with low RAM (expected 1); output: $out"
else
  if [[ "$out" == *"500"* ]]; then
    pass "--check-only flags low RAM and prints the reason"
  else
    bad "--check-only flagged low RAM but the reason is missing the RAM figure: $out"
  fi
fi

bindir="$(fake_free 100 4000 healthy)"
if out="$(PATH="$bindir:$PATH" "$HEALTH_CHECK" --check-only)"; then
  pass "--check-only exits 0 when no pressure"
else
  bad "--check-only exited non-zero with no pressure; output: $out"
fi

# ---------------------------------------------------------------------------
# 2. fedora-maintenance.sh wiring: daily/monthly call the gate, major doesn't
#    (major reboots the box right after cleanup; there's no desktop left to
#    notify).
# ---------------------------------------------------------------------------
case_body() {
  # case_body <mode>: the lines of the named case branch in main()'s case
  # statement, up to its closing ';;'.
  awk -v mode="$1" '
    $0 ~ "^[[:space:]]*" mode "\\)" { grab = 1; next }
    grab && /;;/ { exit }
    grab { print }
  ' "$MAINTENANCE"
}

for mode in daily monthly; do
  if case_body "$mode" | grep -q 'post_maintenance_health_check'; then
    pass "mode '$mode' calls post_maintenance_health_check at the end of its run"
  else
    bad "mode '$mode' does not call post_maintenance_health_check"
  fi
done

if case_body major | grep -q 'post_maintenance_health_check'; then
  bad "mode 'major' calls post_maintenance_health_check, but major reboots right after"
else
  pass "mode 'major' does not call post_maintenance_health_check"
fi

# ---------------------------------------------------------------------------
# 3. post_maintenance_health_check(): behaviour in isolation. Sourced in a
#    separate bash process (not this test's own shell) so fedora-maintenance.sh's
#    `set -Eeuo pipefail` and globals never leak into this test script.
# ---------------------------------------------------------------------------
RUNNER="$WORK/run-check.sh"
cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1090  # path is supplied by the caller, not this file
source "$1"
notify_user() { printf '%s|%s\n' "$1" "$2" >>"$NOTIFY_LOG"; }
LOG_FILE="$MAINT_LOG"
MODE="daily"
post_maintenance_health_check
EOF
chmod +x "$RUNNER"

# 3a. flagged: notify_user gets a distinctly-worded "maintenance ran" message,
#     not system-health-check's own hourly wording.
bindir="$(fake_free 1600 2000 flagged)"
NOTIFY_LOG="$WORK/notify-flagged.log"; : >"$NOTIFY_LOG"
MAINT_LOG="$WORK/maint-flagged.log"; : >"$MAINT_LOG"
if NOTIFY_LOG="$NOTIFY_LOG" MAINT_LOG="$MAINT_LOG" PATH="$bindir:$PATH" \
    bash "$RUNNER" "$MAINTENANCE"; then
  pass "post_maintenance_health_check runs to completion when flagged"
else
  bad "post_maintenance_health_check exited non-zero when flagged (should notify, not fail the run)"
fi
call="$(cat "$NOTIFY_LOG" 2>/dev/null || true)"
if [[ "$call" == *"Maintenance ran (daily)"* && "$call" == *"flagged"* && "$call" == *"1600"* ]]; then
  pass "flagged run notifies with a maintenance-distinct message carrying the reason"
else
  bad "flagged run's notify_user call is missing the distinct wording or the reason: $call"
fi

# 3b. healthy: no extra notification beyond the normal end-of-run one.
bindir="$(fake_free 100 4000 healthygate)"
NOTIFY_LOG="$WORK/notify-healthy.log"; : >"$NOTIFY_LOG"
MAINT_LOG="$WORK/maint-healthy.log"; : >"$MAINT_LOG"
NOTIFY_LOG="$NOTIFY_LOG" MAINT_LOG="$MAINT_LOG" PATH="$bindir:$PATH" \
  bash "$RUNNER" "$MAINTENANCE"
if [[ -s "$NOTIFY_LOG" ]]; then
  bad "healthy run unexpectedly called notify_user: $(cat "$NOTIFY_LOG")"
else
  pass "healthy run sends no extra notification"
fi
if grep -q 'no pressure detected' "$MAINT_LOG"; then
  pass "healthy run logs the health check result"
else
  bad "healthy run did not log a 'no pressure detected' line"
fi

# 3c. the health-check script is missing: skip quietly, never fail the run.
mkdir -p "$WORK/isolated"
cp "$MAINTENANCE" "$WORK/isolated/fedora-maintenance.sh"
NOTIFY_LOG="$WORK/notify-missing.log"; : >"$NOTIFY_LOG"
MAINT_LOG="$WORK/maint-missing.log"; : >"$MAINT_LOG"
if NOTIFY_LOG="$NOTIFY_LOG" MAINT_LOG="$MAINT_LOG" \
    bash "$RUNNER" "$WORK/isolated/fedora-maintenance.sh"; then
  pass "post_maintenance_health_check skips quietly when system-health-check.sh is missing"
else
  bad "post_maintenance_health_check failed the run when system-health-check.sh is missing"
fi

echo "----"
if [[ "$fail" -ne 0 ]]; then
  echo "HEALTH CHECK GATE TEST FAILED"
  exit 1
fi
echo "ALL HEALTH CHECK GATE TESTS PASSED"
