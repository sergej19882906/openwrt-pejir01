#!/bin/bash
# ============================================================
# OpenWrt 25.12.6 for Perenio Elegance PEJIR01 — build script
# Usage: ./build.sh          (run on Debian/Ubuntu x86_64, ~30GB free)
#
# Переменные окружения:
#   STOCK_FW   — путь к заводской прошивке Perenio 9.0.4 (.swu).
#                Если не задана, скрипт ищет ./pejir-9.0.4.swu, потом
#                пробует публичный S3 Perenio, потом ассет релиза.
#   WORKDIR    — каталог для дерева сборки (по умолчанию ~/openwrt-pejir01-build)
# ============================================================
set -e

OPENWRT_VER="v25.12.6"
WORKDIR="${WORKDIR:-$HOME/openwrt-pejir01-build}"
JOBS="$(nproc)"
STOCK_FW_URL="https://router-pejir-openwrt-firmware.s3.eu-central-1.amazonaws.com/ci/1487/pejir-9.0.4-po-jenkins-pejir-openwrt-1487-ramips-mt7621-pejir01-34-BA-squashfs-upgrade.swu"
STOCK_SHA256="842f10d78d9d5d28063d72331bbf9b35d1983c713bebe24d9cabfb98a47c0c67"
BLOBS_URL="https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/pejir-vendor-blobs-9.0.4.zip"
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
# Серия применяется целиком, поэтому проверяем не HEAD, а историю:
# патч 0001 — это и есть маркер серии.
if git log --oneline | grep -q "Perenio Elegance PEJIR01"; then
  echo "    series already applied, skip"
else
  git am --3way "$REPO_DIR"/patches/*.patch \
    || { echo "git am failed — apply manually: git am patches/*.patch"; exit 1; }
fi

echo "==> 4. Vendor binaries from stock 9.0.4 (Perenio public S3)"
MCU_DIR="package/perenio-mcu/files"
IDATA_DIR="package/pejir-idata/files"
mkdir -p "$MCU_DIR" "$IDATA_DIR"
if [ ! -f "$MCU_DIR/mcu" ]; then
  SW="/tmp/pejir-9.0.4.swu"

  # 4a. локальная заводская прошивка: STOCK_FW или ./pejir-9.0.4.swu
  if [ -n "${STOCK_FW:-}" ] && [ -f "$STOCK_FW" ]; then
    echo "    using local stock firmware: $STOCK_FW"
    cp "$STOCK_FW" "$SW"
  elif [ -f "./pejir-9.0.4.swu" ]; then
    echo "    using local stock firmware: ./pejir-9.0.4.swu"
    cp "./pejir-9.0.4.swu" "$SW"
  fi

  # 4b. публичный S3 Perenio
  if [ ! -f "$SW" ]; then
    echo "    downloading stock firmware from S3"
    curl -sfL -o "$SW" "$STOCK_FW_URL" || rm -f "$SW"
  fi

  # 4c. ассет релиза с уже распакованными блобами
  ZIP="/tmp/pejir-vendor-blobs.zip"
  if [ ! -f "$SW" ] && [ ! -f "$ZIP" ]; then
    curl -sfL -o "$ZIP" "$BLOBS_URL" || rm -f "$ZIP"
  fi

  if [ -f "$ZIP" ]; then
    echo "    using vendor blobs from release asset"
    rm -rf /tmp/pejir-vendor-blobs-9.0.4
    ( cd /tmp && unzip -q pejir-vendor-blobs.zip )
    cp /tmp/pejir-vendor-blobs-9.0.4/perenio-mcu/* "$WORKDIR/openwrt/$MCU_DIR/"
    cp /tmp/pejir-vendor-blobs-9.0.4/pejir-idata/* "$WORKDIR/openwrt/$IDATA_DIR/"
  elif [ -f "$SW" ]; then
    # сверяем контрольную сумму стоковой прошивки, если она известна
    if command -v sha256sum >/dev/null; then
      got="$(sha256sum "$SW" | cut -d' ' -f1)"
      if [ "$got" != "$STOCK_SHA256" ]; then
        echo "    WARNING: sha256 of stock firmware differs"
        echo "            expected $STOCK_SHA256"
        echo "            got      $got"
        echo "            vendor binaries will be extracted from an unverified image"
      else
        echo "    stock firmware sha256 OK"
      fi
    fi
    rm -rf /tmp/pejir-stock && mkdir -p /tmp/pejir-stock
    ( cd /tmp/pejir-stock && cpio -idm --no-absolute-filenames < "$SW" )
    unsquashfs -q -d /tmp/pejir-stock/vendor-root /tmp/pejir-stock/root.squashfs
    cp /tmp/pejir-stock/vendor-root/usr/bin/mcu \
       /tmp/pejir-stock/vendor-root/usr/bin/mcud \
       /tmp/pejir-stock/vendor-root/usr/bin/stm32flash "$WORKDIR/openwrt/$MCU_DIR/"
    cp /tmp/pejir-stock/vendor-root/usr/sbin/idata_load \
       /tmp/pejir-stock/vendor-root/usr/sbin/idata_flash \
       /tmp/pejir-stock/vendor-root/usr/sbin/idata_getconf \
       /tmp/pejir-stock/vendor-root/usr/sbin/idata_lib.sh "$WORKDIR/openwrt/$IDATA_DIR/"
  else
    cat >&2 <<'EOM'

ERROR: не удалось получить вендорские бинарии (mcu/mcud/stm32flash/idata_*).

Ни один источник не сработал. Сделайте одно из:
  1) положите заводскую прошивку Perenio 9.0.4 рядом с build.sh как
     ./pejir-9.0.4.swu (или укажите путь в переменной STOCK_FW);
  2) опубликуйте ассет pejir-vendor-blobs-9.0.4.zip в Releases этого
     репозитория;
  3) дождитесь, пока Perenio опубликует новую сборку 9.0.4 по S3.

EOM
    exit 1
  fi
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
CONFIG_PACKAGE_mosquitto-nossl=y
CONFIG_PACKAGE_mosquitto-client-nossl=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_kmod-amneziawg=y
CONFIG_PACKAGE_amneziawg-tools=y
CONFIG_PACKAGE_luci-proto-amneziawg=y
CONFIG_PACKAGE_pejir-lte-base=y
CONFIG_PACKAGE_smstools3=y
CONFIG_PACKAGE_pejir-sms=y
CONFIG_PACKAGE_pejir-homed-feed=y
# stock migration: Wi-Fi SSID/keys, country, root password from idata
CONFIG_PACKAGE_pejir-idata=y
# LuCI: battery/power status and SMS pages for PEJIR01
CONFIG_PACKAGE_luci-app-perenio=y
# monitoring / traffic / diagnostics
CONFIG_PACKAGE_mwan3=y
CONFIG_PACKAGE_luci-app-mwan3=y
CONFIG_PACKAGE_sqm-scripts=y
CONFIG_PACKAGE_luci-app-sqm=y
CONFIG_PACKAGE_collectd=y
CONFIG_PACKAGE_luci-app-statistics=y
CONFIG_PACKAGE_nlbwmon=y
CONFIG_PACKAGE_luci-app-nlbwmon=y
CONFIG_PACKAGE_banip=y
CONFIG_PACKAGE_luci-app-banip=y
CONFIG_PACKAGE_vnstat2=y
CONFIG_PACKAGE_luci-app-vnstat2=y
CONFIG_PACKAGE_picocom=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_htop=y
# universal modem stack (replace GM510 with EC25/EP06/GM610/etc.)
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y
CONFIG_PACKAGE_uqmi=y
CONFIG_PACKAGE_kmod-usb-net-cdc-mbim=y
CONFIG_PACKAGE_umbim=y
CONFIG_PACKAGE_kmod-usb-net-rndis=y
CONFIG_PACKAGE_kmod-usb-net-huawei-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-serial-sierrawireless=y
CONFIG_PACKAGE_comgt=y
CONFIG_PACKAGE_usb-modeswitch=y
CONFIG_PACKAGE_atinout=y
CONFIG_PACKAGE_luci-app-atinout=y
CONFIG_PACKAGE_luci-app-modeminfo=y
CONFIG_PACKAGE_pingcontrol=y
# theme
CONFIG_PACKAGE_luci-theme-cyberpunk=y
# dynamic DNS
CONFIG_PACKAGE_ddns-scripts=y
CONFIG_PACKAGE_ddns-scripts-services=y
CONFIG_PACKAGE_luci-app-ddns=y
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
