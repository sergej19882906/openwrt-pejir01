#!/bin/bash
# ============================================================
# OpenWrt 25.12.6 for Perenio Elegance PEJIR01 — build script
# Usage: ./build.sh          (run on Debian/Ubuntu x86_64, ~30GB free)
# ============================================================
set -e

OPENWRT_VER="v25.12.6"
WORKDIR="${WORKDIR:-$HOME/openwrt-pejir01-build}"
JOBS="$(nproc)"
STOCK_FW_URL="https://router-pejir-openwrt-firmware.s3.eu-central-1.amazonaws.com/ci/1487/pejir-9.0.4-po-jenkins-pejir-openwrt-1487-ramips-mt7621-pejir01-34-BA-squashfs-upgrade.swu"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> 1. Build dependencies (Debian/Ubuntu)"
if command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y build-essential flex bison gawk gettext git \
    libncurses-dev libssl-dev python3-dev python3-setuptools python3-pip \
    python3-ply rsync swig unzip zip zlib1g-dev file wget curl bc cpio \
    xsltproc libelf-dev ccache python3-yaml squashfs-tools
fi

echo "==> 2. OpenWrt $OPENWRT_VER"
mkdir -p "$WORKDIR" && cd "$WORKDIR"
[ -d openwrt ] || git clone --depth 1 --branch "$OPENWRT_VER" \
  https://github.com/openwrt/openwrt.git openwrt
cd openwrt

echo "==> 3. Apply PEJIR01 patch series"
git am --3way "$REPO_DIR"/patches/*.patch \
  || { echo "git am failed — apply manually: git am patches/*.patch"; exit 1; }

echo "==> 4. Vendor binaries from stock 9.0.4 (Perenio public S3)"
MCU_DIR="package/perenio-mcu/files"
mkdir -p "$MCU_DIR"
if [ ! -f "$MCU_DIR/mcu" ]; then
  curl -L -o /tmp/pejir-9.0.4.swu "$STOCK_FW_URL"
  rm -rf /tmp/pejir-stock && mkdir /tmp/pejir-stock && cd /tmp/pejir-stock
  cpio -idm --no-absolute-filenames < /tmp/pejir-9.0.4.swu
  unsquashfs -q -d vendor-root root.squashfs
  cp vendor-root/usr/bin/mcu vendor-root/usr/bin/mcud \
     vendor-root/usr/bin/stm32flash "$WORKDIR/openwrt/$MCU_DIR/"
  cd "$WORKDIR/openwrt"
else
  echo "    vendor binaries already present, skip"
fi

echo "==> 5. Feeds + config"
cp feeds.conf.default feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

cat > .config <<'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_perenio_pejir01-34-BA=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_uartmuxd=y
CONFIG_PACKAGE_perenio-mcu=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-storage-uas=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_coreutils-stty=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-serial-option=y
CONFIG_PACKAGE_lxc=y
CONFIG_PACKAGE_lxc-auto=y
CONFIG_PACKAGE_lxc-attach=y
CONFIG_PACKAGE_lxc-create=y
CONFIG_PACKAGE_lxc-templates=y
CONFIG_PACKAGE_lxc-hooks=y
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_pejir-lxc-base=y
CONFIG_PACKAGE_pejir-homed-feed=y
CONFIG_PACKAGE_mosquitto-nossl=y
CONFIG_PACKAGE_mosquitto-client-nossl=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_kmod-amneziawg=y
CONFIG_PACKAGE_amneziawg-tools=y
CONFIG_PACKAGE_luci-proto-amneziawg=y
CONFIG_PACKAGE_dropbear=y
EOF
make defconfig

echo "==> 6. Download sources"
export FORCE_UNSAFE_CONFIGURE=1
make download -j"$JOBS"

echo "==> 7. Build (this takes hours)"
make -j"$JOBS" || make -j1 V=s

echo ""
echo "============================================================"
echo " DONE. Images:"
ls -la bin/targets/ramips/mt7621/*.bin
echo "============================================================"
