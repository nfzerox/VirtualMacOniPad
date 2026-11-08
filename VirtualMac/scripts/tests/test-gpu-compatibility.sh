#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/gpu-compatibility"
mkdir -p "$OUT"
SOURCES=("$VZ_REPO_ROOT/tests/test-gpu-compatibility.m")
for source in VZGPUCompatibility VZGPUCompatibilityBootstrap;do
 if [[ -f "$VZ_REPO_ROOT/vz/host/$source.m" ]];then SOURCES+=("$VZ_REPO_ROOT/vz/host/$source.m");fi
done
xcrun --sdk macosx clang -fblocks -Wall -Wextra -Werror -Wl,-export_dynamic -framework Foundation -framework Metal \
 "${SOURCES[@]}" -o "$OUT/lifecycle"
env VMM_GPU_COMPATIBILITY_ENABLED=1 "$OUT/lifecycle"
