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
# executable bit, or has no valid interpreter. The units run the scripts through
# the symlinks the READMEs tell you to create (`ln -s <repo>/<path> /usr/local/bin/<name>`),
# so this test reads those paths from the READMEs themselves, not from a list kept
# here. It fails when:
#   * a README `ln -s` source path does not exist in the repo (script moved/renamed),
#   * that symlinked script has no shebang or is not committed as executable (100755),
#   * a README `ExecStart=` runs a `/usr/local/bin/<name>` (or `~/.local/bin/<name>`)
#     that no README `ln -s` line creates,
#   * any entrypoint (every `*.sh` outside `scripts/`) fails `bash -n` or does not
#     exit 0 on `--help` without root.
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
done < <(grep -rhoE --include='*.md' --exclude-dir=.git 'ln -s +[^ ]+ +[^ ]+' . \
           | awk '{print $(NF-1), $NF}')

if [[ "${#LINK_SRC[@]}" -eq 0 ]]; then
  bad "no README 'ln -s <repo>/<script> <bin>' lines found; cannot verify systemd targets"
fi

declare -A LINKED=()     # repo-relative path -> 1
for name in "${!LINK_SRC[@]}"; do
  script="${LINK_SRC[$name]}"
  LINKED["$script"]=1
  if [[ ! -f "$script" ]]; then
    bad "$script: missing, but README symlinks it as '$name' (F-0024: ExecStart would 203/EXEC)"
  elif ! has_shebang "$script"; then
    bad "$script: no shebang, but README symlinks it as '$name' (would 203/EXEC)"
  elif ! is_executable "$script"; then
    bad "$script: not committed as executable (100755), but README symlinks it as '$name' (would 203/EXEC; fix: git update-index --chmod=+x $script)"
  else
    pass "$script: symlink target '$name' exists, has a shebang and is executable"
  fi
done

# ---------------------------------------------------------------------------
# 2. Every ExecStart binary in the READMEs is created by a README ln -s line
# ---------------------------------------------------------------------------
while read -r bin; do
  [[ -n "$bin" ]] || continue
  name="$(basename "$bin")"
  if [[ -n "${LINK_SRC[$name]:-}" ]]; then
    pass "ExecStart $bin -> ${LINK_SRC[$name]}"
  else
    bad "ExecStart runs $bin but no README 'ln -s' line creates it (F-0024: 203/EXEC)"
  fi
done < <(grep -rhE --include='*.md' --exclude-dir=.git '^ExecStart=' . \
           | grep -oE '(/usr/local/bin|\.local/bin)/[A-Za-z0-9._-]+' | sort -u)

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
