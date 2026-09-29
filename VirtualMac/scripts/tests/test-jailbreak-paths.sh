#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/test-jailbreak-paths"
mkdir -p "$(dirname "$OUT")"
xcrun --sdk macosx clang -Wall -Wextra -Werror \
    "$VZ_REPO_ROOT/tests/test-jailbreak-paths.c" -o "$OUT"
"$OUT"
sh -n "$VZ_REPO_ROOT/vz/install/start-install.sh"
# The shared installer must stay on its original mode unless the RootHide
# package builder explicitly stamps the copy it ships.
grep -Fxq 'VZ_INSTALL_ROOTHIDE=0' "$VZ_REPO_ROOT/vz/install/start-install.sh"
for script in preinst postinst prerm stop-runtime.sh; do
    sh -n "$VZ_REPO_ROOT/packaging/roothide/$script"
done
