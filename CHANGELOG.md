# Changelog

All notable changes to this project are documented in this file.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `fedora-maintenance.sh`: `daily`/`monthly`/`extended` (not `major`, which
  reboots) now run `system-health-check.sh --check-only` at the end of the
  run and fold the result into exactly one final notification — a
  distinctly-worded "Maintenance ran (...); health check flagged: ..." (or
  "...; health check NOT run (system-health-check not found)" if the script
  can't be found at all) in place of the normal "Completed" message — never
  a second notification stacked on top. The script is resolved
  symlink-safely (`$HEALTH_CHECK_CMD` override, then the repo copy via the
  maintenance script's own `readlink -f`'d `REPO_ROOT`, then `PATH`, then the
  documented `/usr/local/bin/system-health-check` symlink), so the gate still
  works through the documented `/usr/local/bin/fedora-maintenance` install
  that systemd/cron actually use. A missing health check is always logged
  loudly (`WARN: health check not run: ...`), never a silent skip. The gate
  is advisory and never changes the run's exit code. A cheap echo of
  Bluefin's "automatic update + easy rollback if it looks wrong" trust model
  on a traditional dnf Workstation that has no OS-level rollback. New
  regression test: `scripts/test-health-check-gate.sh` (F-2585, issue #14).
- `fedora-maintenance.sh`: `--dry-run` flag for `daily`/`monthly`/`major`/`extended`.
  Lists the pending dnf/flatpak/firmware/kernel-prune actions (and, for
  `major`, the system-upgrade download/reboot steps) without running any of
  them, and exits 0. Regression test: `scripts/test-dry-run.sh`, run by the
  `smoke` CI job on every push/PR. (#12)
- `fedora-maintenance.sh extended` mode: opt-in steps that update the other
  dev-stack ecosystems this repo already runs — `pip3 install --user
  --upgrade` for `bug-bounty-agent`'s deps (`UPDATE_PIP=1`) and `ollama pull`
  for every locally installed model used by `local-ai-agent` (`UPDATE_OLLAMA=1`).
  Both are off by default, independently toggleable, and logged the same way
  as the existing dnf/flatpak/firmware steps. The pip step also re-runs
  `python3 -m playwright install chromium` as the same user when
  `requirements.txt` pins `playwright`, so a Playwright upgrade doesn't leave
  `bug-bounty-agent`'s browser phase pointing at a Chromium build that's no
  longer cached. The Ollama step distinguishes "daemon unreachable" from "no
  local models" in its `SKIP` log. (#15)
- `fedora-maintenance.sh daily` now defaults to notify-only: it lists
  available DNF updates via a desktop notification instead of installing
  them, per Fedora's own guidance that a single workstation should default
  to notify/download-only. Set `AUTO_INSTALL=1` to restore the previous
  unattended-install behavior for `daily`. `monthly`/`major` are unchanged.
  (F-2584)
- `renovate/default.json`: shared Renovate preset other repos extend
  (`github>MRegra/fedora-workstation-scripts//renovate/default`). Weekly
  grouped non-major PRs per ecosystem, one PR per major update, immediate
  vulnerability-alert PRs, Renovate-side automerge for patch/digest/pin only
  after every check is green. Renovate itself is not enabled on this repo;
  see [ADR 0002](docs/adr/0002-shared-renovate-preset-in-this-public-repo.md)
  for why the preset lives here. (#9)
- CI (`.github/workflows/ci.yml`): shellcheck, actionlint, gitleaks and a
  script smoke test (`scripts/test-smoke.sh`) run on every push to `main` and
  every pull request. The smoke test is a regression guard for the F-0024
  `203/EXEC` systemd failure (moved/renamed script entrypoints). (#3)
- `-h`/`--help` on every shell entrypoint (`fedora-maintenance.sh`,
  `system-health-check.sh`, `soft-reboot.sh`, `system-audit.sh`,
  `nightly-launch.sh`, `install-tools.sh`), so each can be smoke-tested
  without sudo or side effects. (#3)
- `docs/adr/0001-ci-on-home-self-hosted-runners.md`: CI runs on the owner's
  home self-hosted runners instead of GitHub-hosted runners. (#5)
- `docs/runbook.md`: service map, health checks and failure modes (including
  F-0024).
- `docs/runbook.md`: "Known issues" entry documenting that systemd units
  created before the scripts moved into `fedora-maintenance/`/`system-health/`
  subdirectories may still have `ExecStart=` pointing at the old flat repo
  paths (`status=203/EXEC`), with the fix (point `ExecStart=` at the
  `/usr/local/bin`/`~/.local/bin` symlink, re-create the symlink if missing,
  `daemon-reload`).

### Changed

- CI jobs moved from GitHub-hosted (`ubuntu-24.04`) to the home self-hosted
  runners (`runs-on: [self-hosted, home]`); shellcheck and actionlint are now
  installed without sudo (pinned downloads / `actions/setup-go`). (#5)

### Fixed

- `CLAUDE.md`: corrected the repository structure listing — the self-hosted
  runner label config for actionlint lives at `.github/actionlint.yaml`, not
  inside `.github/workflows/`. (docs pass, F-1595)
- `docs/runbook.md`: added a failure-mode row for a CI job being refused
  outright on the shared home runner host due to low disk space (observed on
  `gitleaks`, run 41771405938), distinct from the existing "runner offline"
  row — the host rejects the job before any of its steps run. (docs pass,
  F-2114)
