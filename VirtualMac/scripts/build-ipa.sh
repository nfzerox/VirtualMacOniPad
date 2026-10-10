#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

need_command zip
need_command xcrun
need_command codesign

APP_PATH="${1:-$VZ_BUILD_ROOT/ios-app/VirtualMac.app}"
OUT_DIR="${VZ_IPA_OUTPUT_DIR:-$VZ_BUILD_ROOT/ipa}"
APP_NAME="${VZ_IPA_APP_NAME:-VirtualMac}"
APP_ID="${VZ_IPA_APP_ID:-com.mac.virtual}"
SIGN_IDENTITY="${VZ_IPA_SIGN_IDENTITY:-${VZ_CODESIGN_IDENTITY:-}}"

[[ -d "$APP_PATH" ]] || die "app bundle not found: $APP_PATH"
mkdir -p "$OUT_DIR"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

payload_dir="$workdir/Payload"
mkdir -p "$payload_dir"
cp -R "$APP_PATH" "$payload_dir/$APP_NAME.app"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "signing $payload_dir/$APP_NAME.app with $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements \
        "$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements" \
        "$payload_dir/$APP_NAME.app"
else
    echo "note: no signing identity set; generating an unsigned IPA archive"
fi

ipa_path="$OUT_DIR/${APP_NAME}.ipa"
(
    cd "$workdir"
    zip -qr "$ipa_path" Payload
)

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "signed IPA created: $ipa_path"
else
    echo "unsigned IPA archive created: $ipa_path"
fi

echo "note: enable JIT in StickDebug before launching the app on-device."
