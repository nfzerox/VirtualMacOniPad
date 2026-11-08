#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-vm"
PAYLOAD="$OUT/payload"
BIN="$PAYLOAD/bin"
FRAMEWORKS="$PAYLOAD/Frameworks"
VMM="$PAYLOAD/VirtualMachine.xpc"
VMM_BIN="$VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
# The host and VMM are separate processes, but dyld can load both from this
# shared runtime directory. Keep XPC-private compatibility dylibs here too so
# the package has one authoritative framework location.
VMM_FRAMEWORKS="$FRAMEWORKS"
IPADOS15_COMPAT="$PAYLOAD/Compatibility/iPadOS15"
IPADOS15_AUTH_COMPAT="$PAYLOAD/Compatibility/iPadOS15Authenticated"
IPADOS14_COMPAT="$PAYLOAD/Compatibility/iPadOS14"
IPADOS14_HV="$VZ_BUILD_ROOT/ipados14-hypervisor"
LIBSYSTEM15_COMPAT="$VMM_FRAMEWORKS/LibSystem15Compat.dylib"
IOKIT15_COMPAT="$VMM_FRAMEWORKS/IOKit15Compat.dylib"
IOKIT14_COMPAT="$OUT/ipados14-vmm/IOKit15Compat.dylib"
SOURCE_VZ="$VZ_BUILD_ROOT/inputs/macos/22D68__MacOS/System/Library/Frameworks/Virtualization.framework/Versions/A"
SOURCE_VMM="$SOURCE_VZ/XPCServices/com.apple.Virtualization.VirtualMachine.xpc"
IOS_FRAMEWORKS="$VZ_BUILD_ROOT/frameworks/bundles/ios"
ENTS="$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements"
VMM_ENTS="$VZ_REPO_ROOT/vz/patches/vmm.ents.xml"
VMM_OPTIONAL_DEVICES_PATCH="$VZ_REPO_ROOT/vz/patches/patch_vmm_optional_devices.py"
VMM_PCI_ADDRESS_PATCH="$VZ_REPO_ROOT/vz/patches/patch_vmm_pci_address.py"
PVG_EXCEPTION_LOG_PATCH="$VZ_REPO_ROOT/vz/patches/patch_pvg_exception_log.py"
MACHO_CSTRING_PATCH="$VZ_REPO_ROOT/vz/patches/patch_macho_cstring.py"
METAL_SERIALIZER_FRAMEWORK="$IOS_FRAMEWORKS/MetalSerializer.framework"
VMNET_FRAMEWORK="$VZ_BUILD_ROOT/ipad-vmnet/vmnet.framework"
NETRB_FRAMEWORK="$VZ_BUILD_ROOT/ipad-netrb/Netrb.framework"
IPADOS14_VMNET_FRAMEWORK="$VZ_BUILD_ROOT/ipad-vmnet14/vmnet.framework"
IPADOS14_NETRB_FRAMEWORK="$VZ_BUILD_ROOT/ipad-netrb14/Netrb.framework"
VIDEOTOOLBOX_FRAMEWORK="$VZ_BUILD_ROOT/ipad-videotoolbox/VideoToolbox.framework"
VIDEOTOOLBOX_PV_FRAMEWORK="$VZ_BUILD_ROOT/ipad-videotoolbox/VideoToolboxParavirtualizationSupport.framework"
DISKIMAGES2_FRAMEWORK="$VZ_BUILD_ROOT/ipad-diskimages2/DiskImages2.framework"
ENTITLEMENT_AUDIT="$VZ_REPO_ROOT/scripts/audit-entitlements.py"
IPADOS15_OBJC_PATCH="$VZ_REPO_ROOT/vz/patches/patch_ipados15_objc_class_data.py"
IPADOS15_OBJC_IMPORT_PATCH="$VZ_REPO_ROOT/vz/patches/patch_ipados15_objc_imports.py"
IPADOS14_VMM_VMNET_PATCH="$VZ_REPO_ROOT/vz/patches/patch_ipados14_vmm_vmnet_import.py"
IPADOS14_VMM_VIDEOTOOLBOX_PATCH="$VZ_REPO_ROOT/vz/patches/patch_ipados14_vmm_videotoolbox_import.py"
VMM_IPADOS14_ENTS="$OUT/vmm-ipados14.ents.xml"

need_command codesign
need_command ditto
need_command install_name_tool
need_command ldid
need_command lipo
need_command otool
need_command xcrun
need_file "$SOURCE_VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
need_file "$SOURCE_VZ/Resources/AVPBooter.vmapple2.bin"
need_file "$ENTS"
need_file "$VMM_ENTS"
need_file "$VMM_OPTIONAL_DEVICES_PATCH"
need_file "$VMM_PCI_ADDRESS_PATCH"
need_file "$PVG_EXCEPTION_LOG_PATCH"
need_file "$MACHO_CSTRING_PATCH"
need_file "$ENTITLEMENT_AUDIT"
need_file "$IPADOS15_OBJC_PATCH"
need_file "$IPADOS15_OBJC_IMPORT_PATCH"
need_file "$IPADOS14_VMM_VMNET_PATCH"
need_file "$IPADOS14_VMM_VIDEOTOOLBOX_PATCH"
need_file "$VZ_REPO_ROOT/vz/host/pvg_trace.m"
need_file "$VZ_REPO_ROOT/vz/shaders/pvg_display.metal"

macho_matches_target() {
    local candidate="$1"
    [[ -f "$candidate" ]] && otool -l "$candidate" | awk \
        -v target="$VZ_IPADOS_MIN_VERSION" '
            /cmd LC_BUILD_VERSION/ { found=1 }
            found && /minos/ { checked=1; exit !($2 == target) }
            END { if (!found || !checked) exit 1 }
        '
}

restamp_bundle() {
    local binary="$1" bundle="$2" temporary
    temporary="$binary.restamped"
    "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
        "$VZ_REPO_ROOT/vz/stamp_ios.py" "$binary" "$temporary" \
        "$VZ_IPADOS_MIN_VERSION"
    mv -f "$temporary" "$binary"
    chmod 755 "$binary"
    codesign --force --sign - "$bundle"
}

frameworks_present=1
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    candidate="$IOS_FRAMEWORKS/$name.framework/Versions/A/$name"
    [[ -f "$candidate" ]] || frameworks_present=0
done
[[ -f "$METAL_SERIALIZER_FRAMEWORK/Versions/A/MetalSerializer" ]] || \
    frameworks_present=0
if (( frameworks_present )) && [[ "${VZ_REUSE_EXTRACTED_RUNTIME:-0}" == 1 ]]; then
    # Changing LC_BUILD_VERSION does not require re-running dyld extraction.
    # This is the fast path used while extending the same Ventura runtime to
    # an older iPadOS deployment floor.
    for name in Hypervisor ParavirtualizedGraphics Virtualization; do
        candidate="$IOS_FRAMEWORKS/$name.framework/Versions/A/$name"
        macho_matches_target "$candidate" || \
            restamp_bundle "$candidate" "$IOS_FRAMEWORKS/$name.framework"
    done
    candidate="$METAL_SERIALIZER_FRAMEWORK/Versions/A/MetalSerializer"
    macho_matches_target "$candidate" || \
        restamp_bundle "$candidate" "$METAL_SERIALIZER_FRAMEWORK"
elif (( ! frameworks_present )); then
    echo "rebuilding Ventura framework bundles for iPadOS $VZ_IPADOS_MIN_VERSION"
    "$SCRIPT_DIR/build-frameworks.sh"
fi
need_file "$METAL_SERIALIZER_FRAMEWORK/Versions/A/MetalSerializer"
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    need_file "$IOS_FRAMEWORKS/$name.framework/Versions/A/$name"
done

if [[ "${VZ_REUSE_EXTRACTED_RUNTIME:-0}" == 1 ]]; then
    [[ -f "$VMNET_FRAMEWORK/vmnet" ]] || "$SCRIPT_DIR/build-ipad-vmnet.sh"
    [[ -f "$NETRB_FRAMEWORK/Netrb" ]] || "$SCRIPT_DIR/build-ipad-netrb.sh"
    [[ -f "$VIDEOTOOLBOX_FRAMEWORK/VideoToolbox" ]] || \
        "$SCRIPT_DIR/build-ipad-videotoolbox.sh"
    [[ -f "$VIDEOTOOLBOX_PV_FRAMEWORK/VideoToolboxParavirtualizationSupport" ]] || \
        "$SCRIPT_DIR/build-ipad-videotoolbox.sh"
    [[ -f "$DISKIMAGES2_FRAMEWORK/Versions/A/DiskImages2" ]] || \
        "$SCRIPT_DIR/build-ipad-diskimages2.sh"
    macho_matches_target "$VMNET_FRAMEWORK/vmnet" || \
        restamp_bundle "$VMNET_FRAMEWORK/vmnet" "$VMNET_FRAMEWORK"
    macho_matches_target "$NETRB_FRAMEWORK/Netrb" || \
        restamp_bundle "$NETRB_FRAMEWORK/Netrb" "$NETRB_FRAMEWORK"
    macho_matches_target "$VIDEOTOOLBOX_FRAMEWORK/VideoToolbox" || \
        restamp_bundle "$VIDEOTOOLBOX_FRAMEWORK/VideoToolbox" \
            "$VIDEOTOOLBOX_FRAMEWORK"
    macho_matches_target "$VIDEOTOOLBOX_PV_FRAMEWORK/VideoToolboxParavirtualizationSupport" || \
        restamp_bundle \
            "$VIDEOTOOLBOX_PV_FRAMEWORK/VideoToolboxParavirtualizationSupport" \
            "$VIDEOTOOLBOX_PV_FRAMEWORK"
    macho_matches_target "$DISKIMAGES2_FRAMEWORK/Versions/A/DiskImages2" || \
        restamp_bundle "$DISKIMAGES2_FRAMEWORK/Versions/A/DiskImages2" \
            "$DISKIMAGES2_FRAMEWORK"
else
    "$SCRIPT_DIR/build-ipad-vmnet.sh"
    "$SCRIPT_DIR/build-ipad-netrb.sh"
    "$SCRIPT_DIR/build-ipad-videotoolbox.sh"
    "$SCRIPT_DIR/build-ipad-diskimages2.sh"
fi
need_file "$VMNET_FRAMEWORK/vmnet"
need_file "$NETRB_FRAMEWORK/Netrb"
need_file "$VIDEOTOOLBOX_FRAMEWORK/VideoToolbox"
need_file "$VIDEOTOOLBOX_PV_FRAMEWORK/VideoToolboxParavirtualizationSupport"
need_file "$DISKIMAGES2_FRAMEWORK/Versions/A/DiskImages2"

if [[ "${VZ_REUSE_EXTRACTED_RUNTIME:-0}" != 1 ||
      ! -f "$IPADOS14_VMNET_FRAMEWORK/vmnet" ||
      ! -f "$IPADOS14_NETRB_FRAMEWORK/Netrb" ]]; then
    "$SCRIPT_DIR/build-ipados14-network-stack.sh"
fi
need_file "$IPADOS14_VMNET_FRAMEWORK/vmnet"
need_file "$IPADOS14_NETRB_FRAMEWORK/Netrb"

rm -rf "$PAYLOAD"
mkdir -p "$BIN" "$FRAMEWORKS"
for name in Hypervisor ParavirtualizedGraphics Virtualization; do
    ditto "$IOS_FRAMEWORKS/$name.framework" \
        "$FRAMEWORKS/$name.framework"
done
ditto "$VMNET_FRAMEWORK" "$FRAMEWORKS/vmnet.framework"
HOST_VZ_BINARY="$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" "$HOST_VZ_BINARY" \
    /System/Library/Frameworks/vmnet.framework/vmnet \
    @loader_path/../../../vmnet.framework/vmnet
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$FRAMEWORKS/Virtualization.framework"
ditto "$SOURCE_VMM" "$VMM"
rm -rf "$VMM/Contents/_CodeSignature" "$VMM/Contents/Frameworks"
/usr/libexec/PlistBuddy -c \
    "Add :NSMicrophoneUsageDescription string Virtual Mac microphone input" \
    "$VMM/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c \
        "Set :NSMicrophoneUsageDescription Virtual Mac microphone input" \
        "$VMM/Contents/Info.plist"
mkdir -p "$VMM_FRAMEWORKS"
lipo -thin arm64e \
    "$SOURCE_VMM/Contents/MacOS/com.apple.Virtualization.VirtualMachine" \
    -output "$VMM_BIN"
ditto "$NETRB_FRAMEWORK" "$VMM_FRAMEWORKS/Netrb.framework"
ditto "$VIDEOTOOLBOX_FRAMEWORK" \
    "$VMM_FRAMEWORKS/VideoToolbox.framework"
ditto "$VIDEOTOOLBOX_PV_FRAMEWORK" \
    "$VMM_FRAMEWORKS/VideoToolboxParavirtualizationSupport.framework"
ditto "$DISKIMAGES2_FRAMEWORK" \
    "$VMM_FRAMEWORKS/DiskImages2.framework"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" \
    "$VMM_FRAMEWORKS/vmnet.framework/vmnet" \
    /System/Library/PrivateFrameworks/Netrb.framework/Netrb \
    @loader_path/../Netrb.framework/Netrb
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$VMM_FRAMEWORKS/vmnet.framework/vmnet"
ditto "$METAL_SERIALIZER_FRAMEWORK" \
    "$VMM_FRAMEWORKS/MetalSerializer.framework"
METAL_SERIALIZER_FRAMEWORK="$VMM_FRAMEWORKS/MetalSerializer.framework"
METAL_SERIALIZER_BINARY="$METAL_SERIALIZER_FRAMEWORK/Versions/A/MetalSerializer"

PVG_BINARY="$VMM_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" "$PVG_BINARY" \
    /System/Library/PrivateFrameworks/MetalSerializer.framework/MetalSerializer \
    @loader_path/../../../MetalSerializer.framework/MetalSerializer
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$PVG_EXCEPTION_LOG_PATCH" "$PVG_BINARY"

PVG_RESOURCES="$VMM_FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/Resources"
cp "$PVG_RESOURCES/default.metallib" \
    "$PVG_RESOURCES/default.macos.metallib"
xcrun --sdk iphoneos metal \
    -std=metal3.0 -mios-version-min="$VZ_IPADOS_MIN_VERSION" -ffast-math \
    -c "$VZ_REPO_ROOT/vz/shaders/pvg_display.metal" \
    -o "$OUT/pvg_display.air"
xcrun --sdk iphoneos metallib \
    "$OUT/pvg_display.air" \
    -o "$PVG_RESOURCES/default.metallib"
# iPadOS 15's Metal runtime predates Metal language 3.0. Keep the established
# iPadOS 16 library as default and bundle an ABI-identical older-language set
# selected by the PVG hook only on pre-16 hosts.
xcrun --sdk iphoneos metal \
    -std=ios-metal2.4 -mios-version-min=15.0 -ffast-math \
    -c "$VZ_REPO_ROOT/vz/shaders/pvg_display.metal" \
    -o "$OUT/pvg_display.ipados15.air"
xcrun --sdk iphoneos metallib \
    "$OUT/pvg_display.ipados15.air" \
    -o "$PVG_RESOURCES/default.ipados15.metallib"
# iPadOS 14.5 supports Metal language 2.3. Keep this as a third resource;
# runtime selection is exact, so neither established newer-host path changes.
xcrun --sdk iphoneos metal \
    -std=ios-metal2.3 -mios-version-min=14.5 -ffast-math \
    -c "$VZ_REPO_ROOT/vz/shaders/pvg_display.metal" \
    -o "$OUT/pvg_display.ipados14.air"
xcrun --sdk iphoneos metallib \
    "$OUT/pvg_display.ipados14.air" \
    -o "$PVG_RESOURCES/default.ipados14.metallib"

xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" -fblocks \
    -framework Foundation \
    "$VZ_REPO_ROOT/vz/host/vzboot.m" \
    -o "$BIN/vzboot"
xcrun --sdk iphoneos clang \
    -arch arm64 -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -framework Foundation -framework Metal -framework UIKit \
    -Wl,-export_dynamic \
    "$VZ_REPO_ROOT/vz/host/NSViewShim.m" \
    "$VZ_REPO_ROOT/vz/development/probes/objc_methods.m" \
    -o "$BIN/objc-methods"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -install_name "@rpath/VZHostCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/vzxpchook.m" \
    -o "$BIN/VZHostCompat.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib \
    -framework Foundation \
    -Wl,-reexport_framework,Metal \
    -install_name "@rpath/MetalCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/native_bc_texture_support.m" \
    "$VZ_REPO_ROOT/vz/host/metalshim.m" \
    -o "$VMM_FRAMEWORKS/MetalCompat.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework AVFAudio \
    -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name "@rpath/LaunchServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/lsshim.m" \
    "$VZ_REPO_ROOT/vz/host/vmmhook.m" \
    "$VZ_REPO_ROOT/vz/host/VZNativeTouchBackend.m" \
    "$VZ_REPO_ROOT/vz/host/VZGPUCompatibilityBootstrap.m" \
    "$VZ_REPO_ROOT/vz/host/pvg_trace.m" \
    -o "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib \
    -Wl,-reexport_library,"$SDK/usr/lib/libSystem.B.tbd" \
    -install_name "@rpath/LibSystem15Compat.dylib" \
    "$VZ_REPO_ROOT/vz/host/libsystem15_compat.c" \
    -o "$LIBSYSTEM15_COMPAT"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -framework CoreFoundation \
    -Wl,-reexport_framework,IOKit \
    -install_name "@rpath/IOKit15Compat.dylib" \
    "$VZ_REPO_ROOT/vz/host/iokit15_compat.c" \
    -o "$IOKIT15_COMPAT"
mkdir -p "$(dirname "$IOKIT14_COMPAT")"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -framework CoreFoundation \
    -Wl,-reexport_framework,IOKit \
    -install_name "@rpath/IOKit15Compat.dylib" \
    "$VZ_REPO_ROOT/vz/host/iokit14_compat.c" \
    -o "$IOKIT14_COMPAT"

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/stamp_ios.py" "$VMM_BIN" "$VMM_BIN.ios" \
    "$VZ_IPADOS_MIN_VERSION"
mv -f "$VMM_BIN.ios" "$VMM_BIN"

install_name_tool \
    -change \
    /System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia \
    /System/Library/Frameworks/CoreMedia.framework/CoreMedia \
    -change \
    /System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor \
    @loader_path/../../../Frameworks/Hypervisor.framework/Hypervisor \
    -change \
    /System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics \
    @loader_path/../../../Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics \
    -change \
    /System/Library/Frameworks/Metal.framework/Versions/A/Metal \
    @loader_path/../../../Frameworks/MetalCompat.dylib \
    -change \
    /System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices \
    @loader_path/../../../Frameworks/LaunchServicesCompat.dylib \
    -change \
    /System/Library/Frameworks/vmnet.framework/Versions/A/vmnet \
    @loader_path/../../../Frameworks/vmnet.framework/vmnet \
    -change \
    /System/Library/PrivateFrameworks/ParavirtualizedANE.framework/Versions/A/ParavirtualizedANE \
    /System/Library/PrivateFrameworks/ParavirtualizedANE.framework/ParavirtualizedANE \
    -change \
    /System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/ExtensionFoundation \
    /System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation \
    -change \
    /System/Library/Frameworks/Security.framework/Versions/A/Security \
    /System/Library/Frameworks/Security.framework/Security \
    -change \
    /System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox \
    @loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox \
    -change \
    /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    /System/Library/Frameworks/Foundation.framework/Foundation \
    -change \
    /System/Library/Frameworks/AudioToolbox.framework/Versions/A/AudioToolbox \
    /System/Library/Frameworks/AudioToolbox.framework/AudioToolbox \
    -change \
    /System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio \
    /System/Library/Frameworks/CoreAudio.framework/CoreAudio \
    -change \
    /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    -change \
    /System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics \
    /System/Library/Frameworks/CoreGraphics.framework/CoreGraphics \
    -change \
    /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    /System/Library/Frameworks/IOKit.framework/IOKit \
    -change \
    /System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface \
    /System/Library/Frameworks/IOSurface.framework/IOSurface \
    -change \
    /System/Library/Frameworks/IOUSBHost.framework/Versions/A/IOUSBHost \
    /System/Library/PrivateFrameworks/IOUSBHost.framework/IOUSBHost \
    -change \
    /System/Library/PrivateFrameworks/DiskImages2.framework/Versions/A/DiskImages2 \
    /System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2 \
    "$VMM_BIN"

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VMM_OPTIONAL_DEVICES_PATCH" "$VMM_BIN"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VMM_PCI_ADDRESS_PATCH" "$VMM_BIN"

ldid -S"$ENTS" "$BIN/vzboot"
ldid -S"$ENTS" "$BIN/objc-methods"
ldid -S"$ENTS" "$BIN/VZHostCompat.dylib"
for dylib in \
    "$VMM_FRAMEWORKS/MetalCompat.dylib" \
    "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib" \
    "$LIBSYSTEM15_COMPAT" \
    "$IOKIT15_COMPAT"; do
    ldid -S"$VMM_ENTS" "$dylib"
done

codesign --verify "$VMM_FRAMEWORKS/vmnet.framework/vmnet"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime \
    "$METAL_SERIALIZER_FRAMEWORK"
codesign --force --sign - \
    --preserve-metadata=entitlements,requirements,flags,runtime "$PVG_BINARY"
ldid -S"$VMM_ENTS" "$VMM_BIN"

# iPadOS 15's native DiskImages2 predates the C++ ABI used by Ventura's VMM.
# Preserve the established iPadOS 16 binary verbatim and build a second VMM
# whose only difference is loading the bundled matching Ventura framework.
# postinst selects the appropriate binary from the actual host version.
VMM_IPADOS16="$VMM_BIN.ipados16"
VMM_IPADOS15="$VMM_BIN.ipados15"
VMM_IPADOS14="$VMM_BIN.ipados14"
cp "$VMM_BIN" "$VMM_IPADOS16"
cp "$VMM_BIN" "$VMM_IPADOS15"
install_name_tool -change \
    /System/Library/PrivateFrameworks/DiskImages2.framework/DiskImages2 \
    @loader_path/../../../Frameworks/DiskImages2.framework/DiskImages2 \
    -change /usr/lib/libSystem.B.dylib \
    @loader_path/../../../Frameworks/LibSystem15Compat.dylib \
    -change /System/Library/Frameworks/IOKit.framework/IOKit \
    @loader_path/../../../Frameworks/IOKit15Compat.dylib \
    "$VMM_IPADOS15"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$IPADOS15_OBJC_IMPORT_PATCH" "$VMM_IPADOS15"
# The optional PVG reset-retain list can be null when RestoreOS tears down its
# first graphics context. Both iPadOS 14 and newer 15.x libobjc paths expose
# the same Ventura VMM cleanup bug; guard only the older-host VMM variant.
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/patches/patch_vmm_optional_pvg_reset.py" \
    "$VMM_IPADOS15"
ldid -Icom.apple.Virtualization.VirtualMachine \
    -S"$VMM_ENTS" "$VMM_IPADOS15"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/stamp_ios.py" "$VMM_IPADOS15" "$VMM_IPADOS14" 14.5
install_name_tool \
    -change @loader_path/../../../Frameworks/LibSystem15Compat.dylib \
        @loader_path/../../../Frameworks/LibSystem14 \
    -change /usr/lib/libc++.1.dylib \
        @loader_path/../../../Frameworks/LibCxx.dylib \
    "$VMM_IPADOS14"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$IPADOS14_VMM_VMNET_PATCH" "$VMM_IPADOS14"
# Old dyld otherwise coalesces this weak import with iPadOS 14's system
# VideoToolbox, whose API does not include the Mac paravirtual host endpoint.
# Keep the private extracted framework mandatory only in the 14.x VMM.
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$IPADOS14_VMM_VIDEOTOOLBOX_PATCH" "$VMM_IPADOS14"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$VZ_REPO_ROOT/vz/patches/patch_vmm_optional_pvg_reset.py" \
    "$VMM_IPADOS14"
cp "$VMM_ENTS" "$VMM_IPADOS14_ENTS"
/usr/libexec/PlistBuddy -c \
    "Add :com.apple.MobileInternetSharing.allow bool true" \
    "$VMM_IPADOS14_ENTS"
ldid -Icom.apple.Virtualization.VirtualMachine \
    -S"$VMM_IPADOS14_ENTS" "$VMM_IPADOS14"

# The iPadOS 14 VMM's vmnet path requires both its private checksum data-plane
# interposer and MobileInternetSharing entitlement. Compile only that hot-path
# difference separately; Hypervisor compatibility remains runtime-selected in
# the common source on every host.
VMM_HOOK_IPADOS14="$VMM_FRAMEWORKS/LaunchServicesCompat.dylib.ipados14"
xcrun --sdk iphoneos clang \
    -arch arm64e -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" -isysroot "$SDK" \
    -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -DVZ_IPADOS14_NETWORK_COMPAT=1 \
    -framework AVFAudio \
    -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices \
    -install_name "@rpath/LaunchServicesCompat.dylib" \
    "$VZ_REPO_ROOT/vz/host/lsshim.m" \
    "$VZ_REPO_ROOT/vz/host/vmmhook.m" \
    "$VZ_REPO_ROOT/vz/host/VZNativeTouchBackend.m" \
    "$VZ_REPO_ROOT/vz/host/VZGPUCompatibilityBootstrap.m" \
    "$VZ_REPO_ROOT/vz/host/pvg_trace.m" \
    -o "$VMM_HOOK_IPADOS14"
ldid -ILaunchServicesCompat.dylib \
    -S"$VMM_IPADOS14_ENTS" "$VMM_HOOK_IPADOS14"

# Ventura uses its newer arm64e Objective-C ABI for class_t::data.  Preserve
# every established framework byte-for-byte in its normal location and keep
# legacy-ABI replacement binaries outside the signed bundles.  postinst copies
# them into place only on iPadOS 14/15; iPadOS 16 never loads this adaptation.
mkdir -p "$IPADOS15_COMPAT" "$IPADOS15_AUTH_COMPAT"
legacy_objc_binaries=(
    "Hypervisor|$FRAMEWORKS/Hypervisor.framework/Versions/A/Hypervisor"
    "ParavirtualizedGraphics|$FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
    "Virtualization|$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization"
    "MetalSerializer|$FRAMEWORKS/MetalSerializer.framework/Versions/A/MetalSerializer"
    "VideoToolbox|$FRAMEWORKS/VideoToolbox.framework/VideoToolbox"
    "DiskImages2|$FRAMEWORKS/DiskImages2.framework/Versions/A/DiskImages2"
)
for specification in "${legacy_objc_binaries[@]}"; do
    name="${specification%%|*}"
    binary="${specification#*|}"
    authenticated="$IPADOS15_AUTH_COMPAT/$name"
    legacy="$IPADOS15_COMPAT/$name"
    cp "$binary" "$authenticated"
    "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
        "$IPADOS15_OBJC_IMPORT_PATCH" "$authenticated"
    cp "$authenticated" "$legacy"
    "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
        "$IPADOS15_OBJC_PATCH" "$legacy"
    codesign --force --sign - "$authenticated"
    codesign --force --sign - "$legacy"
done

# Only the pre-iPadOS 16 VideoToolbox replacement must prefer the bundled
# support framework.  Leave the normal binary untouched so iPadOS 16 keeps
# loading its proven system copy byte-for-byte.
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" "$IPADOS15_COMPAT/VideoToolbox" \
    /System/Library/PrivateFrameworks/VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport \
    @loader_path/../VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport
codesign --force --sign - "$IPADOS15_COMPAT/VideoToolbox"
"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
    "$MACHO_CSTRING_PATCH" "$IPADOS15_AUTH_COMPAT/VideoToolbox" \
    /System/Library/PrivateFrameworks/VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport \
    @loader_path/../VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport
codesign --force --sign - "$IPADOS15_AUTH_COMPAT/VideoToolbox"

# iPadOS 14 uses the same legacy Objective-C ABI adaptation as iPadOS 15,
# but dyld also requires an image whose deployment target is no newer than
# the host. Preserve the proven iPadOS 15 copies and restamp separate files.
mkdir -p "$IPADOS14_COMPAT"
ldid -S"$VMM_ENTS" "$IOKIT14_COMPAT"
cp "$IOKIT14_COMPAT" "$IPADOS14_COMPAT/IOKit15Compat.dylib"
for legacy15 in "$IPADOS15_COMPAT"/*; do
    name="$(basename "$legacy15")"
    legacy14_input="$legacy15"
    if [[ "$name" == Virtualization ]]; then
        # iPadOS 14's dyld does not coalesce a preloaded framework by its
        # missing macOS install-name path. Retarget only the 14.x copy; the
        # proven iPadOS 15 and 16 framework images remain unchanged.
        cp "$legacy15" "$OUT/Virtualization.ipados14.input"
        "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
            "$MACHO_CSTRING_PATCH" "$OUT/Virtualization.ipados14.input" \
            /System/Library/Frameworks/Hypervisor.framework/Hypervisor \
            @loader_path/../../../Hypervisor.framework/Hypervisor
        legacy14_input="$OUT/Virtualization.ipados14.input"
    fi
    "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
        "$VZ_REPO_ROOT/vz/stamp_ios.py" "$legacy14_input" \
        "$IPADOS14_COMPAT/$name" 14.5
    if [[ "$name" == VideoToolbox ]]; then
        # iPadOS 14 preloads its system VideoToolbox before the VMM's explicit
        # @loader_path dependency is resolved. If the extracted framework
        # retains Apple's system LC_ID_DYLIB, old dyld coalesces the two and
        # the VMM later calls missing Mac host-session exports through NULL.
        # Give only the 14.x compatibility copy a private identity so the
        # bundled Ventura implementation is mapped as a distinct image.
        "$VZ_BUILD_ROOT/toolchain/venv/bin/python3" \
            "$MACHO_CSTRING_PATCH" "$IPADOS14_COMPAT/$name" \
            /System/Library/Frameworks/VideoToolbox.framework/VideoToolbox \
            @rpath/VirtualMacVideoToolbox
    fi
    codesign --force --sign - "$IPADOS14_COMPAT/$name"
done

# iPadOS 14/XNU 20 uses the aligned Big Sur Hypervisor implementation. The
# facade preserves Ventura VMM's newer public imports while forwarding the
# common ABI to Apple's matching binary. These copies overwrite only the 14.x
# compatibility slot; iPadOS 15 continues using Ventura Hypervisor unchanged.
"$SCRIPT_DIR/build-ipados14-hypervisor.sh"
cp "$IPADOS14_HV/Hypervisor" "$IPADOS14_COMPAT/Hypervisor"
cp "$IPADOS14_HV/HypervisorBigSur" "$IPADOS14_COMPAT/HypervisorBigSur"
cp "$IPADOS14_HV/LibSystemCompat.dylib" \
    "$IPADOS14_COMPAT/LibSystemCompat.dylib"
cp "$IPADOS14_HV/LibCxx.dylib" "$VMM_FRAMEWORKS/LibCxx.dylib"
cp "$IPADOS14_VMNET_FRAMEWORK/vmnet" "$IPADOS14_COMPAT/vmnet"
cp "$IPADOS14_NETRB_FRAMEWORK/Netrb" "$IPADOS14_COMPAT/Netrb"

# Finder and BridgeSupport metadata from the extracted frameworks are not
# used by the Objective-C runtime. Remove them before resealing every
# structured framework whose resource envelope may have referenced them.
find "$PAYLOAD" -type f \( -name .DS_Store -o -name '._*' \) -delete
find "$FRAMEWORKS" -type d -name BridgeSupport -prune \
    -exec rm -rf {} +
for framework in \
    "$FRAMEWORKS/Hypervisor.framework" \
    "$FRAMEWORKS/ParavirtualizedGraphics.framework" \
    "$FRAMEWORKS/Virtualization.framework" \
    "$FRAMEWORKS/MetalSerializer.framework" \
    "$FRAMEWORKS/DiskImages2.framework"; do
    codesign --force --sign - \
        --preserve-metadata=entitlements,requirements,flags,runtime \
        "$framework"
    codesign --verify --deep --strict "$framework"
done

"$VZ_BUILD_ROOT/toolchain/venv/bin/python3" "$ENTITLEMENT_AUDIT" \
    "$ENTS" "$BIN/vzboot" \
    "$ENTS" "$BIN/objc-methods" \
    "$ENTS" "$BIN/VZHostCompat.dylib" \
    "$VMM_ENTS" "$VMM_BIN" \
    "$VMM_IPADOS14_ENTS" "$VMM_IPADOS14" \
    "$VMM_ENTS" "$VMM_IPADOS15" \
    "$VMM_ENTS" "$VMM_IPADOS16" \
    "$VMM_ENTS" "$VMM_FRAMEWORKS/MetalCompat.dylib" \
    "$VMM_ENTS" "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib" \
    "$VMM_IPADOS14_ENTS" "$VMM_HOOK_IPADOS14" \
    "$VMM_ENTS" "$IPADOS14_COMPAT/Hypervisor" \
    "$VMM_ENTS" "$IPADOS14_COMPAT/LibSystemCompat.dylib" \
    "$VMM_ENTS" "$LIBSYSTEM15_COMPAT" \
    "$VMM_ENTS" "$IOKIT15_COMPAT" \
    - "$FRAMEWORKS/Hypervisor.framework/Versions/A/Hypervisor" \
    - "$FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics" \
    - "$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization" \
    - "$VMM_FRAMEWORKS/vmnet.framework/vmnet" \
    - "$VMM_FRAMEWORKS/Netrb.framework/Netrb" \
    - "$METAL_SERIALIZER_BINARY" \
    - "$VMM_FRAMEWORKS/VideoToolbox.framework/VideoToolbox" \
    - "$VMM_FRAMEWORKS/VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport" \
    - "$VMM_FRAMEWORKS/DiskImages2.framework/Versions/A/DiskImages2"

otool -l "$VMM_BIN" | grep -q "LC_DYLD_CHAINED_FIXUPS" ||
    die "VMM lost LC_DYLD_CHAINED_FIXUPS"
otool -l "$VMM_BIN" |
    awk '/LC_BUILD_VERSION/{show=1; left=7} show && left-- > 0 {print}' |
    grep -q "platform 2" ||
    die "VMM is not stamped for iOS"
for dependency in \
    "@loader_path/../../../Frameworks/Hypervisor.framework/Hypervisor" \
    "@loader_path/../../../Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics" \
    "@loader_path/../../../Frameworks/MetalCompat.dylib" \
    "@loader_path/../../../Frameworks/LaunchServicesCompat.dylib" \
    "@loader_path/../../../Frameworks/vmnet.framework/vmnet" \
    "@loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox"; do
    otool -L "$VMM_BIN" | grep -Fq "$dependency" ||
        die "VMM is missing dependency: $dependency"
done
otool -L "$VMM_FRAMEWORKS/vmnet.framework/vmnet" | grep -Fq \
    "@loader_path/../Netrb.framework/Netrb" ||
    die "VMM vmnet is missing its patched Netrb dependency"

VZ_GPU_COMPAT_OUTPUT="$VMM_FRAMEWORKS/libVMMGPUCompatibility.dylib" bash "$SCRIPT_DIR/build-gpu-compat.sh"

{
    files=(
        "$BIN/vzboot"
        "$BIN/objc-methods"
        "$BIN/VZHostCompat.dylib"
        "$VMM_BIN"
        "$VMM_IPADOS14"
        "$VMM_IPADOS15"
        "$VMM_IPADOS16"
        "$VMM_FRAMEWORKS/MetalCompat.dylib"
        "$VMM_FRAMEWORKS/LaunchServicesCompat.dylib"
        "$VMM_HOOK_IPADOS14"
        "$LIBSYSTEM15_COMPAT"
        "$IOKIT15_COMPAT"
        "$VMM_FRAMEWORKS/LibCxx.dylib"
        "$VMM_FRAMEWORKS/vmnet.framework/vmnet"
        "$VMM_FRAMEWORKS/Netrb.framework/Netrb"
        "$METAL_SERIALIZER_BINARY"
        "$VMM_FRAMEWORKS/libVMMGPUCompatibility.dylib"
        "$VMM_FRAMEWORKS/VideoToolbox.framework/VideoToolbox"
        "$VMM_FRAMEWORKS/VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport"
        "$VMM_FRAMEWORKS/DiskImages2.framework/Versions/A/DiskImages2"
        "$FRAMEWORKS/Hypervisor.framework/Versions/A/Hypervisor"
        "$FRAMEWORKS/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics"
        "$FRAMEWORKS/Virtualization.framework/Versions/A/Virtualization"
        "$IPADOS15_COMPAT/Hypervisor"
        "$IPADOS15_COMPAT/ParavirtualizedGraphics"
        "$IPADOS15_COMPAT/Virtualization"
        "$IPADOS15_COMPAT/MetalSerializer"
        "$IPADOS15_COMPAT/VideoToolbox"
        "$IPADOS15_COMPAT/DiskImages2"
        "$IPADOS14_COMPAT/vmnet"
        "$IPADOS14_COMPAT/Netrb"
        "$IPADOS14_COMPAT/Hypervisor"
        "$IPADOS14_COMPAT/HypervisorBigSur"
        "$IPADOS14_COMPAT/LibSystemCompat.dylib"
    )
    for file in "${files[@]}"; do
        printf '%s\t%s\n' \
            "$(ldid -h "$file" | sed -n 's/^CDHash=//p')" \
            "${file#"$PAYLOAD/"}"
    done
} >"$PAYLOAD/trustcache.txt"

echo "iPad VM payload built with unavailable host devices optional and without validator/registry/PAC bypasses: $PAYLOAD"
