#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/standard-launcher"
mkdir -p "$OUT"
BASE=${1:-1.2.3}
git -C "$VZ_REPO_ROOT" show "$BASE:VirtualMac/vz/install/install_launcher.c" > "$OUT/original.c"
xcrun --sdk macosx clang -Wall -Wextra -Werror -c \
    "$VZ_REPO_ROOT/tests/fixtures/launcher-syscalls.c" -o "$OUT/syscalls.o"
compile=(xcrun --sdk macosx clang -Wall -Wextra -Werror)
for call in open stat access setgid setuid kill usleep dup2 close setenv execl; do
    compile+=("-D$call=test_$call")
done
"${compile[@]}" "$OUT/original.c" "$OUT/syscalls.o" -o "$OUT/original"
"${compile[@]}" "$VZ_REPO_ROOT/vz/install/install_launcher.c" \
    "$OUT/syscalls.o" -o "$OUT/current"
python3 "$VZ_REPO_ROOT/tests/test-standard-launcher.py" "$OUT"
