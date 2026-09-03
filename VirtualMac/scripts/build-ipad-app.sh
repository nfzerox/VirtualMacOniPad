#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-app"
APP="$OUT/VirtualMac.app"
BIN="$APP/VirtualMac"
HOOK="$APP/VZHostCompat.dylib"
DIAGNOSTICS="$OUT/virtualmac-diagnostics"
ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"

need_command ldid
need_command plutil
need_command sips
need_command xattr
need_command xcrun
need_file "$VZ_REPO_ROOT/vz/host/VirtualMac-Info.plist"
need_file "$VZ_REPO_ROOT/vz/host/VirtualMacLaunchScreen.storyboard"
need_file "$VZ_REPO_ROOT/assets/VirtualMac.png"
need_file "$VZ_REPO_ROOT/assets/VirtualMacTemplate.png"
for installer_icon in monterey ventura sonoma sequoia tahoe golden-gate ipsw; do
    need_file "$VZ_REPO_ROOT/assets/installers/$installer_icon.png"
done
need_file "$VZ_REPO_ROOT/vz/host/NSViewShim.m"
need_file "$VZ_REPO_ROOT/vz/host/VZAppSettings.m"
need_file "$VZ_REPO_ROOT/vz/host/VZGamepadBridge.m"
need_file "$VZ_REPO_ROOT/vz/host/VZGamepadSettingsViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZDiagnostics.m"
need_file "$VZ_REPO_ROOT/vz/host/VZFailureDetailsViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZRestoreCatalog.m"
need_file "$VZ_REPO_ROOT/vz/host/VZSupport.m"
need_file "$VZ_REPO_ROOT/scripts/validate-localizations.py"
need_file "$VZ_REPO_ROOT/vz/host/VZNewVMViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZProgressViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZSettingsViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VZTrackpadScrollBridge.m"
need_file "$VZ_REPO_ROOT/vz/host/VZGuestTools.m"
need_file "$VZ_REPO_ROOT/vz/host/VZGuestRuntimePolicy.m"
need_file "$VZ_REPO_ROOT/vz/host/VZVMLibraryViewController.m"
need_file "$VZ_REPO_ROOT/vz/host/VirtualMacApp.m"
need_file "$VZ_REPO_ROOT/vz/host/virtualmac_diagnostics_main.m"
need_file "$VZ_REPO_ROOT/vz/host/vzxpchook.m"
need_file "$ENTS"

# Guest payloads are built from source and bundled with the host app. macOS's
# built-in AppleQEMUGuestAgent installs them without network access or guest
# credentials on first boot.
"$VZ_REPO_ROOT/scripts/build-guest-tools.sh"
need_file "$VZ_BUILD_ROOT/guest-tools/VirtualMacGuestTools.tar.gz"

rm -rf "$APP"
python3 "$VZ_REPO_ROOT/scripts/validate-localizations.py"
mkdir -p "$APP"
cp "$VZ_REPO_ROOT/vz/host/VirtualMac-Info.plist" "$APP/Info.plist"
mkdir -p "$APP/GuestTools"
cp "$VZ_BUILD_ROOT/guest-tools/VirtualMacGuestTools.tar.gz" \
    "$APP/GuestTools/VirtualMacGuestTools.tar.gz"
sips -Z 320 "$VZ_REPO_ROOT/assets/VirtualMacTemplate.png" \
    --out "$APP/VirtualMacTemplate.png" >/dev/null
APP_VERSION="${VZ_RELEASE_VERSION:-1.2.3}"
APP_BUILD="$(git -C "$VZ_REPO_ROOT" rev-list --count HEAD)"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" \
    "$APP/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD" "$APP/Info.plist"
plutil -replace MinimumOSVersion -string "$VZ_IPADOS_MIN_VERSION" \
    "$APP/Info.plist"
cp "$VZ_REPO_ROOT/vendor/VirtualBuddy/ipsws_v2.json" "$APP/ipsws_v2.json"
if [[ -d "$VZ_REPO_ROOT/resources/Localizations" ]]; then
    cp -R "$VZ_REPO_ROOT/resources/Localizations/"*.lproj "$APP/"
fi
if [[ -d "$VZ_REPO_ROOT/assets/developers" ]]; then
    mkdir -p "$APP/Developers"
    cp "$VZ_REPO_ROOT/assets/developers/"* "$APP/Developers/"
fi
if [[ -d "$VZ_REPO_ROOT/assets/installers" ]]; then
    mkdir -p "$APP/Installers"
    for installer_icon in monterey ventura sonoma sequoia tahoe golden-gate ipsw; do
        cp "$VZ_REPO_ROOT/assets/installers/$installer_icon.png" "$APP/Installers/"
    done
fi
if [[ -d "$VZ_REPO_ROOT/assets/wallpapers" ]]; then
    mkdir -p "$APP/Wallpapers"
    cp "$VZ_REPO_ROOT/assets/wallpapers"/*.jpg "$APP/Wallpapers/"
    cp "$VZ_REPO_ROOT/assets/wallpapers"/*.png "$APP/Wallpapers/"
fi
xcrun ibtool --compile "$APP/VirtualMacLaunchScreen.storyboardc" \
    "$VZ_REPO_ROOT/vz/host/VirtualMacLaunchScreen.storyboard" \
    --target-device ipad \
    --minimum-deployment-target "$VZ_IPADOS_MIN_VERSION" >/dev/null

# Generate the exact legacy icon filenames consumed by iPadOS 16. The checked
# in 1024-pixel RGB master has no alpha channel, as required for app icons.
cp "$VZ_REPO_ROOT/assets/VirtualMac.png" "$APP/AppIcon1024x1024.png"
for spec in \
    '120 AppIcon60x60@2x.png' \
    '180 AppIcon60x60@3x.png' \
    '152 AppIcon76x76@2x.png' \
    '167 AppIcon83.5x83.5@2x.png'; do
    read -r size name <<<"$spec"
    sips -z "$size" "$size" "$VZ_REPO_ROOT/assets/VirtualMac.png" \
        --out "$APP/$name" >/dev/null
done

xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" -fblocks \
    -framework AVFAudio -framework CoreImage -framework Foundation \
    -framework GameController -framework Metal -framework QuartzCore \
    -framework Security -framework UIKit \
    -framework UniformTypeIdentifiers \
    -Wl,-export_dynamic -Wl,-undefined,dynamic_lookup \
    "$VZ_REPO_ROOT/vz/host/NSViewShim.m" \
    "$VZ_REPO_ROOT/vz/host/VZAppSettings.m" \
    "$VZ_REPO_ROOT/vz/host/VZGamepadBridge.m" \
    "$VZ_REPO_ROOT/vz/host/VZGamepadSettingsViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZDiagnostics.m" \
    "$VZ_REPO_ROOT/vz/host/VZFailureDetailsViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZRestoreCatalog.m" \
    "$VZ_REPO_ROOT/vz/host/VZSupport.m" \
    "$VZ_REPO_ROOT/vz/host/VZGuestTools.m" \
    "$VZ_REPO_ROOT/vz/host/VZGuestRuntimePolicy.m" \
    "$VZ_REPO_ROOT/vz/host/VZNewVMViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZProgressViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZSettingsViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VZTrackpadScrollBridge.m" \
    "$VZ_REPO_ROOT/vz/host/VZVMLibraryViewController.m" \
    "$VZ_REPO_ROOT/vz/host/VirtualMacApp.m" \
    -o "$BIN"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -install_name "@executable_path/VZHostCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/vzxpchook.m" \
    -o "$HOOK"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" -fblocks \
    -framework Foundation -framework UIKit \
    "$VZ_REPO_ROOT/vz/host/VZAppSettings.m" \
    "$VZ_REPO_ROOT/vz/host/VZDiagnostics.m" \
    "$VZ_REPO_ROOT/vz/host/virtualmac_diagnostics_main.m" \
    -o "$DIAGNOSTICS"

xattr -cr "$APP"
ldid -Icom.mac.virtual -S"$ENTS" "$BIN"
ldid -S"$ENTS" "$HOOK"
ldid -S "$DIAGNOSTICS"
echo "native iPad VM app built: $APP"
