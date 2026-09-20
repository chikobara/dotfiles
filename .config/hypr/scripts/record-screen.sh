#!/usr/bin/env bash

set -euo pipefail

videos_dir="$(xdg-user-dir VIDEOS 2>/dev/null || printf '%s/Videos' "$HOME")"
mkdir -p "$videos_dir"

if pgrep -x gpu-screen-recorder >/dev/null; then
    pkill -INT -x gpu-screen-recorder
    notify-send "Recording stopped" "Saved the recording to $videos_dir" -a "GPU Screen Recorder"
    exit 0
fi

timestamp="$(date '+%Y-%m-%d_%H.%M.%S')"
output="$videos_dir/recording_${timestamp}.mp4"
capture_args=()
audio_args=()

case "${1:-region}" in
    --fullscreen|--fullscreen-sound)
        monitor="$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name')"
        if [[ -z "$monitor" ]]; then
            notify-send "Recording failed" "Could not find the focused monitor" -a "GPU Screen Recorder"
            exit 1
        fi
        capture_args=(-w "$monitor")
        ;;
    --sound)
        geometry="$(slurp -f '%wx%h+%x+%y')"
        capture_args=(-w region -region "$geometry")
        audio_args=(-a default_output)
        ;;
    region)
        geometry="$(slurp -f '%wx%h+%x+%y')"
        capture_args=(-w region -region "$geometry")
        ;;
    *)
        echo "usage: $0 [region|--sound|--fullscreen|--fullscreen-sound]" >&2
        exit 2
        ;;
esac

if [[ "${1:-region}" == "--fullscreen-sound" ]]; then
    audio_args=(-a default_output)
fi

notify-send "Recording started" "Saving to $output" -a "GPU Screen Recorder"
gpu-screen-recorder "${capture_args[@]}" "${audio_args[@]}" -f 60 -c mp4 -o "$output" &
disown
