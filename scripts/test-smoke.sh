#!/usr/bin/env bash
# Smoke test for every shell entrypoint in this repository.
#
# Regression guard for F-0024
# ---------------------------
# `fedora-maintenance.service` failed on the workstation in three ways, one
# after the other:
#   1. `status=203/EXEC`: the unit's `ExecStart=%h/dev/fedora-workstation-scripts/fedora-maintenance.sh`
#      pointed at a path that no longer existed after the scripts moved into
#      per-tool subdirectories (`fedora-maintenance/fedora-maintenance.sh`).
#   2. `status=1/FAILURE` after 4ms: with the path fixed, ExecStart passed no
#      mode argument, and main() prints usage and exits 1 without one.
#   3. Even with a mode, a `systemctl --user` unit runs as the user, and
#      need_root() exits 1 unless the script is started through sudo.
#
# The units are documented in the READMEs, so this test reads the README
# `ln -s` lines and `ExecStart=` lines (not a list kept here) and fails when:
#   * a README `ln -s` source path does not exist in the repo (script moved/renamed),
#     or that script has no shebang or is not committed as executable (100755)   [1]
#   * an `ExecStart=` runs a repo path directly (`%h/.../fedora-workstation-scripts/<path>`
#     or an absolute path) that is missing, has no shebang or is not 100755       [1]
#   * an `ExecStart=` runs a `/usr/local/bin/<name>` or `~/.local/bin/<name>` that no
#     README `ln -s` line creates, or runs nothing from this repo at all          [1]
#   * the script declares `# smoke-modes: <mode> ...` and the ExecStart passes no
#     mode, an unknown mode, or `%i` in a unit that is not a template
#     (`name@.service`), or a `name@<instance>.timer` uses an unknown mode        [2]
#   * a user unit (`~/.config/systemd/user/...`) runs a script that calls
#     need_root without going through sudo                                        [3]
#   * any entrypoint (every `*.sh` outside `scripts/`) fails `bash -n`, does not
#     handle `--help` (checked statically, so it is never run for real), or does
#     not exit 0 on `--help` without root.
#
# Usage: bash scripts/test-smoke.sh
#        SMOKE_ROOT=<dir> bash scripts/test-smoke.sh   # check another tree (self-test)
set -uo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

REPO_MARKER="/fedora-workstation-scripts/"

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

# Committed mode wins over the working-tree mode: the file mode is what a fresh
# clone (and therefore the owner's /usr/local/bin symlink) gets.
is_executable() {
  local f="$1" mode=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mode="$(git ls-files -s -- "$f" | awk '{print $1}')"
  fi
  if [[ -n "$mode" ]]; then
    [[ "$mode" == "100755" ]]
  else
    [[ -x "$f" ]]
  fi
}

has_shebang() { head -n 1 "$1" | grep -q '^#!'; }

# check_target <repo-relative script> <what runs it>: can systemd execute it?
check_target() {
  local script="$1" what="$2"
  if [[ ! -f "$script" ]]; then
    bad "$script: missing, but $what (F-0024: would fail with 203/EXEC)"
  elif ! has_shebang "$script"; then
    bad "$script: no shebang, but $what (would fail with 203/EXEC)"
  elif ! is_executable "$script"; then
    bad "$script: not committed as executable (100755), but $what (would fail with 203/EXEC; fix: git update-index --chmod=+x $script)"
  else
    return 0
  fi
  return 1
}

# Modes a script accepts, from its `# smoke-modes: a b c` line (empty if none).
script_modes() { sed -n 's/^#[[:space:]]*smoke-modes:[[:space:]]*//p' "$1" | head -n 1; }

# Does the script call need_root (not just define it)?
needs_root() { grep -qE '^[[:space:]]*need_root([[:space:]]|$)' "$1"; }

# ---------------------------------------------------------------------------
# 1. Symlink targets documented in the READMEs (what systemd actually executes)
# ---------------------------------------------------------------------------
declare -A LINK_SRC=()   # link name -> repo-relative script path
while read -r src dst; do
  [[ "$src" == *"$REPO_MARKER"* ]] || continue
  rel="${src#*"$REPO_MARKER"}"
  name="$(basename "$dst")"
  if [[ -n "${LINK_SRC[$name]:-}" && "${LINK_SRC[$name]}" != "$rel" ]]; then
    bad "READMEs link '$name' to two different scripts: ${LINK_SRC[$name]} and $rel"
    continue
  fi
  LINK_SRC["$name"]="$rel"
done < <(grep -rhoE --include='*.md' --exclude-dir=.git 'ln +-[A-Za-z]*s[A-Za-z]* +[^ ]+ +[^ ]+' . \
           | awk '{print $(NF-1), $NF}')

if [[ "${#LINK_SRC[@]}" -eq 0 ]]; then
  bad "no README 'ln -s <repo>/<script> <bin>' lines found; cannot verify systemd targets"
fi

declare -A LINKED=()     # repo-relative path -> 1
for name in "${!LINK_SRC[@]}"; do
  script="${LINK_SRC[$name]}"
  LINKED["$script"]=1
  if check_target "$script" "README symlinks it as '$name'"; then
    pass "$script: symlink target '$name' exists, has a shebang and is executable"
  fi
done

# ---------------------------------------------------------------------------
# 2. Every README ExecStart runs an existing script, with arguments it accepts
# ---------------------------------------------------------------------------
# One record per ExecStart line: <file>:<line> US <unit path seen above it> US <command>,
# with US = \037 (a non-whitespace IFS keeps an empty unit field in place).
# The unit is the last `*.service` path mentioned before the ExecStart line in
# the same file (the READMEs put the unit path right above each [Service] block).
# shellcheck disable=SC2016  # the single-quoted $0 belongs to awk, not to bash
mapfile -t EXEC_LINES < <(find . -type f -name '*.md' -not -path './.git/*' -print0 | sort -z \
  | xargs -0 --no-run-if-empty awk '
      FNR == 1 { unit = "" }
      /^ExecStart=/ { print FILENAME ":" FNR "\037" unit "\037" substr($0, 11); next }
      { if (match($0, "[-A-Za-z0-9_.@~%/]*[.]service")) unit = substr($0, RSTART, RLENGTH) }')

if [[ "${#EXEC_LINES[@]}" -eq 0 ]]; then
  bad "no README 'ExecStart=' lines found; cannot verify the documented systemd units"
fi

for rec in "${EXEC_LINES[@]}"; do
  IFS=$'\037' read -r where unit cmd <<<"$rec"
  where="${where#./}"
  read -r -a toks <<<"$cmd"
  # systemd ExecStart prefixes: - @ : + !
  while [[ "${#toks[@]}" -gt 0 && "${toks[0]}" == [-@:+\!]* ]]; do toks[0]="${toks[0]:1}"; done

  script="" idx=-1 via_sudo=0
  for i in "${!toks[@]}"; do
    t="${toks[$i]}"
    if [[ "$t" == *"$REPO_MARKER"* ]]; then
      script="${t#*"$REPO_MARKER"}"
      check_target "$script" "$where ExecStart runs it directly" || script=""
      idx=$i; break
    elif [[ "$t" == */usr/local/bin/* || "$t" == *.local/bin/* ]]; then
      name="${t##*/}"
      if [[ -n "${LINK_SRC[$name]:-}" ]]; then
        script="${LINK_SRC[$name]}"
        [[ -f "$script" ]] || script=""   # already reported in section 1
      else
        bad "$where: ExecStart runs $t but no README 'ln -s' line creates it (F-0024: 203/EXEC)"
      fi
      idx=$i; break
    elif [[ "${t##*/}" == sudo ]]; then
      via_sudo=1
    fi
  done

  if [[ "$idx" -lt 0 ]]; then
    bad "$where: ExecStart does not run a script from this repo: $cmd"
    continue
  fi
  [[ -n "$script" ]] || continue
  args=("${toks[@]:idx+1}")
  ok=1

  modes="$(script_modes "$script")"
  if [[ -n "$modes" ]]; then
    arg="${args[0]:-}"
    if [[ -z "$arg" ]]; then
      bad "$where: ExecStart runs $script with no mode (F-0024: exits 1 with usage); pass one of: $modes"
      ok=0
    elif [[ "$arg" == %[iI] ]]; then
      if [[ "${unit##*/}" != *@.service ]]; then
        bad "$where: ExecStart passes $arg but unit '${unit:-<unknown>}' is not a template (name@.service), so the mode is empty (F-0024: exits 1)"
        ok=0
      else
        base="${unit##*/}"; base="${base%@.service}"
        while read -r inst; do
          [[ -n "$inst" ]] || continue
          if [[ " $modes " != *" $inst "* ]]; then
            bad "timer $base@$inst.timer starts $script with unknown mode '$inst' (accepted: $modes)"
            ok=0
          fi
        done < <(grep -rhoE --include='*.md' --exclude-dir=.git "$base@[A-Za-z0-9_-]+\.timer" . \
                   | sed -E "s/^$base@//; s/\.timer\$//" | sort -u)
      fi
    elif [[ " $modes " != *" $arg "* ]]; then
      bad "$where: ExecStart runs $script with unknown mode '$arg' (accepted: $modes)"
      ok=0
    fi
  fi

  if needs_root "$script" && [[ "$unit" == *systemd/user/* && "$via_sudo" -eq 0 ]]; then
    bad "$where: user unit '$unit' runs $script, which needs root, without sudo (F-0024: need_root exits 1)"
    ok=0
  fi

  [[ "$ok" -eq 1 ]] && pass "$where: ExecStart ${toks[*]} -> $script"
done

# Every declared mode must be a real `case` branch, so the list cannot drift.
while IFS= read -r -d '' script; do
  script="${script#./}"
  for m in $(script_modes "$script"); do
    grep -qE "^[[:space:]]*$m\)" "$script" \
      || bad "$script: '# smoke-modes' lists '$m' but there is no '$m)' case branch"
  done
done < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './scripts/*' -print0)

# ---------------------------------------------------------------------------
# 3. Every entrypoint parses and answers --help without root or side effects
# ---------------------------------------------------------------------------
mapfile -t ENTRYPOINTS < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './scripts/*' \
                             | sed 's#^\./##' | sort)

if [[ "${#ENTRYPOINTS[@]}" -eq 0 ]]; then
  bad "no *.sh entrypoints found under $ROOT"
fi

for script in "${ENTRYPOINTS[@]}"; do
  if ! has_shebang "$script"; then
    bad "$script: no shebang"
    continue
  fi

  if ! bash -n "$script"; then
    bad "$script: bash -n reported a syntax error"
    continue
  fi

  # Scripts run with `bash <script>` (e.g. nightly-launch.sh) need no +x bit;
  # the symlinked ones were already checked strictly above.
  if [[ -z "${LINKED[$script]:-}" ]] && ! is_executable "$script"; then
    printf 'INFO  %s: not executable (run it with: bash %s)\n' "$script" "$script"
  fi

  # Never run a script that does not even mention --help: it would do its real
  # work on the developer's machine instead of printing usage.
  if ! grep -qE -- '(^|[^A-Za-z0-9_-])--help([^A-Za-z0-9_-]|$)' "$script"; then
    bad "$script: does not handle --help (not run; add a --help branch before any side effect)"
    continue
  fi

  if timeout 30 bash "$script" --help </dev/null >/dev/null 2>&1; then
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
