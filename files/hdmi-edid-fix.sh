#!/bin/bash
# Work around the mainline rockchip dw-hdmi-qp bug on RK3588 where the driver
# mis-parses some sinks' EDID, logs "HDMI Sink doesn't support RGB, something's
# wrong", fails the atomic modeset, and leaves the connector disabled (black
# screen). Overriding the connector EDID with a clean canned 1920x1080 block via
# debugfs lets the modeset succeed (it falls back to YCbCr output).
#
# Runs at boot (see hdmi-edid-fix.service). Also usable by hand after a hotplug.
# NOTE: after a cold boot the connector may read "disconnected" until the cable
# is physically reseated (RK3588 HPD quirk) -- that is not this bug.
set -u
EDID=/lib/firmware/edid/1920x1080.bin   # ships with Armbian/linux-firmware
[ -f "$EDID" ] || exit 0
for try in 1 2 3 4 5; do
  for c in /sys/class/drm/card0/card0-HDMI-A-1 /sys/class/drm/card0/card0-HDMI-A-2; do
    [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
    name=$(basename "$c" | sed 's/^card0-//')
    d=$(find /sys/kernel/debug/dri -maxdepth 2 -name "$name" -type d 2>/dev/null | head -1)
    [ -n "$d" ] && cat "$EDID" > "$d/edid_override" 2>/dev/null && exit 0
  done
  sleep 3
done
