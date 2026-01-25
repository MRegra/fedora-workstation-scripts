# Fedora Maintenance

Automate routine Fedora maintenance with safe defaults:

- DNF updates and cleanup
- Optional Flatpak maintenance
- Optional firmware updates
- Optional major version upgrade

## Requirements

- Fedora with `dnf`
- Optional: `fwupd` for firmware updates
- Optional: `dnf-plugins-core` for `needs-restarting` and `repoquery`
- Optional: `flatpak` for Flatpak maintenance
- Optional: `libnotify` for desktop notifications

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
Description=Fedora maintenance (%i)

[Service]
Type=oneshot
ExecStart=/usr/bin/sudo -n /usr/local/bin/fedora-maintenance %i
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

## Notes

- The script refuses to run without root.
- Major upgrade uses the next Fedora version by default.
- Change how many kernels to keep with `KEEP_KERNELS=2` (or another value).
- Log retention defaults to 30 days of rotated logs. Set `LOG_DAYS=0` to disable cleanup.
- Journal retention defaults to 7 days. Set `JOURNAL_DAYS=0` to disable cleanup.
- Desktop notifications are optional: set `NOTIFY_USER=yourusername` in the unit and keep a GUI session active.
