#!/usr/bin/env bash
# Build a recent Yosys from source (Ubuntu 22.04 ships 0.9, which does not
# fold constant functions in generate-loop port connections).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
pkill -x yosys || true
apt-get install -y -qq build-essential clang bison flex libreadline-dev gawk tcl-dev \
  libffi-dev git graphviz pkg-config python3 libboost-system-dev \
  libboost-python-dev libboost-filesystem-dev zlib1g-dev >/tmp/apt_yosys.log 2>&1
mkdir -p /root/src && cd /root/src
if [ ! -d yosys ]; then
  git clone --depth 1 --branch yosys-0.44 --recurse-submodules https://github.com/YosysHQ/yosys.git
fi
cd yosys
make config-gcc >/dev/null
make -j 24 >/root/src/yosys_build.log 2>&1
make install PREFIX=/opt/yosys >/dev/null
/opt/yosys/bin/yosys -V
