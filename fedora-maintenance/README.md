# Fedora Maintenance

Automate routine Fedora maintenance with safe defaults:

- DNF updates and cleanup
- Optional Flatpak maintenance
- Optional firmware updates
- Optional major version upgrade
- Optional (`extended` mode): pip updates for `bug-bounty-agent` and Ollama
  model updates for `local-ai-agent` — the other dev-stack ecosystems this
  repo already runs, kept out of the default `daily`/`monthly` path

## Requirements

- Fedora with `dnf`
- Optional: `fwupd` for firmware updates
- Optional: `dnf-plugins-core` for `needs-restarting` and `repoquery`
- Optional: `flatpak` for Flatpak maintenance
- Optional: `libnotify` for desktop notifications
- Optional (`extended` mode): `pip3` for the bug-bounty-agent pip update step,
  `ollama` for the Ollama model update step

Install optional tools:

```bash
sudo dnf install -y fwupd dnf-plugins-core flatpak libnotify
```

## Install

Make the script executable (only needed if you run it from the repo path):

```bash
chmod +x /home/mregra/dev/fedora-workstation-scripts/fedora-maintenance/fedora-maintenance.sh
```

## Setup (symlinks)

User-local:

```bash
mkdir -p ~/.local/bin
ln -s /home/mregra/dev/fedora-workstation-scripts/fedora-maintenance/fedora-maintenance.sh ~/.local/bin/fedora-maintenance
```

System-wide (for systemd system units):

```bash
sudo ln -s /home/mregra/dev/fedora-workstation-scripts/fedora-maintenance/fedora-maintenance.sh /usr/local/bin/fedora-maintenance
```

Ensure `~/.local/bin` is on your `PATH` if you use the user-local symlink.

## Usage

```bash
sudo fedora-maintenance daily
sudo fedora-maintenance monthly
sudo fedora-maintenance major

# opt-in: monthly (dnf + firmware + flatpak) + this repo's other ecosystems (off by default, see below)
sudo UPDATE_PIP=1 UPDATE_OLLAMA=1 fedora-maintenance extended
```

Logs:

```bash
sudo tail -n 200 /var/log/fedora-maintenance.log
```

Rotated logs are saved alongside the main log as `/var/log/fedora-maintenance.log.YYYYmmdd-HHMMSS`.

## Automation

Systemd timers are recommended on Fedora. Cron works too.

### Option A: systemd user timers (recommended for desktop)

Create these files under `~/.config/systemd/user`.

`~/.config/systemd/user/fedora-maintenance.service`

```ini
[Unit]
Description=Fedora maintenance (daily)

[Service]
Type=oneshot
ExecStart=/usr/bin/sudo -n /usr/local/bin/fedora-maintenance daily
Environment=NOTIFY_USER=mregra
```

`~/.config/systemd/user/fedora-maintenance.timer`

```ini
[Unit]
Description=Fedora maintenance schedule

[Timer]
OnCalendar=Mon..Sun 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable them:

```bash
systemctl --user daemon-reload
systemctl --user enable --now fedora-maintenance.timer
```

If you use the user timers, make sure `sudo` is configured for passwordless
execution of the maintenance script (or it will prompt and fail in the background).
Always pass a mode in `ExecStart`: without one the script prints usage and exits 1.
`%i` only works in a template unit (`fedora-maintenance@.service`, Option B); in
`fedora-maintenance.service` it expands to an empty string.

### Option B: systemd system timers

System-wide units run as root and do not need `sudo` in `ExecStart`.

`/etc/systemd/system/fedora-maintenance@.service`

```ini
[Unit]
Description=Fedora maintenance (%i)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fedora-maintenance %i
Environment=NOTIFY_USER=mregra
```

`/etc/systemd/system/fedora-maintenance@daily.timer`

```ini
[Unit]
Description=Fedora maintenance daily

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/fedora-maintenance@monthly.timer`

```ini
[Unit]
Description=Fedora maintenance monthly

[Timer]
OnCalendar=*-*-01 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable them:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fedora-maintenance@daily.timer
sudo systemctl enable --now fedora-maintenance@monthly.timer
```

### Option C: cron

Edit root's crontab:

```bash
sudo crontab -e
```

Add:

```cron
0 8 * * * /usr/local/bin/fedora-maintenance daily
0 9 1 * * /usr/local/bin/fedora-maintenance monthly
```

## Extended mode (pip + Ollama)

`extended` runs the same steps as `monthly` (dnf + firmware + flatpak), plus two opt-in steps for the
other dev-stack ecosystems this repo already runs — `bug-bounty-agent`
(pip) and `local-ai-agent` (Ollama). Each is off by default and toggled
independently:

- `UPDATE_PIP=1` — runs `pip3 install --user --upgrade -r bug-bounty-agent/requirements.txt`
  as `MAINTENANCE_USER` (default: `NOTIFY_USER`). It must run as that user,
  not root, or the packages land in `/root`'s `pip --user` site instead of
  the desktop account's. If neither is set, the step is skipped and logged.
- `UPDATE_OLLAMA=1` — runs `ollama pull <model>` for every model already
  present (`ollama list`), to fetch newer digests. Runs as whichever user
  invokes the script, since `ollama pull` only talks to the local daemon's
  API; model storage belongs to the `ollama` service, not the caller.

Both steps log the same way as the existing ones (`- <step>` / `OK` / `WARN`
to stdout and `$LOG_FILE`) and never fail the run: a missing `pip3`/`ollama`,
an unset `MAINTENANCE_USER`, or no local Ollama models are a logged `SKIP`,
not an error.

```bash
sudo UPDATE_PIP=1 UPDATE_OLLAMA=1 MAINTENANCE_USER=mregra fedora-maintenance extended
```

## Notes

- The script refuses to run without root.
- Major upgrade uses the next Fedora version by default.
- Change how many kernels to keep with `KEEP_KERNELS=2` (or another value).
- Log retention defaults to 30 days of rotated logs. Set `LOG_DAYS=0` to disable cleanup.
- Journal retention defaults to 7 days. Set `JOURNAL_DAYS=0` to disable cleanup.
- Desktop notifications are optional: set `NOTIFY_USER=yourusername` in the unit and keep a GUI session active.
- `extended` mode's pip/Ollama steps are opt-in (see above); plain `daily`/`monthly`/`major` never touch them.
