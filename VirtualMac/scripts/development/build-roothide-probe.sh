#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
need_command xcrun
need_command ldid
need_command dpkg-deb
need_command python3
"$SCRIPT_DIR/prepare-roothide-sdk.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
ROOTHIDE_SDK="${VZ_ROOTHIDE_SDK:-$VZ_BUILD_ROOT/toolchain/roothide-sdk/devkit}"
SOURCE="$VZ_REPO_ROOT/vz/development/probes/roothide"
OUT="$VZ_BUILD_ROOT/roothide-probe"
STAGE="$(mktemp -d -t VirtualMacProbe.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
PAYLOAD="$STAGE/usr/libexec/VirtualMacProbe"
mkdir -p "$PAYLOAD" "$STAGE/DEBIAN" "$OUT"
chmod 755 "$STAGE"

compile=(xcrun --sdk iphoneos clang -miphoneos-version-min=15.0
    -isysroot "$SDK" -I"$ROOTHIDE_SDK" -L"$ROOTHIDE_SDK/roothide"
    -Wall -Wextra -Werror)
"${compile[@]}" -arch arm64 "$SOURCE/probe.c" -lroothide \
    -o "$PAYLOAD/virtualmac-roothide-probe"
"${compile[@]}" -arch arm64e "$SOURCE/probe.c" -lroothide \
    -o "$PAYLOAD/virtualmac-roothide-probe.arm64e"
"${compile[@]}" -arch arm64 -arch arm64e -dynamiclib \
    -install_name '@loader_path/ProbeLibrary.dylib' \
    "$SOURCE/probe-library.c" -lroothide -o "$PAYLOAD/ProbeLibrary.dylib"
"${compile[@]}" -arch arm64 "$SOURCE/root-helper.c" -o "$PAYLOAD/root-helper"
for binary in "$PAYLOAD/virtualmac-roothide-probe" \
    "$PAYLOAD/virtualmac-roothide-probe.arm64e" "$PAYLOAD/root-helper"; do
    ldid -S"$SOURCE/entitlements.plist" "$binary"
    python3 "$VZ_REPO_ROOT/scripts/audit-entitlements.py" \
        "$SOURCE/entitlements.plist" "$binary"
done
ldid -S "$PAYLOAD/ProbeLibrary.dylib"
python3 "$VZ_REPO_ROOT/scripts/audit-entitlements.py" - "$PAYLOAD/ProbeLibrary.dylib"
chmod 4755 "$PAYLOAD/root-helper"

cat > "$STAGE/DEBIAN/control" <<'CONTROL'
Package: com.mac.virtual.roothide-probe
Name: Virtual Mac RootHide Probe
Version: 0.1
Architecture: iphoneos-arm64e
Maintainer: Virtual Mac
Section: Development
Depends: firmware (>= 15.0), firmware (<< 16.4), roothide, dopamine-basebin-link
Description: Diagnose Virtual Mac path, loading, and process requirements on RootHide.
CONTROL
cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -eu
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
probe=/usr/libexec/VirtualMacProbe
# Bootstrap tools take virtual paths; native jbctl takes a physical Mach-O path.
for binary in "$probe/"*; do
    /basebin/jbctl trustcache add "$(jbroot "$binary")"
done
chown root:wheel "$probe/root-helper"
chmod 4755 "$probe/root-helper"
POSTINST
chmod 755 "$STAGE/DEBIAN/postinst"
for binary in "$PAYLOAD/virtualmac-roothide-probe" \
    "$PAYLOAD/virtualmac-roothide-probe.arm64e" "$PAYLOAD/ProbeLibrary.dylib"; do
    otool -L "$binary" | grep -Fq '@loader_path/.jbroot/usr/lib/libroothide.dylib' ||
        die "probe must link the native roothide library: $binary"
done
DEB="$OUT/VirtualMac-roothide-probe_0.1_iphoneos-arm64e.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB"
dpkg-deb --info "$DEB"
echo "roothide diagnostic package: $DEB"
