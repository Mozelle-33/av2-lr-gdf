#!/usr/bin/env bash
# Configure and build AVM (AV2 reference software) inside WSL.
# Usage: build_avm.sh <build-name> [extra cmake args...]
#   The source tree is G:\AV2\avm; the build tree lives on the WSL native
#   filesystem (/root/build/<build-name>) for speed.
set -euo pipefail
SRC=/mnt/g/AV2/avm
NAME=${1:-avm-rel}
shift || true
BUILD=/root/build/$NAME
mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_TESTS=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=1 \
  -DENABLE_NASM=1 "$@" >"$BUILD/configure.log" 2>&1 || { tail -30 "$BUILD/configure.log"; exit 1; }
ninja -C "$BUILD" ${NINJA_JOBS:+-j "$NINJA_JOBS"} >"$BUILD/build.log" 2>&1 || { tail -40 "$BUILD/build.log"; exit 1; }
ls -la "$BUILD"/avmenc "$BUILD"/avmdec 2>/dev/null || ls "$BUILD"
