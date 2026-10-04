#!/usr/bin/env bash
# Install the build dependencies for AVM (AV2 reference software) inside WSL Ubuntu.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Wait for any apt/dpkg process started at WSL boot (e.g. apt-daily) to finish.
for i in $(seq 1 120); do
  if ! pgrep -x apt-get >/dev/null && ! pgrep -x dpkg >/dev/null && ! pgrep -f unattended-upgr >/dev/null; then
    break
  fi
  sleep 5
done

apt-get update -qq
apt-get install -y -qq cmake ninja-build nasm yasm linux-tools-generic >/dev/null || \
  apt-get install -y -qq cmake ninja-build nasm yasm >/dev/null

cmake --version | head -1
echo "ninja $(ninja --version)"
nasm -v
