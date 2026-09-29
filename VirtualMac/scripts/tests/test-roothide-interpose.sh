#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
[[ $# == 0 || ( $# == 1 && "$1" == --files-only ) ]] ||
    die "usage: test-roothide-interpose.sh [--files-only]"
OUT="$VZ_BUILD_ROOT/tests/roothide-interpose"
mkdir -p "$OUT"
xcrun --sdk macosx clang -DVZ_ROOTHIDE -I"$VZ_REPO_ROOT/tests/fixtures" \
    -Wall -Wextra -Werror -dynamiclib -fblocks -lutil \
    "$VZ_REPO_ROOT/vz/host/roothide_paths.c" \
    "$VZ_REPO_ROOT/tests/fixtures/roothide-paths.c" \
    -o "$OUT/VirtualMacPaths.dylib"
xcrun --sdk macosx clang -Wall -Wextra -Werror -fblocks \
    "$VZ_REPO_ROOT/tests/test-roothide-interpose.c" \
    "$OUT/VirtualMacPaths.dylib" -o "$OUT/test-roothide-interpose"
VZ_TEST_ROOT=$(mktemp -d /private/tmp/virtualmac-paths.XXXXXX)
export VZ_TEST_ROOT
trap 'rm -rf "$VZ_TEST_ROOT"' EXIT
mkdir -p "$VZ_TEST_ROOT/var/mobile/Library/VirtualMac/Root/Pairing" \
    "$VZ_TEST_ROOT/var/mobile/Library/VirtualMac/Network" \
    "$VZ_TEST_ROOT/var/run/vm"
"$OUT/test-roothide-interpose" "$@"
