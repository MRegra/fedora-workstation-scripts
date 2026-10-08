# Changelog

All notable changes to this project are documented in this file.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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

### Changed

- CI jobs moved from GitHub-hosted (`ubuntu-24.04`) to the home self-hosted
  runners (`runs-on: [self-hosted, home]`); shellcheck and actionlint are now
  installed without sudo (pinned downloads / `actions/setup-go`). (#5)
