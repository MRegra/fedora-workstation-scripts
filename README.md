# Fedora Hygiene Script

Automate routine Fedora maintenance with safe defaults:

- Daily updates (`dnf upgrade --refresh`)
- Monthly firmware refresh (`fwupdmgr`) and extra cleanup
- Optional major version upgrade (`dnf system-upgrade`)
- Cleanup: autoremove, clean, trim old kernels
- Compact terminal output with full details in `/var/log/fedora-hygiene.log`

## Requirements

- Fedora with `dnf`
- Optional: `fwupd` for firmware updates
- Optional: `dnf-plugins-core` for old-kernel cleanup and `needs-restarting`
- Optional: `libnotify` for desktop notifications

Install optional tools:

```bash
sudo dnf install -y fwupd dnf-plugins-core libnotify
```

## Setup

Install the script to a system path (recommended for systemd):

```bash
sudo install -m 0755 /home/marcelo/dev/fedora-workstation-scripts/update-system.sh /usr/local/bin/fedora-hygiene
```

Install the desktop entry for GNOME/KDE notifications:

```bash
sudo install -m 0644 /home/marcelo/dev/fedora-workstation-scripts/fedora-hygiene.desktop /usr/share/applications/fedora-hygiene.desktop
```

Make the script executable (only needed if you run it from the repo path):

```bash
chmod +x update-system.sh
```

Run manually:

```bash
sudo /usr/local/bin/fedora-hygiene daily
sudo /usr/local/bin/fedora-hygiene monthly
sudo /usr/local/bin/fedora-hygiene major
```

Logs:

```bash
sudo tail -n 200 /var/log/fedora-hygiene.log
```

Rotated logs are saved alongside the main log as `/var/log/fedora-hygiene.log.YYYYmmdd-HHMMSS`.

## Bash alias (optional)

Add this to `~/.bashrc` (or `~/.bash_profile` if you prefer):

```bash
alias fedora-hygiene='sudo /usr/local/bin/fedora-hygiene'
```

Reload your shell:

```bash
source ~/.bashrc
```

Then use:

```bash
fedora-hygiene daily
```

## Automation

Systemd timers are recommended on Fedora. Cron works too.

### Option A: systemd timer (recommended)

Create these files (system-wide units):

`/etc/systemd/system/fedora-hygiene@.service`

```ini
[Unit]
Description=Fedora hygiene maintenance (daily/monthly)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fedora-hygiene %i
Environment=NOTIFY_USER=marcelo
```

`/etc/systemd/system/fedora-hygiene@daily.timer`

```ini
[Unit]
Description=Fedora hygiene daily

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/fedora-hygiene@monthly.timer`

```ini
[Unit]
Description=Fedora hygiene monthly

[Timer]
OnCalendar=*-*-01 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable them:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fedora-hygiene@daily.timer
sudo systemctl enable --now fedora-hygiene@monthly.timer
```

### Option B: cron

Edit root's crontab:

```bash
sudo crontab -e
```

Add:

```cron
0 8 * * * /usr/local/bin/fedora-hygiene daily
0 9 1 * * /usr/local/bin/fedora-hygiene monthly
```

## Notes

- The script refuses to run without root.
- Major upgrade uses the next Fedora version by default.
- Change how many kernels to keep with `KEEP_KERNELS=2` (or another value).
- Log retention defaults to 30 days of rotated logs. Set `LOG_DAYS=0` to disable cleanup.
- Desktop notifications are optional: set `NOTIFY_USER=yourusername` in the systemd unit and keep a GUI session active.
- For GNOME/KDE, install `fedora-hygiene.desktop` so notifications show up as a distinct app.

## Testing

Run once without systemd:

```bash
sudo NOTIFY_USER=marcelo /usr/local/bin/fedora-hygiene daily
```

Start a single systemd run:

```bash
sudo systemctl start fedora-hygiene@daily.service
sudo systemctl status fedora-hygiene@daily.service
sudo journalctl -u fedora-hygiene@daily.service -b --no-pager
```
