#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/legacy-storage"
mkdir -p "$OUT"
xcrun --sdk macosx clang -Wall -Wextra -Werror -DVZ_ROOTHIDE -Dgeteuid=test_geteuid \
    -I"$VZ_REPO_ROOT/tests/fixtures" "$VZ_REPO_ROOT/vz/install/roothide_legacy_storage.c" \
    "$VZ_REPO_ROOT/tests/fixtures/legacy-storage.c" -o "$OUT/legacy-storage"
python3 "$VZ_REPO_ROOT/tests/test-roothide-legacy-storage.py" "$OUT/legacy-storage"
