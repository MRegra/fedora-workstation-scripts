#!/usr/bin/env bash
# Regression test for F-2583: `fedora-maintenance <mode> --dry-run` must list
# the pending dnf/flatpak/firmware/kernel-prune/upgrade actions without
# running any of them.
#
# fedora-maintenance.sh always requires real root (need_root(), EUID is a
# bash builtin that cannot be faked in a sandbox), so this test cannot drive
# the CLI end-to-end here. Instead it sources the script (guarded at the
# bottom so sourcing does not call main()) and exercises the per-mode action
# functions directly - the same functions main() calls for daily/monthly/major.
#
# dnf/flatpak/fwupdmgr are stubbed on PATH; each stub touches a marker file
# when invoked for anything other than a read-only query (dnf repoquery).
# With DRY_RUN=1 no marker must appear for any mode, including major (whose
# system-upgrade reboot trigger is irreversible - see F-2583 triage). With
# DRY_RUN=0 the markers must still appear, proving the stubs/test are wired
# correctly and that normal (non-dry-run) behaviour is unchanged.
#
# Usage: bash scripts/test-dry-run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/fedora-maintenance/fedora-maintenance.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

mkdir -p "$WORK/bin" "$WORK/markers"

write_stub() {
  local name="$1" body="$2"
  cat >"$WORK/bin/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod 755 "$WORK/bin/$name"
}

MARKERS="$WORK/markers"
write_stub dnf "
case \"\$*\" in
  *repoquery*) echo 'kernel-0:6.0.0-300.fc44.x86_64'; exit 0 ;;
  *) touch '$MARKERS/dnf-mutated'; exit 0 ;;
esac
"
write_stub flatpak "touch '$MARKERS/flatpak-mutated'; exit 0"
write_stub fwupdmgr "touch '$MARKERS/fwupdmgr-mutated'; exit 0"
write_stub needs-restarting "exit 0"
write_stub rpm "[[ \"\$*\" == *%fedora* ]] && echo 44 || exit 0"

# Source the script for its functions without running main() (bottom guard).
LOG_FILE="$WORK/maintenance.log"
# shellcheck source=/dev/null
source "$SCRIPT"

# Every mutating action a mode takes, run under DRY_RUN. Safe to call for
# real too (all commands are stubbed, see above) EXCEPT cleanup_system()
# and major_version_upgrade(), which also shell out to the real, unstubbed
# rm/journalctl/reboot-trigger when DRY_RUN=0 - so the "real commands still
# run" proof below deliberately uses only dnf_update_daily/firmware, never
# those two, to stay inside the guardrails (no real rm/journal/reboot here).
run_dry_actions() {
  local mode="$1"
  case "$mode" in
    # Both daily paths: notify-only (default) and AUTO_INSTALL=1 (install).
    daily) AUTO_INSTALL=0 daily_mode && AUTO_INSTALL=1 daily_mode ;;
    monthly) dnf_update_daily && firmware_update_monthly && flatpak_update && cleanup_system && maybe_reboot_hint ;;
    major) dnf_update_daily && flatpak_update && cleanup_system && major_version_upgrade ;;
  esac
}

check_mode() {
  local mode="$1"
  rm -rf "$MARKERS"
  mkdir -p "$MARKERS"
  : >"$LOG_FILE"

  DRY_RUN=1
  local rc=0
  PATH="$WORK/bin:$PATH" run_dry_actions "$mode" >/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "$mode --dry-run: action functions returned non-zero ($rc)"
  else
    pass "$mode --dry-run: action functions exit 0"
  fi

  local marker leftover=0
  for marker in dnf-mutated flatpak-mutated fwupdmgr-mutated; do
    if [[ -e "$MARKERS/$marker" ]]; then
      bad "$mode --dry-run: $marker fired (a real command ran, system was modified)"
      leftover=1
    fi
  done
  [[ "$leftover" -eq 0 ]] && pass "$mode --dry-run: no dnf/flatpak/firmware command was executed"

  # Prove the opposite: without --dry-run, the stubbed dnf command does get
  # invoked (otherwise this test would pass even with the feature ripped
  # out). Only dnf_update_daily is exercised here, never cleanup_system()/
  # major_version_upgrade(), which also call the real rm/journalctl/reboot
  # trigger once DRY_RUN=0 and must not run for real in this sandbox.
  rm -rf "$MARKERS"
  mkdir -p "$MARKERS"
  : >"$LOG_FILE"
  # shellcheck disable=SC2034  # DRY_RUN is read by the sourced script's functions
  DRY_RUN=0
  rc=0
  PATH="$WORK/bin:$PATH" dnf_update_daily >/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "$mode (no --dry-run): dnf_update_daily returned non-zero ($rc)"
  else
    pass "$mode (no --dry-run): dnf_update_daily exits 0"
  fi
  if [[ -e "$MARKERS/dnf-mutated" ]]; then
    pass "$mode (no --dry-run): dnf was invoked for real (test wiring confirmed)"
  else
    bad "$mode (no --dry-run): dnf-mutated never fired; test stub/wiring is broken"
  fi
}

for m in daily monthly major; do
  check_mode "$m"
done

echo "----"
if [[ "$fail" -ne 0 ]]; then
  echo "DRY-RUN TEST FAILED"
  exit 1
fi
echo "ALL DRY-RUN TESTS PASSED"
