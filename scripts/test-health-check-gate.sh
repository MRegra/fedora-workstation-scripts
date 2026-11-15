#!/usr/bin/env bash
# Regression test for F-2585: fedora-maintenance.sh must run
# system-health-check.sh at the end of daily/monthly/extended (not major,
# which reboots), must find it symlink-safely (the documented install runs
# fedora-maintenance through /usr/local/bin/fedora-maintenance, and systemd/
# cron never resolve that symlink for us), must never fail silently when the
# health check can't be found at all, and must fold the outcome into exactly
# one final notification distinct from system-health-check's own hourly one.
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
# 2. fedora-maintenance.sh wiring: daily/monthly/extended call the gate,
#    major doesn't (major reboots the box right after cleanup; there's no
#    desktop left to notify).
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

for mode in daily monthly extended; do
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
#
#    post_maintenance_health_check() no longer calls notify_user itself: it
#    sets the global HEALTH_NOTE, and on_exit folds it into one final
#    notification (section 4 below). So these cases assert HEALTH_NOTE and
#    the log, not a notify_user call.
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
[[ -n "${DRY_RUN_OVERRIDE:-}" ]] && DRY_RUN="$DRY_RUN_OVERRIDE"
post_maintenance_health_check
printf '%s' "$HEALTH_NOTE" >"$HEALTH_NOTE_FILE"
EOF
chmod +x "$RUNNER"

run_gate() {
  # run_gate <maintenance-path>: wires the common env for $RUNNER and
  # returns its exit code; leaves NOTIFY_LOG/MAINT_LOG/HEALTH_NOTE_FILE for
  # the caller to inspect.
  local maint_path="$1"
  NOTIFY_LOG="$WORK/notify-$2.log"; : >"$NOTIFY_LOG"
  MAINT_LOG="$WORK/maint-$2.log"; : >"$MAINT_LOG"
  HEALTH_NOTE_FILE="$WORK/note-$2.log"; : >"$HEALTH_NOTE_FILE"
  NOTIFY_LOG="$NOTIFY_LOG" MAINT_LOG="$MAINT_LOG" HEALTH_NOTE_FILE="$HEALTH_NOTE_FILE" \
    DRY_RUN_OVERRIDE="${DRY_RUN_OVERRIDE:-}" HEALTH_CHECK_CMD="${HEALTH_CHECK_CMD:-}" \
    PATH="${GATE_PATH:-$PATH}" \
    bash "$RUNNER" "$maint_path"
}

# 3a. flagged: HEALTH_NOTE carries a distinctly-worded reason, not
#     system-health-check's own hourly wording.
bindir="$(fake_free 1600 2000 flagged)"
GATE_PATH="$bindir:$PATH" run_gate "$MAINTENANCE" flagged
rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "post_maintenance_health_check runs to completion when flagged"
else
  bad "post_maintenance_health_check exited non-zero when flagged (should notify, not fail the run)"
fi
note="$(cat "$WORK/note-flagged.log" 2>/dev/null || true)"
if [[ "$note" == *"health check flagged"* && "$note" == *"1600"* ]]; then
  pass "flagged run sets HEALTH_NOTE with a distinct wording carrying the reason"
else
  bad "flagged run's HEALTH_NOTE is missing the distinct wording or the reason: $note"
fi
if [[ ! -s "$WORK/notify-flagged.log" ]]; then
  pass "flagged run does not call notify_user directly (on_exit sends the single final notification)"
else
  bad "flagged run called notify_user directly: $(cat "$WORK/notify-flagged.log")"
fi

# 3b. healthy: HEALTH_NOTE stays empty.
bindir="$(fake_free 100 4000 healthygate)"
GATE_PATH="$bindir:$PATH" run_gate "$MAINTENANCE" healthy
note="$(cat "$WORK/note-healthy.log" 2>/dev/null || true)"
if [[ -z "$note" ]]; then
  pass "healthy run leaves HEALTH_NOTE empty"
else
  bad "healthy run unexpectedly set HEALTH_NOTE: $note"
fi
if grep -q 'no pressure detected' "$WORK/maint-healthy.log"; then
  pass "healthy run logs the health check result"
else
  bad "healthy run did not log a 'no pressure detected' line"
fi

# 3c. no health check can be found anywhere (repo copy missing, nothing on
#     PATH, no /usr/local/bin fallback): this must be LOUD, not a silent
#     skip. (Replaces the old test that accepted a quiet skip as OK.)
mkdir -p "$WORK/isolated"
cp "$MAINTENANCE" "$WORK/isolated/fedora-maintenance.sh"
GATE_PATH="$WORK/isolated-empty-bin:/usr/bin:/bin" run_gate "$WORK/isolated/fedora-maintenance.sh" missing
note="$(cat "$WORK/note-missing.log" 2>/dev/null || true)"
if [[ "$note" == *"NOT run"* ]]; then
  pass "missing health check sets HEALTH_NOTE to 'NOT run' (never a silent skip)"
else
  bad "missing health check did not set a loud HEALTH_NOTE: $note"
fi
if grep -q 'WARN: health check not run' "$WORK/maint-missing.log"; then
  pass "missing health check logs a WARN line"
else
  bad "missing health check did not log a WARN line"
fi

# 3d. REPO_ROOT has no system-health/, but a `system-health-check` stub is on
#     PATH: the PATH fallback must be used instead of skipping.
mkdir -p "$WORK/pathbin"
cat >"$WORK/pathbin/system-health-check" <<EOF
#!/usr/bin/env bash
touch "$WORK/path-fallback-used"
[[ "\$1" == "--check-only" ]] || exit 1
exit 0
EOF
chmod +x "$WORK/pathbin/system-health-check"
rm -f "$WORK/path-fallback-used"
GATE_PATH="$WORK/pathbin:/usr/bin:/bin" run_gate "$WORK/isolated/fedora-maintenance.sh" pathfallback
note="$(cat "$WORK/note-pathfallback.log" 2>/dev/null || true)"
if [[ -e "$WORK/path-fallback-used" ]]; then
  pass "PATH fallback (system-health-check on PATH) is used when the repo copy is absent"
else
  bad "PATH fallback was not invoked; system-health-check on PATH was ignored"
fi
if [[ "$note" != *"NOT run"* ]]; then
  pass "PATH fallback run does not report 'NOT run' (a health check was actually found and run)"
else
  bad "PATH fallback run still reported 'NOT run': $note"
fi

# 3e. installed via the documented symlink (/usr/local/bin/fedora-maintenance,
#     the only way systemd/cron run this script per fedora-maintenance/README.md):
#     the repo's own system-health-check.sh must still be found and run. This
#     is the case the adversary review proved was broken before REPO_ROOT
#     (resolved with readlink -f) replaced the gate's own unresolved,
#     BASH_SOURCE-relative lookup.
mkdir -p "$WORK/usr/local/bin"
ln -s "$MAINTENANCE" "$WORK/usr/local/bin/fedora-maintenance"
bindir="$(fake_free 1600 2000 symlink)"
GATE_PATH="$bindir:$PATH" run_gate "$WORK/usr/local/bin/fedora-maintenance" symlink
note="$(cat "$WORK/note-symlink.log" 2>/dev/null || true)"
if [[ "$note" == *"health check flagged"* && "$note" == *"1600"* ]]; then
  pass "symlinked install still finds and runs the repo's health check"
else
  bad "symlinked install skipped or lost the health check: $note"
fi

# ---------------------------------------------------------------------------
# 4. on_exit(): the gate's outcome is folded into exactly one final
#    notification, never a second one stacked on top of/after it.
# ---------------------------------------------------------------------------
ONEXIT_RUNNER="$WORK/run-onexit.sh"
cat >"$ONEXIT_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1090
source "$1"
notify_user() { printf '%s|%s\n' "$1" "$2" >>"$NOTIFY_LOG"; }
MODE="daily"
HEALTH_NOTE="${HEALTH_NOTE_VALUE:-}"
true   # make $? 0 right before on_exit, like a successful main() return
on_exit
EOF
chmod +x "$ONEXIT_RUNNER"

NOTIFY_LOG="$WORK/notify-onexit-flagged.log"; : >"$NOTIFY_LOG"
NOTIFY_LOG="$NOTIFY_LOG" HEALTH_NOTE_VALUE="health check flagged: swap used 1600MiB" \
  bash "$ONEXIT_RUNNER" "$MAINTENANCE"
calls="$(wc -l <"$NOTIFY_LOG" | tr -d ' ')"
call="$(cat "$NOTIFY_LOG")"
if [[ "$calls" -eq 1 ]]; then
  pass "on_exit with HEALTH_NOTE set sends exactly one notification"
else
  bad "on_exit with HEALTH_NOTE set sent $calls notifications (expected 1): $call"
fi
if [[ "$call" == "fail|Maintenance ran (daily); health check flagged: swap used 1600MiB" ]]; then
  pass "on_exit's single notification has status 'fail' and the distinct 'Maintenance ran' wording"
else
  bad "on_exit's notification text/status is wrong: $call"
fi

NOTIFY_LOG="$WORK/notify-onexit-healthy.log"; : >"$NOTIFY_LOG"
NOTIFY_LOG="$NOTIFY_LOG" HEALTH_NOTE_VALUE="" \
  bash "$ONEXIT_RUNNER" "$MAINTENANCE"
calls="$(wc -l <"$NOTIFY_LOG" | tr -d ' ')"
call="$(cat "$NOTIFY_LOG")"
if [[ "$calls" -eq 1 && "$call" == "ok|Completed (daily)" ]]; then
  pass "on_exit with HEALTH_NOTE empty sends exactly one 'Completed (daily)' notification"
else
  bad "on_exit with HEALTH_NOTE empty sent an unexpected notification: $call"
fi

# ---------------------------------------------------------------------------
# 5. DRY_RUN=1: the health check itself must never run, and the preview line
#    must be deterministic regardless of which lookup step would have found it.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/dryrunbin"
DRYRUN_MARKER="$WORK/dryrun-health-check-invoked"
rm -f "$DRYRUN_MARKER"
cat >"$WORK/dryrunbin/stub-health-check.sh" <<EOF
#!/usr/bin/env bash
touch "$DRYRUN_MARKER"
exit 1
EOF
chmod +x "$WORK/dryrunbin/stub-health-check.sh"

DRY_RUN_OVERRIDE=1 HEALTH_CHECK_CMD="$WORK/dryrunbin/stub-health-check.sh" \
  run_gate "$MAINTENANCE" dryrun >"$WORK/dryrun.out"
if [[ -e "$DRYRUN_MARKER" ]]; then
  bad "DRY_RUN=1 still invoked the health check"
else
  pass "DRY_RUN=1 never invokes the health check, even with HEALTH_CHECK_CMD set"
fi
if grep -q 'WOULD RUN: system-health-check --check-only' "$WORK/dryrun.out"; then
  pass "DRY_RUN=1 prints the deterministic 'WOULD RUN' preview line"
else
  bad "DRY_RUN=1 did not print the expected preview line"
fi
if grep -q 'DRY-RUN:' "$WORK/maint-dryrun.log"; then
  pass "DRY_RUN=1 logs a DRY-RUN line for the health check step"
else
  bad "DRY_RUN=1 did not log a DRY-RUN line"
fi

echo "----"
if [[ "$fail" -ne 0 ]]; then
  echo "HEALTH CHECK GATE TEST FAILED"
  exit 1
fi
echo "ALL HEALTH CHECK GATE TESTS PASSED"
