#!/usr/bin/env bash
# Install OpenROAD (Precision Innovations package of The OpenROAD Project,
# Ubuntu 22.04) and fetch the Nangate45 platform of OpenROAD-flow-scripts.
set -euo pipefail
mkdir -p /root/work/pnr && cd /root/work/pnr
deb=openroad_2.0-17598-ga008522d8_amd64-ubuntu-22.04.deb
if ! command -v openroad >/dev/null; then
  [ -f $deb ] || curl -sSL -o $deb \
    https://github.com/Precision-Innovations/OpenROAD/releases/download/2024-12-14/$deb
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ./$deb
fi
openroad -version
if [ ! -d orfs/flow/platforms/nangate45 ]; then
  rm -rf orfs
  git clone -q --depth 1 --filter=blob:none --sparse \
    https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git orfs
  (cd orfs && git sparse-checkout set flow/platforms/nangate45)
fi
ls orfs/flow/platforms/nangate45 orfs/flow/platforms/nangate45/lef | head -60
echo INSTALL_DONE
