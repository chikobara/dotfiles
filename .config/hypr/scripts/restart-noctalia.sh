#!/usr/bin/env bash

set -u

if ! command -v noctalia >/dev/null 2>&1; then
    notify-send "Noctalia restart failed" "The noctalia command is not installed" -a "Hyprland" 2>/dev/null || true
    exit 127
fi

user_id="$(id -u)"
pkill -TERM -u "$user_id" -x noctalia 2>/dev/null || true

for attempt in 1 2 3 4 5; do
    if ! pgrep -u "$user_id" -x noctalia >/dev/null 2>&1; then
        break
    fi
    sleep 0.4
done

if pgrep -u "$user_id" -x noctalia >/dev/null 2>&1; then
    pkill -KILL -u "$user_id" -x noctalia 2>/dev/null || true
fi

log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia"
mkdir -p "$log_dir"
nohup noctalia --daemon >"$log_dir/restart.log" 2>&1 </dev/null &
