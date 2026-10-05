# Runbook — fedora-workstation-scripts

This repo has no deployed service; it's a set of scripts run by systemd
timers/units and cron on the owner's own Fedora workstation(s), plus a
bug-bounty automation pipeline run manually/overnight. This runbook covers
operating the scripts and their automation, not a hosted app.

## Service map

| Script | Runs as | Scheduled by | Logs |
|---|---|---|---|
| `fedora-maintenance/fedora-maintenance.sh` | root | systemd timer (user or system, see `fedora-maintenance/README.md`) or cron | `/var/log/fedora-maintenance.log` (+ rotated copies) |
| `system-health/system-health-check.sh` | user | systemd user timer (hourly) or cron | desktop notification only (no log file) |
| `soft-reboot/soft-reboot.sh` | root | manual (`sudo soft-reboot/soft-reboot.sh`) | `/var/log/soft-reboot.log` |
| `system-audit/system-audit.sh` | root or user | manual | `/var/log/system-audit/` (root) or `~/.local/share/system-audit/logs` (user) |
| `bug-bounty-agent/orchestrator.py` | user | manual, or `nightly-launch.sh` (detached via `nohup`) | `output/` directory, see `bug-bounty-agent/README.md` |

No network service, no database, no deploy/rollback in the usual sense — a
"rollback" here is `git revert` on `main` plus re-pulling/re-symlinking the
script on the workstation.

## Health

- CI status: `.github/workflows/ci.yml` (shellcheck, actionlint, gitleaks,
  script smoke test) on every push to `main` and every PR — green CI is the
  health signal for the scripts themselves.
- Local check: `bash scripts/test-smoke.sh` — verifies every shell entrypoint
  is present, executable, has a shebang, and that README symlink targets and
  documented `ExecStart=` lines actually resolve to a script in the repo.
- `sudo systemctl --user status fedora-maintenance.timer system-health.timer`
  (or system units under `/etc/systemd/system/`) — confirms timers are active.
- `sudo tail -n 200 /var/log/fedora-maintenance.log` — last maintenance run.

## Failure modes

| Symptom | How to confirm | Mitigation | Reference |
|---|---|---|---|
| `fedora-maintenance.service` (or similar unit) fails with `status=203/EXEC` | `systemctl --user status fedora-maintenance.service` or `journalctl --user -u fedora-maintenance.service` shows `203/EXEC` | The unit's `ExecStart=` points at a path that no longer exists (script moved/renamed, e.g. into a per-tool subdirectory). Fix the `ExecStart=` path to match the current README symlink target, then `systemctl --user daemon-reload`. | F-0024; guarded in CI by `scripts/test-smoke.sh` |
| Unit fails with `status=1/FAILURE` almost immediately | `journalctl` shows exit in a few ms, script printed usage text | `ExecStart=` is missing a required mode argument (e.g. `fedora-maintenance` needs `daily`/`monthly`/`major`). Add the mode to `ExecStart=`. `%i` only expands in a template unit (`name@.service`); a plain `name.service` with `%i` runs with an empty argument. | F-0024; guarded in CI by `scripts/test-smoke.sh` |
| `systemctl --user` unit fails because the script needs root | Script exits 1 with a "run as root" message in the journal | User units run as the invoking user, not root. Either run the maintenance script via `sudo -n` in `ExecStart=` with passwordless sudo configured for that command, or use a system unit (`/etc/systemd/system/`) instead. | F-0024; guarded in CI by `scripts/test-smoke.sh` |
| CI `shellcheck`/`actionlint`/`gitleaks` job goes red | Check the failing job in the Actions run | Fix the reported finding (shellcheck warning, workflow lint error, or committed secret — rotate the secret immediately if `gitleaks` finds a real one, then scrub history with the owner's help). | `.github/workflows/ci.yml` |
| CI jobs don't start or stay queued | Check runner status: the jobs target `runs-on: [self-hosted, home]` (server-dev1/server-dev2) | Confirm the home runners are online (owner-operated hardware, not in this repo's control). | `docs/adr/0001-ci-on-home-self-hosted-runners.md`, F-0704 |

## Data

No database. `bug-bounty-agent/scope.yaml` and `bug-bounty-agent/memory/*.json`
hold program-specific targets and findings on the operator's machine only —
never committed (only `scope.example.yaml` is tracked). No backup/restore
procedure; these are local working files, not systems of record.

## Escalation

Everything here runs on the owner's own workstation and home self-hosted CI
runners — there is no third-party account, DNS or paid service to escalate
to. If the home runners (server-dev1/server-dev2) are down, that's an
owner-only hardware/network check, not something fixable from this repo.
