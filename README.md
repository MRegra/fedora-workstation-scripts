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
