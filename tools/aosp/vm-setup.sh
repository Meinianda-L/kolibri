#!/bin/bash
# One-time setup of the Lima build VM (Ubuntu 24.04 arm64): x86_64 libraries for AOSP's host
# prebuilts (run by Rosetta), build dependencies, swap.   sudo bash vm-setup.sh
set -eux
dpkg --add-architecture amd64
# arm64 packages come from ports.ubuntu.com, amd64 ones from archive.ubuntu.com.
sed -i '/^Architectures:/d; s/^Types: deb$/Types: deb\nArchitectures: arm64/' /etc/apt/sources.list.d/ubuntu.sources
cat > /etc/apt/sources.list.d/amd64.sources <<'SRC'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
apt-get update
apt-get install -y git curl python3 python-is-python3 zip unzip rsync bc build-essential flex bison \
    libssl-dev zstd xz-utils fontconfig \
    libc6:amd64 libstdc++6:amd64 zlib1g:amd64 libgcc-s1:amd64 libncurses6:amd64 libtinfo6:amd64
# AOSP 12 prebuilts still want the ncurses 5 ABI (gone from 24.04): take it from 22.04.
tmp=$(mktemp -d)
for p in ncurses/libtinfo5_6.3-2ubuntu0.3_amd64.deb ncurses/libncurses5_6.3-2ubuntu0.3_amd64.deb; do
    curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/universe/n/$p" -o "$tmp/$(basename $p)"
done
dpkg -i "$tmp"/*.deb
rm -rf "$tmp"
if [ ! -f /swapfile ]; then fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile; fi
swapon /swapfile 2>/dev/null || true
grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo "vm-setup done"
