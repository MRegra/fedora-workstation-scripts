#!/bin/bash

SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
RAM_AVAIL=$(free -m | awk '/Mem:/ {print $7}')

if [ "$SWAP_USED" -gt 1500 ] || [ "$RAM_AVAIL" -lt 800 ]; then
  notify-send "⚠️ System Health Warning" \
    "Memory pressure detected.\nConsider restarting soon."
fi
