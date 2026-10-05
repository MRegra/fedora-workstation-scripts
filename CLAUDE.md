# fedora-workstation-scripts

Personal toolbox for a Fedora Linux power user + bug bounty hunter (Intigriti / Bugcrowd).
Public repo; CI runs on the owner's home self-hosted runners.

## Repository structure

```
fedora-maintenance/  — DNF updates, cleanup, firmware, major upgrades (sudo fedora-maintenance.sh daily|monthly|major)
system-health/       — lightweight memory/swap pressure warning (system-health-check.sh)
soft-reboot/         — replicates reboot cleanup effects without rebooting (sudo soft-reboot.sh)
system-audit/        — read-only security + performance audit, PASS/WARN/ALERT, baseline diffing (system-audit.sh [--save-baseline])
local-ai-agent/      — MCP server exposing a local Ollama LLM to Claude Code
bug-bounty-agent/    — overnight AI pipeline: recon → scan → browser → PoC → report (see bug-bounty-agent/README.md)
scripts/             — CI support: test-smoke.sh (F-0024 regression guard) and its self-test
docs/adr/            — Architecture Decision Records
.github/workflows/   — CI (ci.yml), self-hosted runner label config (actionlint.yaml)
```

Each shell entrypoint (`fedora-maintenance.sh`, `system-health-check.sh`,
`soft-reboot.sh`, `system-audit.sh`, `nightly-launch.sh`, `install-tools.sh`)
supports `-h`/`--help`, printing usage and exiting 0 with no privileged or
destructive work. `fedora-maintenance/` and `system-health/` have their own
`README.md` with full setup/automation instructions; `soft-reboot.sh` and
`system-audit.sh` are self-documenting via `--help`.

## CI (`.github/workflows/ci.yml`)

Runs on `push` to `main` and on every `pull_request`, on the owner's home
self-hosted runners (`runs-on: [self-hosted, home]` — see
`docs/adr/0001-ci-on-home-self-hosted-runners.md`). Four jobs, all required
checks:

- **shellcheck** — every `*.sh`, pinned to v0.9.0 (checksum-verified download).
- **actionlint** — lints the workflow files (`go run …@v1.7.7`).
- **gitleaks** — full-history secret scan, pinned to v8.30.1 (checksum-verified
  download, invoked directly — not via `gitleaks-action`).
- **script smoke test** (`scripts/test-smoke.sh` + `scripts/test-smoke-selftest.sh`)
  — the **F-0024 regression guard**: fails if an entrypoint behind a README
  symlink or a systemd `ExecStart=` is missing, non-executable, lacks a
  shebang, or declares `--help`/`# smoke-modes:` but doesn't honor it. This is
  the test suite for the shell scripts — run it locally with:

  ```bash
  bash scripts/test-smoke.sh
  bash scripts/test-smoke-selftest.sh
  ```

The runners have Docker but **no passwordless sudo**: do not add steps that
assume `apt`/`dnf install` will work without prompting. All GitHub Actions are
pinned to full commit SHAs with a `# vX.Y` comment.

## Conventions

- When you move or rename a script, update its README symlink line and any
  systemd `ExecStart=` example in the same change — the smoke test enforces
  this.
- When you add a mode to `fedora-maintenance.sh`, add it to its
  `# smoke-modes:` comment.
- Shell scripts must pass `shellcheck` at default (style) severity; justify
  any inline disable with a comment (see `SC2086`/`SC2009` in
  `fedora-maintenance.sh`/`system-audit.sh` for examples).

## Danger zones (bug-bounty-agent)

- `is_in_scope()` (in `orchestrator.py`) is called before every network
  operation — never remove or bypass it; it is the only thing stopping the
  overnight pipeline from touching out-of-scope hosts.
- `sqlmap` is hardcoded to `--level=1 --risk=1 --technique=BT --banner` in the
  PoC phase — never raise these to enable data exfiltration.
- Browser agent (`browser_agent.py`) is capped at 40 steps per session and 3
  sessions per host — do not remove these caps.
- `scope.yaml` and `memory/*.json` hold program-specific bug bounty data
  (targets, findings, submission status) — never commit real values; only
  `scope.example.yaml` is tracked.

## Where tests live

There is no application test suite — these are maintenance/automation
scripts. The CI safety net is `scripts/test-smoke.sh` (smoke-tests every
shell entrypoint's `--help` path and README/systemd wiring) plus
`scripts/test-smoke-selftest.sh` (proves the smoke test itself goes red on
each F-0024 failure mode). `shellcheck` and `gitleaks` run on every push/PR
via CI (see above). The Python side (`bug-bounty-agent/`, `local-ai-agent/`)
has no automated tests or lint job yet.
