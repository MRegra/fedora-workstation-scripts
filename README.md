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

Every push to `main` and every pull request runs `.github/workflows/ci.yml`:

- **shellcheck** — static analysis of every `*.sh` (the runner's shellcheck is
  older than Fedora's and a little stricter; the version is printed in the log).
- **actionlint** — lints the workflow files.
- **gitleaks** — scans for committed secrets.
- **script smoke test** — `bash -n` on every script plus `scripts/test-smoke.sh`,
  which guards against the systemd `status=203/EXEC` failure (a moved, renamed
  or non-executable script behind a unit's `ExecStart`). It reads the symlink
  lines and `ExecStart=` lines from the READMEs and fails if a symlinked script
  is missing, has no shebang or is not committed as executable (`100755`), or if
  an `ExecStart` binary is not created by any README symlink. It also runs every
  `*.sh` outside `scripts/` with `--help` (no `sudo`, no side effects).
  `scripts/test-smoke-selftest.sh` proves the smoke test goes red on each of
  those failures.

Every runnable script therefore supports `--help`. When you move a script,
update its README symlink line in the same change. Run the checks locally with:

```bash
bash scripts/test-smoke.sh
bash scripts/test-smoke-selftest.sh
```
