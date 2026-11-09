#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/native-touch"
mkdir -p "$OUT"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    "$VZ_REPO_ROOT/tests/test-native-touch-core.c" -o "$OUT/core"
"$OUT/core"
for component in identity contacts; do
    if [[ "$component" == identity ]]; then source_name=Identity; else source_name=Contacts; fi
    xcrun --sdk macosx clang -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
        -framework Foundation "$VZ_REPO_ROOT/tests/test-native-touch-$component.m" \
        "$VZ_REPO_ROOT/vz/host/VZNativeTouch$source_name.m" -o "$OUT/$component"
    "$OUT/$component"
done
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=14.5 \
    -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -fsyntax-only \
    "$VZ_REPO_ROOT/vz/host/VZNativeTouchInput.m" \
    "$VZ_REPO_ROOT/vz/host/VZNativeTouchContacts.m" \
    "$VZ_REPO_ROOT/vz/host/VZNativeTouchIdentity.m"
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=14.5 \
    -fblocks -Wall -Wextra -Werror -fsyntax-only "$VZ_REPO_ROOT/vz/host/VZNativeTouchBackend.m"
echo 'native-touch tests and iOS module compilation passed'

xcrun --sdk macosx clang -Wall -Wextra -Werror \
    "$VZ_REPO_ROOT/tests/test-native-touch-images.c" -o "$OUT/images"
"$OUT/images"
