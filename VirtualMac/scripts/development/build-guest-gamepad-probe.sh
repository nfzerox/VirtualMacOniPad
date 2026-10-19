#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BUILD_ROOT=${VZ_BUILD_ROOT:-$REPO_ROOT/build}
SOURCE="$REPO_ROOT/vz/development/probes/gamepad_hid_probe.m"
ENTITLEMENTS="$REPO_ROOT/vz/development/probes/GamepadHIDProbe.entitlements"
BINARY="$BUILD_ROOT/guest-gamepad-probe"
SENDER_SOURCE="$REPO_ROOT/vz/development/probes/gamepad_udp_sender.m"
SENDER_BINARY="$BUILD_ROOT/guest-gamepad-send"

need_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2
        exit 1
    }
}

need_command xcrun
need_command codesign
[[ -f "$SOURCE" ]] || { echo "missing source: $SOURCE" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "missing entitlements: $ENTITLEMENTS" >&2; exit 1; }
[[ -f "$SENDER_SOURCE" ]] || { echo "missing source: $SENDER_SOURCE" >&2; exit 1; }

SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$BUILD_ROOT"

xcrun --sdk macosx clang \
    -arch arm64 \
    -mmacosx-version-min=13.0 \
    -fblocks \
    -isysroot "$SDK" \
    "$SOURCE" \
    -framework CoreFoundation \
    -framework IOKit \
    -framework Foundation \
    -lm \
    -o "$BINARY"

codesign --force --sign - --entitlements "$ENTITLEMENTS" \
    --timestamp=none "$BINARY" >/dev/null

xcrun --sdk macosx clang \
    -arch arm64 \
    -mmacosx-version-min=13.0 \
    -isysroot "$SDK" \
    "$SENDER_SOURCE" \
    -framework Foundation \
    -lm \
    -o "$SENDER_BINARY"

echo "guest gamepad HID probe built: $BINARY"
echo "guest gamepad UDP sender built: $SENDER_BINARY"
