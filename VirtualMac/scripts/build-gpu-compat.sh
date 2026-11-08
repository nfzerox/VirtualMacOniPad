#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
OUTPUT="${VZ_GPU_COMPAT_OUTPUT:-$VZ_BUILD_ROOT/ipad-vm/payload/Frameworks/libVMMGPUCompatibility.dylib}"
SOURCE="$VZ_REPO_ROOT/vz/host/GPUCompatibility"
mkdir -p "$(dirname "$OUTPUT")"
SOURCES=()
for unit in ThinRuntime RuntimeLog FifoBridge ThinBridge InfoBridge TextureBridge SharedResourceBridge DescriptorPrefixBridge StencilDescriptorBridge NegotiationBridge BackendBridge CommandDiagnostics DeviceInfoBridge ImageblockComputeBridge;do
 ext=m;if [[ "$unit" == ThinBridge ]];then ext=c;fi
 SOURCES+=("$SOURCE/$unit.$ext")
done
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" \
 -fobjc-arc -fobjc-arc-exceptions -fblocks -Wall -Wextra -DTHIN_RUNTIME_LIBRARY=1 \
 -framework Foundation -framework Metal -framework CoreGraphics -framework IOSurface \
 -I"$SOURCE" -dynamiclib -install_name @rpath/libVMMGPUCompatibility.dylib \
 "${SOURCES[@]}" -o "$OUTPUT"
ldid -S "$OUTPUT"
printf 'Built GPU compatibility library: %s\n' "$OUTPUT"
