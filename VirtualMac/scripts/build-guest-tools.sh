#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command codesign
need_command iconutil
need_command sips
need_command xcrun

OUT="${VZ_GUEST_TOOLS_BUILD:-$VZ_BUILD_ROOT/guest-tools}"
OPENGL_OUT="$VZ_BUILD_ROOT/guest-opengl"
GAMEPAD_RECEIVER="$VZ_BUILD_ROOT/guest-gamepad-probe"
APP="$OUT/Virtual Mac Guest Tools.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SYMBOL_CATALOG="$OUT/VirtualMacGuestTools.xcassets"

"$SCRIPT_DIR/development/build-opengl-guest-compat.sh"
"$SCRIPT_DIR/development/build-guest-gamepad-probe.sh"

rm -rf "$APP" "$OUT/VirtualMac.iconset" "$OUT/payload" "$SYMBOL_CATALOG"
rm -f "$OUT/VirtualMacGuestTools.arm64" \
    "$OUT/VirtualMacGuestTools.x86_64" \
    "$OUT/OpenGLPVGCompat.dylib" \
    "$OUT/com.mac.virtual.guest-tools.plist" \
    "$OUT/com.mac.virtual.opengl-compat.plist" \
    "$OUT/VirtualMacGamepadReceiver" \
    "$OUT/Start VirtualMac Gamepad.command" \
    "$OUT/Virtual Mac OpenGL Acceleration" \
    "$OUT/VirtualMacGuestTools.tar.gz"
mkdir -p "$MACOS" "$RESOURCES"
cp "$VZ_REPO_ROOT/vz/guest/VirtualMacGuestTools-Info.plist" \
    "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string \
    "${VZ_RELEASE_VERSION:-1.2.3}" "$CONTENTS/Info.plist"

for architecture in arm64 x86_64; do
    xcrun --sdk macosx clang -arch "$architecture" -fblocks \
        -mmacosx-version-min=12.0 -framework AppKit \
        "$VZ_REPO_ROOT/vz/guest/VirtualMacGuestToolsApp.m" \
        -o "$OUT/VirtualMacGuestTools.$architecture"
done
xcrun lipo -create "$OUT/VirtualMacGuestTools.arm64" \
    "$OUT/VirtualMacGuestTools.x86_64" -output "$MACOS/Virtual Mac Guest Tools"

cp -R "$VZ_REPO_ROOT/assets/GuestToolsSymbols.xcassets" "$SYMBOL_CATALOG"
for symbol in vm.laptopcomputer vm.laptopcomputer.badge.checkmark; do
    symbolset="$SYMBOL_CATALOG/$symbol.symbolset"
    cp "$VZ_REPO_ROOT/assets/icons/$symbol.svg" "$symbolset/$symbol.svg"
done
xcrun actool --compile "$RESOURCES" --platform macosx \
    --minimum-deployment-target 12.0 "$SYMBOL_CATALOG" >/dev/null
for localization in "$VZ_REPO_ROOT/resources/Localizations/"*.lproj; do
    destination="$RESOURCES/$(basename "$localization")"
    mkdir -p "$destination"
    cp "$localization/Localizable.strings" "$destination/"
done

ICONSET="$OUT/VirtualMac.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$VZ_REPO_ROOT/assets/VirtualMacGuest.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$VZ_REPO_ROOT/assets/VirtualMacGuest.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/VirtualMac.icns"

codesign --force --sign - "$APP"

cp "$OPENGL_OUT/OpenGLPVGCompat.dylib" "$OUT/OpenGLPVGCompat.dylib"
cp "$GAMEPAD_RECEIVER" "$OUT/VirtualMacGamepadReceiver"
cp "$VZ_REPO_ROOT/vz/guest/Start VirtualMac Gamepad.command" \
    "$OUT/Start VirtualMac Gamepad.command"
cp "$VZ_REPO_ROOT/vz/guest/com.mac.virtual.guest-tools.plist" \
    "$OUT/com.mac.virtual.guest-tools.plist"
PAYLOAD="$OUT/payload"
mkdir -p "$PAYLOAD/Library/VirtualMac/Gamepad" \
    "$PAYLOAD/Library/LaunchAgents"
cp -R "$APP" "$PAYLOAD/Library/VirtualMac/"
cp "$OUT/OpenGLPVGCompat.dylib" "$PAYLOAD/Library/VirtualMac/"
cp "$OUT/VirtualMacGamepadReceiver" "$PAYLOAD/Library/VirtualMac/Gamepad/"
cp "$OUT/Start VirtualMac Gamepad.command" \
    "$PAYLOAD/Library/VirtualMac/Gamepad/"
cp "$OUT/com.mac.virtual.guest-tools.plist" \
    "$PAYLOAD/Library/LaunchAgents/"
chmod 755 "$PAYLOAD/Library/VirtualMac/Gamepad/VirtualMacGamepadReceiver" \
    "$PAYLOAD/Library/VirtualMac/Gamepad/Start VirtualMac Gamepad.command"
# Do not encode checkout provenance into the guest payload. macOS 27 launchd
# rejects quarantined LaunchAgents even when their syntax, ownership, and code
# signature are valid.
xattr -cr "$PAYLOAD"
tar -C "$PAYLOAD" -czf "$OUT/VirtualMacGuestTools.tar.gz" Library

printf 'Built %s\n' "$OUT"
