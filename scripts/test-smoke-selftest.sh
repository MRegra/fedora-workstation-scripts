#!/usr/bin/env bash
# Self-test for scripts/test-smoke.sh: proves it goes red on each F-0024
# failure mode (systemd `status=203/EXEC`) and stays green on a healthy tree.
# Each case builds a throwaway fixture tree in a temp dir and runs the smoke
# test against it with SMOKE_ROOT.
#
# Usage: bash scripts/test-smoke-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$HERE/test-smoke.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

REPO="/home/user/dev/fedora-workstation-scripts"
status=0

# write_tool <root> <relpath> <mode>: a minimal script that honours --help.
write_tool() {
  mkdir -p "$1/$(dirname "$2")"
  cat >"$1/$2" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then echo usage; exit 0; fi
exit 1
EOF
  chmod "$3" "$1/$2"
}

# write_readme <root> <link-src-relpath> <link-name> <execstart-name>
write_readme() {
  cat >"$1/README.md" <<EOF
\`\`\`bash
sudo ln -s $REPO/$2 /usr/local/bin/$3
\`\`\`

\`\`\`ini
[Service]
ExecStart=/usr/local/bin/$4
\`\`\`
EOF
}

# expect <case> <want: pass|fail> <grep pattern expected in output or ''>
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

# healthy: symlink target exists, is 755, answers --help, ExecStart is linked.
write_tool   "$WORK/healthy" tool/tool.sh 755
write_readme "$WORK/healthy" tool/tool.sh tool tool
expect healthy pass ''

# moved: the README still points at the old path (the literal F-0024 cause).
write_tool   "$WORK/moved" tool/tool.sh 755
write_readme "$WORK/moved" tool.sh tool tool
expect moved fail 'tool.sh: missing'

# noexec: the symlinked script lost its executable bit.
write_tool   "$WORK/noexec" tool/tool.sh 644
write_readme "$WORK/noexec" tool/tool.sh tool tool
expect noexec fail 'not committed as executable'

# unlinked: ExecStart runs a binary no README ln -s line creates.
write_tool   "$WORK/unlinked" tool/tool.sh 755
write_readme "$WORK/unlinked" tool/tool.sh tool other-tool
expect unlinked fail 'no README'

# nohelp: an entrypoint that does not answer --help.
write_tool   "$WORK/nohelp" tool/tool.sh 755
write_readme "$WORK/nohelp" tool/tool.sh tool tool
mkdir -p "$WORK/nohelp/other"
printf '#!/usr/bin/env bash\nexit 3\n' >"$WORK/nohelp/other/other.sh"
expect nohelp fail 'other/other.sh: --help did not exit 0'

echo "----"
if [[ "$status" -ne 0 ]]; then
  echo "SMOKE SELF-TEST FAILED"
  exit 1
fi
echo "SMOKE SELF-TEST PASSED"
