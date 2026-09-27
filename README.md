# Fedora Workstation Scripts

This repo contains small, focused scripts for maintaining a Fedora workstation.
Each script lives in its own folder with a dedicated README that covers usage,
install, and setup details.

## Projects

- `fedora-maintenance/`: system updates, cleanup, firmware, and major upgrades
- `system-health/`: lightweight memory pressure warning

## Quick setup (symlinks)

User-local:

```bash
mkdir -p ~/.local/bin
ln -s /home/mregra/dev/fedora-workstation-scripts/fedora-maintenance/fedora-maintenance.sh ~/.local/bin/fedora-maintenance
ln -s /home/mregra/dev/fedora-workstation-scripts/system-health/system-health-check.sh ~/.local/bin/system-health-check
```

System-wide (for systemd system units):

```bash
sudo ln -s /home/mregra/dev/fedora-workstation-scripts/fedora-maintenance/fedora-maintenance.sh /usr/local/bin/fedora-maintenance
sudo ln -s /home/mregra/dev/fedora-workstation-scripts/system-health/system-health-check.sh /usr/local/bin/system-health-check
```

Then follow the per-project READMEs for configuration and automation details.

## Continuous integration

CI runs on the owner's home self-hosted runners (`server-dev1`/`server-dev2`,
labels `self-hosted, Linux, X64, home`) rather than GitHub-hosted runners — see
[ADR 0001](docs/adr/0001-ci-on-home-self-hosted-runners.md). Every push to
`main` and every pull request runs `.github/workflows/ci.yml`:

- **shellcheck** — static analysis of every `*.sh`. Pinned to v0.9.0 (the
  version Fedora/ubuntu-24.04 used to ship, stricter than newer releases on
  SC2015); the tarball is downloaded and checked against a sha256 pinned in
  the workflow before it's extracted and run.
- **actionlint** — lints the workflow files (`go run …@v1.7.7`, checked
  against the Go checksum database).
- **gitleaks** — scans the full git history for committed secrets. Pinned to
  v8.30.1; the tarball is downloaded and checked against a sha256 pinned in
  the workflow (matching gitleaks' own published checksums file) before it's
  extracted and run.
- **script smoke test** — `bash -n` on every script plus `scripts/test-smoke.sh`,
  which guards against the ways `fedora-maintenance.service` failed (F-0024). It
  reads the `ln -s` lines and the `ExecStart=` lines from the READMEs and fails if:
  - a script behind a symlink or a direct repo path (`%h/.../fedora-workstation-scripts/<path>`)
    is missing, has no shebang or is not committed as executable (`100755`),
    so the unit would fail with `status=203/EXEC`;
  - an `ExecStart` runs a `/usr/local/bin` or `~/.local/bin` name that no README
    symlink creates, or runs nothing from this repo;
  - a script that declares `# smoke-modes: ...` is started with no mode, an
    unknown mode, or `%i` in a unit that is not a template (`name@.service`),
    so it would exit 1 with its usage text;
  - a user unit (`~/.config/systemd/user`) runs a script that calls `need_root`
    without `sudo`.

  It also runs every `*.sh` outside `scripts/` with `--help` (no `sudo`, no side
  effects). A script whose source never mentions `--help` is reported and not
  run. `scripts/test-smoke-selftest.sh` proves the smoke test goes red on each
  of those failures.

Every runnable script therefore supports `--help`. When you move a script,
update its README symlink line in the same change. When you add a mode to
`fedora-maintenance.sh`, add it to its `# smoke-modes:` line. Run the checks
locally with:

```bash
bash scripts/test-smoke.sh
bash scripts/test-smoke-selftest.sh
```
