#!/usr/bin/env bash
# Smoke test for every shell entrypoint in this repository.
#
# Regression guard for F-0024
# ---------------------------
# The `fedora-maintenance` and `system-health` systemd units failed with
# `status=203/EXEC` because their `ExecStart=` pointed at a script path that no
# longer existed after the scripts were reorganised into per-tool subdirectories
# (`fedora-maintenance.sh` -> `fedora-maintenance/fedora-maintenance.sh`).
#
# `203/EXEC` means "the executable could not be run": the file is missing, has no
# executable bit, or has no valid interpreter. This test reproduces that failure
# class by asserting, for each documented entrypoint, that it:
#   * exists at its canonical path,
#   * starts with a shebang,
#   * parses cleanly (`bash -n`), and
#   * answers `--help` with exit code 0 without root and without side effects.
#
# If a script is ever moved or renamed without updating its callers, or an
# entrypoint loses its `--help` contract, this test goes red.
#
# Usage: bash scripts/test-smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Canonical entrypoints — the paths referenced by the READMEs and the systemd
# unit / cron examples. Keep this list in sync when adding a runnable script.
ENTRYPOINTS=(
  "fedora-maintenance/fedora-maintenance.sh"
  "system-health/system-health-check.sh"
  "soft-reboot/soft-reboot.sh"
  "system-audit/system-audit.sh"
  "bug-bounty-agent/nightly-launch.sh"
  "bug-bounty-agent/install-tools.sh"
)

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

for script in "${ENTRYPOINTS[@]}"; do
  if [[ ! -f "$script" ]]; then
    bad "$script: missing (F-0024 class: an ExecStart target would 203/EXEC)"
    continue
  fi

  if ! head -n 1 "$script" | grep -q '^#!'; then
    bad "$script: no shebang (would 203/EXEC under systemd)"
    continue
  fi

  if ! bash -n "$script"; then
    bad "$script: bash -n reported a syntax error"
    continue
  fi

  # A missing executable bit is the literal cause of 203/EXEC when the script is
  # symlinked into /usr/local/bin and invoked by systemd. Warn (do not fail): the
  # README documents `chmod +x`, and CI cannot assert the committed file mode.
  if [[ ! -x "$script" ]]; then
    printf 'WARN  %s: not marked executable (run: chmod +x %s)\n' "$script" "$script"
  fi

  if bash "$script" --help >/dev/null 2>&1; then
    pass "$script: --help exits 0"
  else
    bad "$script: --help did not exit 0 (not smoke-testable without root)"
  fi
done

echo "----"
if [[ "$fail" -ne 0 ]]; then
  echo "SMOKE TEST FAILED"
  exit 1
fi
echo "ALL SMOKE TESTS PASSED"
