#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUTPUT="${VZ_VMM_COMPAT_OUTPUT:-$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/LaunchServicesCompat.dylib}"
ENTITLEMENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"

need_command ldid
need_command xcrun
need_file "$ENTITLEMENTS"
need_file "$VZ_REPO_ROOT/vz/host/lsshim.m"
need_file "$VZ_REPO_ROOT/vz/host/vmmhook.m"
need_file "$VZ_REPO_ROOT/vz/host/pvg_trace.m"

mkdir -p "$(dirname "$OUTPUT")"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name "@rpath/LaunchServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/lsshim.m" \
    "$VZ_REPO_ROOT/vz/host/vmmhook.m" \
    "$VZ_REPO_ROOT/vz/host/VZNativeTouchBackend.m" \
    "$VZ_REPO_ROOT/vz/host/VZGPUCompatibilityBootstrap.m" \
    "$VZ_REPO_ROOT/vz/host/pvg_trace.m" \
    -o "$OUTPUT"
ldid -S"$ENTITLEMENTS" "$OUTPUT"

VZ_GPU_COMPAT_OUTPUT="$(dirname "$OUTPUT")/libVMMGPUCompatibility.dylib" bash "$SCRIPT_DIR/build-gpu-compat.sh"

echo "VMM compatibility library built: $OUTPUT"
echo "CDHash: $(ldid -h "$OUTPUT" | sed -n 's/^CDHash=//p')"
