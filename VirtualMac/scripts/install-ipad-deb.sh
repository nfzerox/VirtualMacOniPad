#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command scp
need_command sshpass
need_command dpkg-deb
ensure_ipad_usb

if [[ -n "${VZ_IPAD_DEB:-}" ]]; then
    DEB="$VZ_IPAD_DEB"
else
    DEB="$(find "$VZ_BUILD_ROOT/release" -maxdepth 1 -type f \
        -name 'VirtualMac_*.deb' \
        -print0 | xargs -0 ls -1t 2>/dev/null | head -1)"
fi
[[ -n "$DEB" && -f "$DEB" ]] ||
    die "standalone package not found; run scripts/build-ipad-deb.sh first"

# The roothide package is rootless by construction: its usr/libexec helpers
# resolve inside the Dopamine-roothide bootstrap instead of Apple's real system
# paths, and it keeps state in private storage rather than /var/root/VirtualMac.
# Its dependency list identifies it, so the standard package's rootful-path
# safety checks are skipped for it below.
depends="$(dpkg-deb -f "$DEB" Depends | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
roothide=0
if printf '%s\n' "$depends" | grep -qx roothide; then
    roothide=1
fi

# Refuse an unsafe development package before it reaches a rootful jailbreak.
# Apple system files are outside Virtual Mac's ownership; all Taurine helpers
# must live below /var/root/VirtualMac/rootful.
if [[ "$roothide" == 0 ]]; then
    archive_paths="$(dpkg-deb --fsys-tarfile "$DEB" | tar -tf -)"
    for forbidden in \
        ./usr/libexec/bootpd \
        ./usr/libexec/InternetSharing \
        ./Library/LaunchDaemons/com.apple.bootpd.plist; do
        if printf '%s\n' "$archive_paths" | grep -Fxq "$forbidden"; then
            die "refusing package that replaces an Apple system path: $forbidden"
        fi
    done
fi

rootless="$(ipad_ssh 'test -x /var/jb/usr/bin/jbctl && echo 1 || echo 0')"
system_bootpd_before="$(ipad_ssh 'sha256sum /usr/libexec/bootpd | cut -d" " -f1')"

REMOTE_DEB="/tmp/$(basename "$DEB")"
echo "copying standalone package to iPad: $DEB"
sshpass -p "$VZ_IPAD_PASSWORD" scp \
    "${IPAD_SCP_ARGS[@]}" "$DEB" "$IPAD_TARGET:$REMOTE_DEB"

# Package preinst owns VM termination.  Do not invoke the UI stop action here:
# it asks macOS to shut down and can leave an unattended guest confirmation
# sheet in front of the install.
set +e
install_output="$(ipad_ssh "dpkg -i '$REMOTE_DEB' 2>&1" 2>&1)"
install_status=$?
set -e
printf '%s\n' "$install_output"
((install_status == 0)) || die "dpkg installation failed"

# Maintainer scripts never respring. Sileo consumes finish:restart and offers
# the user its Restart SpringBoard button; direct dpkg installs remain online.
status="$(ipad_ssh "dpkg-query -W -f='\${db:Status-Status}' \
    com.mac.virtual 2>/dev/null || true")"
[[ "$status" == installed ]] ||
    die "package did not reach installed state (status: ${status:-missing})"

if [[ "$roothide" == 0 ]]; then
    ipad_ssh "
set -eu
test -u /var/root/VirtualMac/install/install-launcher
test -d /var/mobile/Media/VirtualMac
"
fi

if [[ "$roothide" == 1 ]]; then
    ipad_ssh "
set -eu
test -x /var/jb/Applications/VirtualMac.app/VirtualMac
test -f /var/jb/usr/lib/VirtualMacPaths.dylib
test -f /var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.dylib
test -x /var/jb/usr/libexec/VirtualMac/install/install-launcher
"
elif [[ "$rootless" == 1 ]]; then
    ipad_ssh "
set -eu
test -x /var/jb/Applications/VirtualMac.app/VirtualMac
test -f /var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.dylib
test -f /var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.plist
if test -L /var/jb/Library/MobileSubstrate/DynamicLibraries; then
    test -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.dylib
fi
launchctl print user/501/vzi.apple.bootpd >/dev/null
launchctl print user/501/com.apple.NetworkSharing >/dev/null
/var/jb/usr/bin/uicache -l | grep -F 'com.mac.virtual' >/dev/null
"
else
    ipad_ssh "
set -eu
test -x /Applications/VirtualMac.app/VirtualMac
test -x /usr/libexec/VirtualMac/bootpd
test -f /usr/lib/TweakInject/VZKeyboardPassthrough.dylib
# iPadOS 14 DHCP is deliberately absent until InternetSharing has produced
# its config; an install-time socket job is a launchd retry-loop hazard.
test -f /var/root/VirtualMac/rootful/Library/LaunchDaemons/com.apple.bootpd.plist
! launchctl print system/vzi.apple.bootpd >/dev/null 2>&1
launchctl print system/com.apple.NetworkSharing >/dev/null
"
fi

system_bootpd_after="$(ipad_ssh 'sha256sum /usr/libexec/bootpd | cut -d" " -f1')"
[[ "$system_bootpd_after" == "$system_bootpd_before" ]] ||
    die "Apple /usr/libexec/bootpd changed during package installation"
ipad_ssh "rm -f '$REMOTE_DEB'"

echo "standalone package installed and registered on iPad"
