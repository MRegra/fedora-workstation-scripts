#!/bin/bash

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
system-health-check.sh — warn on memory pressure via a desktop notification.

Usage:
  system-health-check             Check swap/RAM, notify if thresholds exceeded.
  system-health-check --check-only
                                   Check swap/RAM, print the reason on stdout
                                   and exit 1 on pressure instead of sending a
                                   notification. Used by fedora-maintenance to
                                   gate its own, distinctly-marked notification
                                   after a maintenance run (F-2585).
  system-health-check --help      Show this help and exit.

Triggers a notification when swap used > 1500 MB or available RAM < 800 MB.
Requires libnotify (notify-send) for the notification.
EOF
  exit 0
fi

CHECK_ONLY=0
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=1

SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
RAM_AVAIL=$(free -m | awk '/Mem:/ {print $7}')

REASON=""
if [ "$SWAP_USED" -gt 1500 ]; then
  REASON="swap used ${SWAP_USED}MB (over 1500MB)"
elif [ "$RAM_AVAIL" -lt 800 ]; then
  REASON="RAM available ${RAM_AVAIL}MB (under 800MB)"
fi

if [[ -n "$REASON" ]]; then
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    printf '%s\n' "$REASON"
    exit 1
  fi
  notify-send "⚠️ System Health Warning" \
    "Memory pressure detected: ${REASON}.\nConsider restarting soon."
fi
