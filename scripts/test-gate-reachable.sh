#!/usr/bin/env bash
# Regression test for F-2585 (adversary review round): the post-maintenance
# health-check gate must actually be *reached* under fedora-maintenance.sh's
# `set -Eeuo pipefail`, not just behave correctly when called in isolation.
#
# Two steps that run right before the gate return an *expected*, non-failure
# non-zero exit code on common days:
#   - maybe_reboot_hint: `needs-restarting -r` exits 1 when a reboot is
#     recommended (normal right after a kernel/glibc update).
#   - check_updates_daily: `dnf check-update --refresh` exits 100 when
#     updates are available (the common case for the default notify-only
#     daily run).
# Before the fix, both captured rc with a bare `cmd; rc="$?"`, which is an
# unguarded simple command: under `set -e` the shell exits right there and
# `rc="$?"` is never reached (BashFAQ/105), aborting the whole run before
# post_maintenance_health_check ever executes. on_exit then reports
# "Failed (MODE)" instead of a health result - on exactly the runs where the
# safety net matters most.
#
# Each case below sources the real script (its own `set -Eeuo pipefail`
# stays in effect) in a separate bash process, drives the pre-gate step with
# a stub that returns the expected non-zero code, and asserts the process
# does NOT abort and the gate still runs.
#
# Usage: bash scripts/test-gate-reachable.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAINTENANCE="$HERE/fedora-maintenance/fedora-maintenance.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

# ---------------------------------------------------------------------------
# A. maybe_reboot_hint; post_maintenance_health_check - reboot recommended
#    (needs-restarting -r exits 1) must not abort the script before the gate.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin-a"
cat >"$WORK/bin-a/needs-restarting" <<'EOF'
#!/usr/bin/env bash
# -r: reboot recommended. Real needs-restarting exits 1 for this.
exit 1
EOF
chmod +x "$WORK/bin-a/needs-restarting"

GATE_MARKER_A="$WORK/gate-ran-a"
rm -f "$GATE_MARKER_A"
cat >"$WORK/health-stub-a.sh" <<EOF
#!/usr/bin/env bash
touch "$GATE_MARKER_A"
exit 0
EOF
chmod +x "$WORK/health-stub-a.sh"

RUNNER_A="$WORK/run-a.sh"
cat >"$RUNNER_A" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1090
source "$1"
LOG_FILE="$MAINT_LOG"
MODE="monthly"
maybe_reboot_hint
post_maintenance_health_check
EOF
chmod +x "$RUNNER_A"

MAINT_LOG_A="$WORK/maint-a.log"; : >"$MAINT_LOG_A"
out_a="$(PATH="$WORK/bin-a:$PATH" MAINT_LOG="$MAINT_LOG_A" HEALTH_CHECK_CMD="$WORK/health-stub-a.sh" \
  bash "$RUNNER_A" "$MAINTENANCE" 2>&1)"
rc_a=$?

if [[ "$rc_a" -eq 0 ]]; then
  pass "reboot-recommended (needs-restarting -r exits 1) does not abort the run"
else
  bad "reboot-recommended aborted the run with rc=$rc_a (set -e tripped before the gate): $out_a"
fi
if [[ -e "$GATE_MARKER_A" ]]; then
  pass "post_maintenance_health_check still ran after a reboot recommendation"
else
  bad "post_maintenance_health_check did NOT run after a reboot recommendation"
fi

# ---------------------------------------------------------------------------
# B. daily_mode(); post_maintenance_health_check - pending updates
#    (dnf check-update --refresh exits 100) must not abort the default
#    notify-only daily run before the gate.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin-b"
cat >"$WORK/bin-b/dnf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "check-update" ]]; then
    echo "kernel.x86_64  6.1.0-1.fc44  updates"
    exit 100
  fi
done
exit 0
EOF
chmod +x "$WORK/bin-b/dnf"
# daily_mode also calls maybe_reboot_hint; keep needs-restarting absent so it
# takes the "not found" branch and stays out of this case's way.

GATE_MARKER_B="$WORK/gate-ran-b"
rm -f "$GATE_MARKER_B"
cat >"$WORK/health-stub-b.sh" <<EOF
#!/usr/bin/env bash
touch "$GATE_MARKER_B"
exit 0
EOF
chmod +x "$WORK/health-stub-b.sh"

RUNNER_B="$WORK/run-b.sh"
cat >"$RUNNER_B" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1090
source "$1"
LOG_FILE="$MAINT_LOG"
MODE="daily"
AUTO_INSTALL="0"
NOTIFY_USER=""
notify_user() { :; }
cleanup_system() { :; }
daily_mode
post_maintenance_health_check
EOF
chmod +x "$RUNNER_B"

MAINT_LOG_B="$WORK/maint-b.log"; : >"$MAINT_LOG_B"
out_b="$(PATH="$WORK/bin-b:/usr/bin:/bin" MAINT_LOG="$MAINT_LOG_B" HEALTH_CHECK_CMD="$WORK/health-stub-b.sh" \
  bash "$RUNNER_B" "$MAINTENANCE" 2>&1)"
rc_b=$?

if [[ "$rc_b" -eq 0 ]]; then
  pass "pending updates (dnf check-update exits 100) does not abort the default daily run"
else
  bad "pending updates aborted the daily run with rc=$rc_b (set -e tripped before the gate): $out_b"
fi
if [[ -e "$GATE_MARKER_B" ]]; then
  pass "post_maintenance_health_check still ran after the daily run found pending updates"
else
  bad "post_maintenance_health_check did NOT run after the daily run found pending updates"
fi


# ---------------------------------------------------------------------------
# C. cleanup_system(); post_maintenance_health_check - repoquery (used to
#    prune old kernels) returning non-zero must not abort the run either.
#    cleanup_system runs right before the gate in every mode.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin-c"
cat >"$WORK/bin-c/dnf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "repoquery" ]]; then
    # Simulate a transient/unexpected repoquery failure.
    exit 1
  fi
done
exit 0
EOF
chmod +x "$WORK/bin-c/dnf"
# cleanup_system also runs `rm -rf /root/.cache/*` (run_cmd_optional, already
# safe under set -e either way); stub it out so this test never touches the
# real filesystem regardless of what user/permissions run it.
cat >"$WORK/bin-c/rm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin-c/rm"

GATE_MARKER_C="$WORK/gate-ran-c"
rm -f "$GATE_MARKER_C"
cat >"$WORK/health-stub-c.sh" <<EOF
#!/usr/bin/env bash
touch "$GATE_MARKER_C"
exit 0
EOF
chmod +x "$WORK/health-stub-c.sh"

RUNNER_C="$WORK/run-c.sh"
cat >"$RUNNER_C" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1090
source "$1"
LOG_FILE="$MAINT_LOG"
MODE="monthly"
JOURNAL_DAYS="0"
cleanup_system
post_maintenance_health_check
EOF
chmod +x "$RUNNER_C"

MAINT_LOG_C="$WORK/maint-c.log"; : >"$MAINT_LOG_C"
out_c="$(PATH="$WORK/bin-c:/usr/bin:/bin" MAINT_LOG="$MAINT_LOG_C" HEALTH_CHECK_CMD="$WORK/health-stub-c.sh" \
  bash "$RUNNER_C" "$MAINTENANCE" 2>&1)"
rc_c=$?

if [[ "$rc_c" -eq 0 ]]; then
  pass "a failing repoquery (old-kernel prune) does not abort the run"
else
  bad "a failing repoquery aborted the run with rc=$rc_c (set -e tripped before the gate): $out_c"
fi
if [[ -e "$GATE_MARKER_C" ]]; then
  pass "post_maintenance_health_check still ran after a failing repoquery"
else
  bad "post_maintenance_health_check did NOT run after a failing repoquery"
fi

echo "----"
if [[ "$fail" -ne 0 ]]; then
  echo "GATE REACHABILITY TEST FAILED"
  exit 1
fi
echo "ALL GATE REACHABILITY TESTS PASSED"
