#!/usr/bin/env bash
# Self-test for scripts/test-smoke.sh: proves it goes red on each F-0024
# failure mode and stays green on a healthy tree. Each case builds a throwaway
# fixture tree in a temp dir and runs the smoke test against it with SMOKE_ROOT.
#
# F-0024 failure modes (see the header of test-smoke.sh):
#   1. 203/EXEC  - ExecStart points at a moved/missing/non-executable script
#                  (through a README symlink or directly at a repo path)
#   2. exit 1    - ExecStart passes no mode (or %i in a non-template unit)
#   3. exit 1    - a user unit runs a root-only script without sudo
#
# Usage: bash scripts/test-smoke-selftest.sh
#
# shellcheck disable=SC2016  # fixtures deliberately write literal $ and backticks
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$HERE/test-smoke.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

REPO="/home/user/dev/fedora-workstation-scripts"
status=0

# write_tool <root> <relpath> <chmod>: a minimal script that honours --help.
write_tool() {
  mkdir -p "$1/$(dirname "$2")"
  cat >"$1/$2" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then echo usage; exit 0; fi
exit 1
EOF
  chmod "$3" "$1/$2"
}

# write_modal_tool <root> <relpath>: like fedora-maintenance.sh, it needs a mode
# (daily|monthly) and root.
write_modal_tool() {
  mkdir -p "$1/$(dirname "$2")"
  cat >"$1/$2" <<'EOF'
#!/usr/bin/env bash
# smoke-modes: daily monthly
need_root() { [[ "$EUID" -eq 0 ]] || exit 1; }
if [[ "${1:-}" == "--help" ]]; then echo usage; exit 0; fi
need_root
case "${1:-}" in
  daily) exit 0 ;;
  monthly) exit 0 ;;
esac
exit 1
EOF
  chmod 755 "$1/$2"
}

# link <root> <link-src-relpath> <link-name>: README `ln -s` line.
link() { printf 'sudo ln -s %s/%s /usr/local/bin/%s\n\n' "$REPO" "$2" "$3" >>"$1/README.md"; }

# unit <root> <unit-path> <ExecStart command>: README unit block.
unit() {
  printf '`%s`\n\n```ini\n[Service]\nType=oneshot\nExecStart=%s\n```\n\n' "$2" "$3" >>"$1/README.md"
}

# expect <case> <want: pass|fail> <text expected in the output, or ''>
expect() {
  local name="$1" want="$2" pattern="$3" out rc
  out="$(SMOKE_ROOT="$WORK/$name" bash "$SMOKE" 2>&1)"; rc=$?
  if [[ "$want" == pass && "$rc" -eq 0 ]] \
     || [[ "$want" == fail && "$rc" -ne 0 && ( -z "$pattern" || "$out" == *"$pattern"* ) ]]; then
    printf 'ok    %s (exit %d)\n' "$name" "$rc"
  else
    printf 'NOT OK %s: wanted %s (output matching "%s"), got exit %d\n%s\n' \
      "$name" "$want" "$pattern" "$rc" "$out"
    status=1
  fi
}

SYS=/etc/systemd/system
USR=/home/user/.config/systemd/user

# healthy: every documented shape that works, including `ln -sf`, a direct repo
# path, a template unit with valid instances and a user unit going through sudo.
write_tool       "$WORK/healthy" tool/tool.sh 755
write_modal_tool "$WORK/healthy" maint/maint.sh
link "$WORK/healthy" tool/tool.sh tool
printf 'ln -sf %s/maint/maint.sh ~/.local/bin/maint\n\n' "$REPO" >>"$WORK/healthy/README.md"
unit "$WORK/healthy" "$SYS/tool.service" /usr/local/bin/tool
unit "$WORK/healthy" "$SYS/tool2.service" "%h/dev/fedora-workstation-scripts/tool/tool.sh"
unit "$WORK/healthy" "$SYS/maint@.service" "%h/.local/bin/maint %i"
printf '`%s/maint@daily.timer`\n\n`%s/maint@monthly.timer`\n\n' "$SYS" "$SYS" >>"$WORK/healthy/README.md"
unit "$WORK/healthy" "$USR/maint.service" "/usr/bin/sudo -n $REPO/maint/maint.sh daily"
expect healthy pass ''

# moved: the README symlink still points at the old path (203/EXEC).
write_tool "$WORK/moved" tool/tool.sh 755
link "$WORK/moved" tool.sh tool
unit "$WORK/moved" "$SYS/tool.service" /usr/local/bin/tool
expect moved fail 'tool.sh: missing'

# direct-moved: the literal F-0024 unit, ExecStart straight at an old repo path.
write_tool "$WORK/direct-moved" tool/tool.sh 755
link "$WORK/direct-moved" tool/tool.sh tool
unit "$WORK/direct-moved" "$USR/tool.service" "%h/dev/fedora-workstation-scripts/tool.sh"
expect direct-moved fail 'tool.sh: missing, but README.md:'

# noexec: the symlinked script lost its executable bit.
write_tool "$WORK/noexec" tool/tool.sh 644
link "$WORK/noexec" tool/tool.sh tool
unit "$WORK/noexec" "$SYS/tool.service" /usr/local/bin/tool
expect noexec fail 'not committed as executable'

# unlinked: ExecStart runs a binary no README ln -s line creates.
write_tool "$WORK/unlinked" tool/tool.sh 755
link "$WORK/unlinked" tool/tool.sh tool
unit "$WORK/unlinked" "$SYS/tool.service" /usr/local/bin/other-tool
expect unlinked fail 'no README'

# foreign: ExecStart runs nothing from this repo (would otherwise be skipped).
write_tool "$WORK/foreign" tool/tool.sh 755
link "$WORK/foreign" tool/tool.sh tool
unit "$WORK/foreign" "$SYS/tool.service" /opt/somewhere/tool.sh
expect foreign fail 'does not run a script from this repo'

# no-mode: ExecStart gives a mode-taking script no mode (F-0024, 2026-09-27).
write_modal_tool "$WORK/no-mode" maint/maint.sh
link "$WORK/no-mode" maint/maint.sh maint
unit "$WORK/no-mode" "$SYS/maint.service" /usr/local/bin/maint
expect no-mode fail 'with no mode'

# pct-i-plain: %i in a non-template unit expands to nothing, so no mode either.
write_modal_tool "$WORK/pct-i-plain" maint/maint.sh
link "$WORK/pct-i-plain" maint/maint.sh maint
unit "$WORK/pct-i-plain" "$USR/maint.service" "/usr/bin/sudo -n /usr/local/bin/maint %i"
expect pct-i-plain fail 'is not a template'

# bad-mode: an unknown mode.
write_modal_tool "$WORK/bad-mode" maint/maint.sh
link "$WORK/bad-mode" maint/maint.sh maint
unit "$WORK/bad-mode" "$SYS/maint.service" "/usr/local/bin/maint weekly"
expect bad-mode fail "unknown mode 'weekly'"

# bad-instance: a template timer instance that is not a mode.
write_modal_tool "$WORK/bad-instance" maint/maint.sh
link "$WORK/bad-instance" maint/maint.sh maint
unit "$WORK/bad-instance" "$SYS/maint@.service" "/usr/local/bin/maint %i"
printf '`%s/maint@weekly.timer`\n' "$SYS" >>"$WORK/bad-instance/README.md"
expect bad-instance fail "maint@weekly.timer"

# user-no-sudo: a user unit runs the root-only script as the user.
write_modal_tool "$WORK/user-no-sudo" maint/maint.sh
link "$WORK/user-no-sudo" maint/maint.sh maint
unit "$WORK/user-no-sudo" "$USR/maint.service" "%h/dev/fedora-workstation-scripts/maint/maint.sh daily"
expect user-no-sudo fail 'needs root, without sudo'

# mode-drift: '# smoke-modes' lists a mode the script does not handle.
write_modal_tool "$WORK/mode-drift" maint/maint.sh
sed -i 's/^# smoke-modes: daily monthly$/# smoke-modes: daily monthly weekly/' "$WORK/mode-drift/maint/maint.sh"
link "$WORK/mode-drift" maint/maint.sh maint
unit "$WORK/mode-drift" "$SYS/maint.service" "/usr/local/bin/maint daily"
expect mode-drift fail "no 'weekly)' case branch"

# nohelp: an entrypoint with no --help branch is reported and never run.
write_tool "$WORK/nohelp" tool/tool.sh 755
link "$WORK/nohelp" tool/tool.sh tool
unit "$WORK/nohelp" "$SYS/tool.service" /usr/local/bin/tool
mkdir -p "$WORK/nohelp/other"
printf '#!/usr/bin/env bash\ntouch "$(dirname "$0")/RAN"\n' >"$WORK/nohelp/other/other.sh"
expect nohelp fail 'other/other.sh: does not handle --help (not run'
if [[ -e "$WORK/nohelp/other/RAN" ]]; then
  printf 'NOT OK nohelp: the smoke test executed a script without a --help branch\n'
  status=1
fi

# help-fails: an entrypoint whose --help branch exits non-zero.
write_tool "$WORK/help-fails" tool/tool.sh 755
link "$WORK/help-fails" tool/tool.sh tool
unit "$WORK/help-fails" "$SYS/tool.service" /usr/local/bin/tool
mkdir -p "$WORK/help-fails/other"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--help" ]] && exit 3\n' >"$WORK/help-fails/other/other.sh"
expect help-fails fail 'other/other.sh: --help did not exit 0'

echo "----"
if [[ "$status" -ne 0 ]]; then
  echo "SMOKE SELF-TEST FAILED"
  exit 1
fi
echo "SMOKE SELF-TEST PASSED"
