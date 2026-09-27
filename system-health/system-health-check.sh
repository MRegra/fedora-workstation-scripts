#!/bin/bash

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
system-health-check.sh — warn on memory pressure via a desktop notification.

Usage:
  system-health-check            Check swap/RAM, notify if thresholds exceeded.
  system-health-check --help     Show this help and exit.

Triggers a notification when swap used > 1500 MB or available RAM < 800 MB.
Requires libnotify (notify-send) for the notification.
EOF
  exit 0
fi

SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
RAM_AVAIL=$(free -m | awk '/Mem:/ {print $7}')

if [ "$SWAP_USED" -gt 1500 ] || [ "$RAM_AVAIL" -lt 800 ]; then
  notify-send "⚠️ System Health Warning" \
    "Memory pressure detected.\nConsider restarting soon."
fi
