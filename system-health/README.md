# System Health Check

Lightweight memory pressure warning for a Fedora workstation. It checks swap
usage and available RAM, and triggers a desktop notification when thresholds are
exceeded.

## Requirements

- `free` (from `procps-ng`, available by default)
- Optional: `libnotify` for desktop notifications

Install optional tools:

```bash
sudo dnf install -y libnotify
```

## Install

Make the script executable (only needed if you run it from the repo path):

```bash
chmod +x /home/mregra/dev/fedora-workstation-scripts/system-health/system-health-check.sh
```

## Setup (symlinks)

User-local:

```bash
mkdir -p ~/.local/bin
ln -s /home/mregra/dev/fedora-workstation-scripts/system-health/system-health-check.sh ~/.local/bin/system-health-check
```

System-wide (for systemd system units):

```bash
sudo ln -s /home/mregra/dev/fedora-workstation-scripts/system-health/system-health-check.sh /usr/local/bin/system-health-check
```

Ensure `~/.local/bin` is on your `PATH` if you use the user-local symlink.

## Usage

```bash
system-health-check
```

`fedora-maintenance` (`daily`/`monthly`) also runs this script with
`--check-only` right after a maintenance pass, to echo Bluefin-style
"rollback if it looks wrong" safety on a traditional dnf Workstation (F-2585).
In that mode it prints the pressure reason and exits 1 instead of sending a
notification — `fedora-maintenance` then sends its own, distinctly-worded
notification so a post-maintenance warning is never confused with this
script's normal hourly one. See `../fedora-maintenance/README.md`.

## Automation

Systemd timers are recommended on Fedora. Cron works too.

### Option A: systemd user timers (recommended for desktop)

Create these files under `~/.config/systemd/user`.

`~/.config/systemd/user/system-health.service`

```ini
[Unit]
Description=System health check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-health-check
```

`~/.config/systemd/user/system-health.timer`

```ini
[Unit]
Description=System health check schedule

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable them:

```bash
systemctl --user daemon-reload
systemctl --user enable --now system-health.timer
```

### Option B: systemd system timers

`/etc/systemd/system/system-health.service`

```ini
[Unit]
Description=System health check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-health-check
```

`/etc/systemd/system/system-health.timer`

```ini
[Unit]
Description=System health check schedule

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable them:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now system-health.timer
```

### Option C: cron

Edit your crontab:

```bash
crontab -e
```

Add:

```cron
0 * * * * /usr/local/bin/system-health-check
```
