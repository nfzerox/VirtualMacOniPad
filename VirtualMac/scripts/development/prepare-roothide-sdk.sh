#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

SDK="${VZ_ROOTHIDE_SDK:-$VZ_BUILD_ROOT/toolchain/roothide-sdk/devkit}"
ARCHIVE="$VZ_BUILD_ROOT/downloads/roothide-devkit.zip"
SHA256=295ce6b7e411aad38738c2965789eb10c7ed244567b9b86b539e226fa6a3dac5
URL=https://github.com/RootHide/libroothide/files/12643716/devkit.zip

if [[ -n "${VZ_ROOTHIDE_SDK:-}" ]]; then
    need_file "$SDK/roothide.h"
    need_file "$SDK/roothide/libroothide.tbd"
    echo "using configured roothide SDK: $SDK"
    exit 0
fi
need_command curl
need_command unzip
need_command shasum
mkdir -p "$(dirname "$ARCHIVE")" "$(dirname "$SDK")"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 2 --output "$ARCHIVE.part" "$URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$actual" == "$SHA256" ]] || die "roothide SDK archive checksum mismatch"
unzip -oq "$ARCHIVE" -d "$(dirname "$SDK")"
need_file "$SDK/roothide.h"
need_file "$SDK/roothide/libroothide.tbd"
echo "verified roothide SDK: $SDK"
