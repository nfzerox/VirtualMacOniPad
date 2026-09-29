#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
for tool in xcrun ldid dpkg-deb python3 shasum ditto plutil rsync; do
    need_command "$tool"
done
"$SCRIPT_DIR/development/prepare-roothide-sdk.sh"

DEVELOPMENT=0
if [[ "${1:-}" == --development ]]; then
    DEVELOPMENT=1
    shift
fi
[[ $# == 0 ]] || die "usage: build-roothide-deb.sh [--development]"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
ROOTHIDE_SDK="${VZ_ROOTHIDE_SDK:-$VZ_BUILD_ROOT/toolchain/roothide-sdk/devkit}"
OUT="$VZ_BUILD_ROOT/roothide"
STAGE="$OUT/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/Applications" \
    "$STAGE/usr/libexec" "$STAGE/usr/bin" "$STAGE/usr/lib" \
    "$STAGE/usr/sbin" "$STAGE/Library/LaunchDaemons"
RUNTIME="$STAGE/usr/libexec/VirtualMac"
APP="$STAGE/Applications/VirtualMac.app"

# The default build assembles from freshly built component products (the same
# Apple-extracted runtime the standard package builds from), so payload-internal
# fixes flow in without reissuing a release deb. Set VZ_BASE_DEB to fall back to
# the released deb for reproducible-from-snapshot builds; in that mode component
# builds are skipped and the deb's extracted payload is reused.
if [[ -n "${VZ_BASE_DEB:-}" ]]; then
    DEB="$VZ_BASE_DEB"
    need_file "$DEB"
    actual="$(shasum -a 256 "$DEB" | awk '{print $1}')"
    [[ "$(dpkg-deb -f "$DEB" Package)" == com.mac.virtual ]] || die "unexpected base package"
    CACHE="$OUT/base-$actual"
    if [[ ! -f "$CACHE/.source-sha256" ]] ||
        [[ "$(cat "$CACHE/.source-sha256")" != "$actual" ]]; then
        mkdir -p "$CACHE"
        dpkg-deb -x "$DEB" "$CACHE"
        printf '%s\n' "$actual" > "$CACHE/.source-sha256"
    fi
    ditto "$CACHE/var/root/VirtualMac/payload" "$RUNTIME/payload"
    ditto "$CACHE/var/root/VirtualMac/install" "$RUNTIME/install"
    ditto "$CACHE/var/jb/Applications/VirtualMac.app" "$APP"
    ditto "$CACHE/var/jb/usr/lib" "$STAGE/usr/lib"
    ditto "$CACHE/var/jb/usr/libexec" "$STAGE/usr/libexec"
    ditto "$CACHE/var/jb/usr/sbin" "$STAGE/usr/sbin"
    for plist in com.apple.NetworkSharing.plist com.apple.bootpd.plist; do
        cp "$CACHE/var/jb/Library/LaunchDaemons/$plist" "$STAGE/Library/LaunchDaemons/"
    done
    mkdir -p "$STAGE/usr/lib/TweakInject"
    ditto "$CACHE/var/root/VirtualMac/bootstrap-common/usr/lib/TweakInject" \
        "$STAGE/usr/lib/TweakInject"
    SOURCE_TAG="deb:$actual"
else
    if [[ "${VZ_SKIP_REBUILD:-0}" != 1 ]]; then
        "$SCRIPT_DIR/build-ipad-vm.sh"
        "$SCRIPT_DIR/build-ipad-network-helpers.sh"
        "$SCRIPT_DIR/build-ipad-network-sharing.sh"
        "$SCRIPT_DIR/build-ipad-installation.sh"
        "$SCRIPT_DIR/build-ipad-app.sh"
        "$SCRIPT_DIR/build-springboard-tweak.sh"
    fi
    "$SCRIPT_DIR/audit-ipados-compatibility.sh"
    # Payload overlay order matters: the installation payload is staged first,
    # then the VM payload overlays it so the shared framework tree is the
    # authoritative VM-runtime copy (mirrors build-ipad-deb.sh).
    ditto "$VZ_BUILD_ROOT/ipad-installation/payload" "$RUNTIME/payload"
    ditto "$VZ_BUILD_ROOT/ipad-vm/payload" "$RUNTIME/payload"
    ditto "$VZ_BUILD_ROOT/ipad-installation/install" "$RUNTIME/install"
    ditto "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app" "$APP"
    install -m 755 "$VZ_BUILD_ROOT/ipad-app/virtualmac-diagnostics" \
        "$STAGE/usr/bin/virtualmac-diagnostics"
    # Component products retain dev-only probes that the standard deb strips;
    # remove them so the roothide package matches the released layout.
    rm -rf "$RUNTIME/payload/bin"
    rm -f "$RUNTIME/payload/trustcache.txt" \
        "$RUNTIME/install/restore-image-probe" \
        "$RUNTIME/install/usb-bridge-probe"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing" \
        "$STAGE/usr/libexec/InternetSharing"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados15" \
        "$STAGE/usr/libexec/InternetSharing.ipados15"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados16" \
        "$STAGE/usr/libexec/InternetSharing.ipados16"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/libmrc.dylib" \
        "$STAGE/usr/lib/libmrc.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/libmrc.ipados15-auth.dylib" \
        "$STAGE/usr/lib/libmrc.ipados15-auth.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/AuthorizationCompat.dylib" \
        "$STAGE/usr/lib/AuthorizationCompat.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/NetworkMemoryPolicy.dylib" \
        "$STAGE/usr/lib/NetworkMemoryPolicy.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/bootpd" \
        "$STAGE/usr/libexec/bootpd"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/rtadvd" \
        "$STAGE/usr/sbin/rtadvd"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/OpenDirectoryCompat.dylib" \
        "$STAGE/usr/lib/OpenDirectoryCompat.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/IOKit14Compat.dylib" \
        "$STAGE/usr/lib/IOKit14Compat.dylib"
    install -m 644 "$VZ_BUILD_ROOT/ipad-network-sharing/com.apple.NetworkSharing.plist" \
        "$STAGE/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
    install -m 644 "$VZ_BUILD_ROOT/ipad-network-helpers/com.apple.bootpd.plist" \
        "$STAGE/Library/LaunchDaemons/com.apple.bootpd.plist"
    mkdir -p "$STAGE/usr/lib/TweakInject"
    install -m 755 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.dylib" \
        "$STAGE/usr/lib/TweakInject/VZKeyboardPassthrough.dylib"
    install -m 644 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.plist" \
        "$STAGE/usr/lib/TweakInject/VZKeyboardPassthrough.plist"
    find "$STAGE" -type f \( -name .DS_Store -o -name '._*' \) -delete
    xattr -cr "$STAGE"
    SOURCE_TAG="component-build"
fi

# Select the iPadOS 16 variant as the default runtime/installation/network
# binary; the on-device selector promotes the matching variant on boot. This
# runs after both input branches have populated the stage.
vmm="$RUNTIME/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
cp "$vmm.ipados16" "$vmm"
installer="$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
cp "$installer.ipados16" "$installer"
cp "$STAGE/usr/libexec/InternetSharing.ipados16" "$STAGE/usr/libexec/InternetSharing"

compile=(xcrun --sdk iphoneos clang -miphoneos-version-min=15.0
    -isysroot "$SDK" -DVZ_ROOTHIDE -I"$ROOTHIDE_SDK"
    -L"$ROOTHIDE_SDK/roothide" -lroothide)
if [[ "$DEVELOPMENT" == 1 ]]; then
    compile+=(-DVZ_DEVELOPMENT)
fi
host="$VZ_REPO_ROOT/vz/host"
install_source="$VZ_REPO_ROOT/vz/install"
"${compile[@]}" -arch arm64 -fblocks \
    -framework AVFAudio -framework CoreImage -framework Foundation \
    -framework GameController -framework Metal -framework Security -framework UIKit \
    -framework UniformTypeIdentifiers -Wl,-export_dynamic -Wl,-undefined,dynamic_lookup \
    "$host/NSViewShim.m" "$host/VZAppSettings.m" "$host/VZDiagnostics.m" \
    "$host/VZFailureDetailsViewController.m" "$host/VZRestoreCatalog.m" \
    "$host/VZSupport.m" "$host/VZGuestTools.m" "$host/VZGuestRuntimePolicy.m" \
    "$host/VZNewVMViewController.m" "$host/VZProgressViewController.m" \
    "$host/VZSettingsViewController.m" "$host/VZTrackpadScrollBridge.m" \
    "$host/VZVMLibraryViewController.m" "$host/VirtualMacApp.m" -o "$APP/VirtualMac"
"${compile[@]}" -arch arm64e -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -install_name '@rpath/VZHostCompat.dylib' "$host/vzxpchook.m" -o "$APP/VZHostCompat.dylib"
cp "$APP/VZHostCompat.dylib" "$RUNTIME/install/VZHostCompat.dylib"
"${compile[@]}" -arch arm64 -fblocks -framework Foundation -framework UIKit \
    "$host/VZAppSettings.m" "$host/VZDiagnostics.m" "$host/virtualmac_diagnostics_main.m" \
    -o "$STAGE/usr/bin/virtualmac-diagnostics"
"${compile[@]}" -arch arm64 "$install_source/install_launcher.c" \
    -o "$RUNTIME/install/install-launcher"
"${compile[@]}" -arch arm64 -Wall -Wextra -Werror \
    "$install_source/roothide_runtime_processes.c" -o "$RUNTIME/install/runtime-processes"
"${compile[@]}" -arch arm64 -Wall -Wextra -Werror "$install_source/roothide_legacy_storage.c" -o "$RUNTIME/install/legacy-storage"
"${compile[@]}" -arch arm64 -fblocks -framework Foundation -framework Metal \
    -framework UIKit -Wl,-export_dynamic "$host/NSViewShim.m" \
    "$install_source/install_macos.m" -o "$RUNTIME/install/install-macos"
cp "$install_source/start-install.sh" "$RUNTIME/install/start-install.sh"
sed -i '' 's/^VZ_INSTALL_ROOTHIDE=0$/VZ_INSTALL_ROOTHIDE=1/' "$RUNTIME/install/start-install.sh"
"${compile[@]}" -arch arm64e -dynamiclib -framework Foundation \
    -Wl,-reexport_framework,Metal -install_name '@rpath/MetalCompat.dylib' \
    "$host/native_bc_texture_support.m" "$host/metalshim.m" \
    -o "$RUNTIME/payload/Frameworks/MetalCompat.dylib"
"${compile[@]}" -arch arm64e -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework AVFAudio -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices -install_name '@rpath/LaunchServicesCompat.dylib' \
    "$host/lsshim.m" "$host/vmmhook.m" "$host/pvg_trace.m" \
    -o "$RUNTIME/payload/Frameworks/LaunchServicesCompat.dylib"
"${compile[@]}" -arch arm64e -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework CoreFoundation -framework IOKit \
    -Wl,-reexport_library,"$host/DiskArbitration-iOS.tbd" \
    -install_name '@rpath/InstallationCompat.dylib' \
    "$host/installationhook.m" "$host/installation_usb_shim.m" \
    -o "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib"
cp "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados16"
"${compile[@]}" -arch arm64e -dynamiclib -fblocks -Wl,-undefined,dynamic_lookup \
    -framework CoreFoundation -framework IOKit -install_name '@rpath/InstallationCompat.dylib' \
    "$host/installationhook.m" "$host/installation_usb_shim.m" \
    "$host/diskarbitration15_compat.c" \
    -o "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados15"
"${compile[@]}" -arch arm64e -dynamiclib -fblocks -framework Foundation \
    -Wl,-undefined,dynamic_lookup \
    -install_name '@loader_path/.jbroot/usr/lib/TweakInject/VZKeyboardPassthrough.dylib' \
    "$VZ_REPO_ROOT/vz/tweak/VZKeyboardPassthrough.m" \
    -o "$STAGE/usr/lib/TweakInject/VZKeyboardPassthrough.dylib"
"${compile[@]}" -arch arm64 -arch arm64e -dynamiclib -fblocks -Wall -Wextra -Werror \
    -lutil \
    -install_name '@loader_path/.jbroot/usr/lib/VirtualMacPaths.dylib' \
    "$host/roothide_paths.c" -o "$STAGE/usr/lib/VirtualMacPaths.dylib"
for helper in \
    "$STAGE/usr/libexec/InternetSharing" "$STAGE/usr/libexec/bootpd" \
    "$STAGE/usr/libexec/InternetSharing.ipados15" "$STAGE/usr/libexec/InternetSharing.ipados16" \
    "$STAGE/usr/sbin/rtadvd" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados15" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados15-auth" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados16" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15-auth" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados16"; do
    python3 "$VZ_REPO_ROOT/vz/patches/add_macho_dylib.py" "$helper" \
        '@loader_path/.jbroot/usr/lib/VirtualMacPaths.dylib'
done

# These are bootstrap paths; RootHide launchctl resolves the current jbroot.
python3 - "$STAGE" "$VZ_REPO_ROOT" "$OUT" "$DEVELOPMENT" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

stage, source, out = map(pathlib.Path, sys.argv[1:4])
for file in (stage / 'Library/LaunchDaemons').glob('*.plist'):
    value = plistlib.loads(file.read_bytes())
    for key in ('Program', 'ProgramArguments', 'StandardOutPath', 'StandardErrorPath'):
        if key not in value:
            continue
        def translate(path):
            if path.startswith('/var/jb/'):
                return path.removeprefix('/var/jb')
            if path.startswith('/tmp/'):
                return '/var/mobile/Library/VirtualMac/Network/' + path.removeprefix('/tmp/')
            return path
        value[key] = [translate(v) for v in value[key]] if isinstance(value[key], list) else translate(value[key])
    file.write_bytes(plistlib.dumps(value))

host_entitlements = plistlib.loads((source / 'vz/host/VirtualMac.entitlements').read_bytes())
required = ('com.apple.private.security.storage.AppBundles',
            'com.apple.private.security.storage.AppDataContainers')
for key in required:
    host_entitlements[key] = True
entitlements = out / 'host.entitlements.plist'
entitlements.write_bytes(plistlib.dumps(host_entitlements))
for relative in ('Applications/VirtualMac.app/VirtualMac',
                 'Applications/VirtualMac.app/VZHostCompat.dylib',
                 'usr/bin/virtualmac-diagnostics',
                 'usr/libexec/VirtualMac/install/install-launcher',
                 'usr/libexec/VirtualMac/install/runtime-processes',
                 'usr/libexec/VirtualMac/install/legacy-storage',
                 'usr/libexec/VirtualMac/install/install-macos',
                 'usr/libexec/VirtualMac/install/VZHostCompat.dylib'):
    subprocess.run(['ldid', '-S' + str(entitlements), str(stage / relative)], check=True)
for relative in ('usr/libexec/VirtualMac/payload/Frameworks/MetalCompat.dylib',
                 'usr/libexec/VirtualMac/payload/Frameworks/LaunchServicesCompat.dylib',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados15',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados16',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15-auth',
                 'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados16',
                 'usr/lib/TweakInject/VZKeyboardPassthrough.dylib',
                 'usr/lib/VirtualMacPaths.dylib'):
    subprocess.run(['ldid', '-S', str(stage / relative)], check=True)

# RootHide needs storage access on every executable, including the extracted
# VMM, Installation, usbmuxd and network helpers; retain their other keys.
for file in stage.rglob('*'):
    if not file.is_file() or file.is_symlink():
        continue
    with file.open('rb') as stream:
        header = stream.read(32)
    if header[:4] != b'\xcf\xfa\xed\xfe' or int.from_bytes(header[12:16], 'little') != 2:
        continue
    raw = subprocess.check_output(['ldid', '-e', str(file)])
    value = plistlib.loads(raw) if raw.strip() else {}
    for key in required:
        value[key] = True
    entitlements_file = out / 'current.entitlements.plist'
    entitlements_file.write_bytes(plistlib.dumps(value))
    subprocess.run(['ldid', '-S' + str(entitlements_file), str(file)], check=True)
    file.chmod(0o755)

info = stage / 'Applications/VirtualMac.app/Info.plist'
value = plistlib.loads(info.read_bytes())
value['CFBundleShortVersionString'] = '1.2.3-roothide' + ('-dev' if sys.argv[4] == '1' else '')
info.write_bytes(plistlib.dumps(value))
PY
# Setuid belongs on the target after postinst verifies the root owner. The
# build machine only needs a regular executable in the package stage.
chmod 755 "$RUNTIME/install/install-launcher"
for control in control preinst postinst prerm; do
    cp "$VZ_REPO_ROOT/packaging/roothide/$control" "$STAGE/DEBIAN/$control"
done
python3 - "$VZ_REPO_ROOT/packaging/roothide" "$STAGE/DEBIAN" <<'PY'
import pathlib
import sys
source, destination = map(pathlib.Path, sys.argv[1:])
stop = (source / 'stop-runtime.sh').read_text()
for name in ('preinst', 'prerm'):
    script = destination / name
    lines = script.read_text().splitlines(keepends=True)
    script.write_text(''.join(stop if line.startswith('. ') else line for line in lines))
PY
base_version=$(sed -n 's/^Version: //p' "$STAGE/DEBIAN/control")
version="${VZ_PACKAGE_VERSION:-$base_version.$(git -C "$VZ_REPO_ROOT" rev-list --count HEAD).$(git -C "$VZ_REPO_ROOT" rev-parse --short=10 HEAD)}"
sed -i '' "s/^Version:.*/Version: $version/" "$STAGE/DEBIAN/control"
printf 'Installed-Size: %s\n' "$(du -sk "$STAGE" | awk '{print $1}')" >> "$STAGE/DEBIAN/control"
printf 'source=%s\nsource-commit=%s\ndevelopment=%s\n' "$SOURCE_TAG" "$(git -C "$VZ_REPO_ROOT" rev-parse HEAD)" "$DEVELOPMENT" > "$RUNTIME/build-source.txt"
# Replace the base deb's checked-in localization files with the ones
# from the source tree so new and updated UI strings ship in the package.
ditto "$VZ_REPO_ROOT/resources/Localizations" "$APP/../Localizations-staging"
for locale_dir in "$APP/../Localizations-staging"/*.lproj; do
    name=$(basename "$locale_dir")
    ditto "$locale_dir/Localizable.strings" "$APP/$name/Localizable.strings"
    ditto "$locale_dir/InfoPlist.strings" "$APP/$name/InfoPlist.strings"
done
rm -rf "$APP/../Localizations-staging"
chmod 755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
python3 "$SCRIPT_DIR/audit-entitlements.py" "$OUT/host.entitlements.plist" "$APP/VirtualMac"
python3 "$SCRIPT_DIR/audit-roothide-package-stage.py" "$STAGE"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/VirtualMac_roothide.deb"
echo "roothide package: $OUT/VirtualMac_roothide.deb"
