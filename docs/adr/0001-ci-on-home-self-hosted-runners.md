# ADR 0001: CI runs on the home self-hosted runners with pinned, checksum-verified tools

- Status: accepted (owner decision 2026-09-27, issue #4)
- Context item: F-0704

## Context

The owner decided that all crew repos run CI on the home self-hosted runners:
server-dev1 and server-dev2, labels `self-hosted, Linux, X64, home`. Each server
has 6 CPUs / 7 GB shared, ~20 GB free, Docker, and no passwordless sudo.

This repo is PUBLIC. Up to now its CI ran on GitHub-hosted `ubuntu-24.04`:
- shellcheck came from Ubuntu's signed apt repo
- gitleaks came through the SHA-pinned `gitleaks/gitleaks-action` v2.3.9
- actionlint comes from `go run …@v1.7.7`, checked against sum.golang.org

Home runners are long-lived and shared between repos, so anything a job
downloads and runs lands on the owner's own machines.

## Decision

1. Every job uses `runs-on: [self-hosted, home]`. Job and check names don't
   change. `.github/actionlint.yaml` declares the `home` label.
2. Tools are installed without sudo into `$RUNNER_TEMP`. Every binary
   downloaded from outside is **pinned by version and checked against a
   sha256 literal in the workflow** before it is extracted or run. Where
   upstream publishes a checksums file (gitleaks), the pinned hash must match
   it. Where it doesn't (shellcheck), the hash is computed once from
   independent fetches and marked trust-on-first-use.
3. Go modules keep using `go run module@version`, which is checked through
   sum.golang.org, with a pinned Go minor version (`1.26.x`).
4. The secret scan runs the gitleaks CLI directly, pinned to a release no
   older than the one the action ran, over the full history with `--redact`.
   It gets no token.
5. Triggers stay `push: [main]` and `pull_request`. `pull_request_target` is
   never used. No secrets are exposed to PR jobs. The repo keeps
   `approval_policy: all_external_contributors`.

## Consequences

- More control over supply-chain integrity than the action gave: the action
  downloaded gitleaks with no checksum check.
- Moving a tool to a new version is now a deliberate two-line change (version
  + hash). It fails closed if the asset changes upstream.
- Remaining risk, accepted by the owner: an approved fork PR executes code on
  shared home hosts that have Docker. Mitigations belong to the runner hosts
  and are tracked outside this repo: ephemeral runners or `container:` jobs,
  one OS user per runner, no docker group or rootless Docker, network
  isolation from the home LAN, and careful review before approving fork runs.
- Rollback: revert the PR to go back to `ubuntu-24.04` and the action.
