#!/usr/bin/env bash
# scripts/android/screencap-verify.sh — Android emulator/device screen capture
# helper that produces two artefacts per invocation:
#
#   /tmp/<label>-raw.png   Full-resolution PNG. Use for ImageMagick pixel
#                          sampling (`magick … -format "%[pixel:p{X,Y}]"`).
#                          Never gets Read into the model context.
#
#   /tmp/<label>.png       Downscaled preview, long edge ≤ 1600px. Safe to
#                          `Read` into the agent context — fits within the
#                          many-image dimension cap (2000px).
#
# The split exists because tall-screen AVDs (Pixel 10 Pro: 1280×2856) trip
# the 2000px many-image cap after a few captures, forcing context compaction.
# A single capture artefact serving both pixel-sampling and layout-inspection
# does the wrong job for both — pixel sampling needs lossless source; layout
# inspection needs a small downscaled preview. Split on disk; only the small
# one ever crosses the model boundary.
#
# Usage:
#   scripts/android/screencap-verify.sh <label>
#
# <label> is a short identifier used as the basename for both artefacts. Files
# are overwritten on subsequent invocations with the same label.
#
# Origin: HMB-29. Companion to HOMEBASE-SOP-007 § Step 3 (Observe).
#
# Canonical source: ~/code/homebase/scripts/android/screencap-verify.sh
# Symlinked into each adopting project via `bin/homebase link-project`.

set -euo pipefail

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
  echo "usage: screencap-verify.sh <label>" >&2
  echo "  produces /tmp/<label>-raw.png (full-res) and /tmp/<label>.png (≤1600px preview)" >&2
  exit 2
fi

# Locate adb. Prefer $PATH; fall back to the canonical macOS install path so
# the script works in fresh shells without explicit env setup.
if command -v adb >/dev/null 2>&1; then
  ADB="$(command -v adb)"
elif [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
else
  echo "error: adb not found in PATH or at ~/Library/Android/sdk/platform-tools/adb" >&2
  echo "  install Android platform-tools or add adb to PATH" >&2
  exit 3
fi

# sips ships with macOS. Bail loud on Linux so the script doesn't silently
# skip the preview.
if ! command -v sips >/dev/null 2>&1; then
  echo "error: sips not found (macOS-only)" >&2
  echo "  on Linux, replace sips with ImageMagick: 'magick <src> -resize 1600x1600\\> <dst>'" >&2
  exit 3
fi

# Confirm at least one device is connected; bail with a useful message if not.
DEVICES="$("$ADB" devices | tail -n +2 | awk '$2 == "device" {print $1}')"
DEVICE_COUNT="$(printf '%s\n' "$DEVICES" | grep -c . || true)"
if [[ "$DEVICE_COUNT" -eq 0 ]]; then
  echo "error: no Android devices/emulators connected" >&2
  echo "  start an emulator (Android Studio or 'emulator -avd <name>') and retry" >&2
  exit 4
fi

RAW="/tmp/${LABEL}-raw.png"
PREVIEW="/tmp/${LABEL}.png"

# Capture full-resolution PNG to /tmp/<label>-raw.png.
"$ADB" exec-out screencap -p > "$RAW"

# Downscale long edge to ≤ 1600px. sips -Z preserves aspect ratio.
sips -Z 1600 "$RAW" --out "$PREVIEW" >/dev/null

RAW_DIMS="$(sips -g pixelWidth -g pixelHeight "$RAW" | awk -F': ' '/pixel(Width|Height)/{printf "%s ", $2}' | sed 's/ $//')"
PREVIEW_DIMS="$(sips -g pixelWidth -g pixelHeight "$PREVIEW" | awk -F': ' '/pixel(Width|Height)/{printf "%s ", $2}' | sed 's/ $//')"

cat <<EOF
captured:
  raw     ($RAW_DIMS): $RAW
  preview ($PREVIEW_DIMS): $PREVIEW

next:
  pixel sample  →  magick $RAW -format "%[pixel:p{X,Y}]" info:
  read preview  →  Read $PREVIEW
EOF
