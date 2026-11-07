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

# ---- диагностика ----------------------------------------------------------
# Лог всего прогона дублируется в файл, а при сбое последние строки
# публикуются как GitHub-annotation (::error::). Их видно в логе job'а
# без доступа к API логов — в том числе в CI.
LOGFILE="${LOGFILE:-/tmp/pejir-build.log}"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

ann() { # ann <level> <title> <text>
  local lvl="$1" title="$2" text="$3"
  text="$(printf '%s' "$text" | tr -d '\r' | sed 's/%/%25/g; s/:/%3A/g; s/,/%2C/g' | tr '\n' ' ')"
  echo "::$lvl title=$title::$text"
}

STEP="startup"
on_err() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  sleep 1  # дать tee допечатать хвост лога
  # GitHub обрезает workflow-команду до 4096 символов, поэтому берём
  # последние ~1600 символов лога (там и есть причина) плюс строки
  # с признаками ошибки. Раньше брались последние N строк, но строки
  # make бывают по километру — ошибка не влезала в аннотацию.
  local tail_txt errs
  tail_txt="$(tail -c 1600 "$LOGFILE" 2>/dev/null | tr '\n' ' ')"
  errs="$(grep -aiE 'error|fatal|cannot|no space|failed|conflict|not found' "$LOGFILE" 2>/dev/null \
            | tail -n 10 | cut -c1-160 | tr '\n' ' ')"
  ann error "build.sh: сбой на шаге '${STEP}' (exit ${rc})" \
      "Хвост: ${tail_txt} | Ошибки: ${errs}"
  exit "$rc"
}
trap on_err EXIT

step() { STEP="$1"; echo "==> $1"; }

OPENWRT_VER="v25.12.6"
WORKDIR="${WORKDIR:-$HOME/openwrt-pejir01-build}"
JOBS="$(nproc)"
STOCK_FW_URL="https://router-pejir-openwrt-firmware.s3.eu-central-1.amazonaws.com/ci/1487/pejir-9.0.4-po-jenkins-pejir-openwrt-1487-ramips-mt7621-pejir01-34-BA-squashfs-upgrade.swu"
STOCK_SHA256="842f10d78d9d5d28063d72331bbf9b35d1983c713bebe24d9cabfb98a47c0c67"
BLOBS_URL="https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/pejir-vendor-blobs-9.0.4.zip"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

step "1. Build dependencies (Debian/Ubuntu)"
if command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y build-essential flex bison gawk gettext git \
    libncurses-dev libssl-dev python3-dev python3-setuptools python3-pip \
    python3-ply rsync swig unzip zip zlib1g-dev file wget curl bc cpio \
    xsltproc libelf-dev ccache python3-yaml squashfs-tools
fi

step "2. OpenWrt $OPENWRT_VER"
mkdir -p "$WORKDIR" && cd "$WORKDIR"
# Каталог openwrt/ к моменту сборки может уже существовать: кэш CI
# восстанавливает в него dl/, build_dir/ и staging_dir/. Проверять надо
# наличие .git, а не сам каталог — иначе клонирование пропускается, git am
# находит .git родительского репозитория (checkout самого pejir01) и
# пытается применить патчи OpenWrt к нему:
#   error: sha1 information is lacking or useless
#   error: could not build fake ancestor
if [ ! -d openwrt/.git ]; then
  mkdir -p openwrt
  (
    cd openwrt
    git init -q
    git remote add origin https://github.com/openwrt/openwrt.git
    git fetch --depth 1 origin tag "$OPENWRT_VER"
    git checkout -q --detach FETCH_HEAD
  )
fi
cd openwrt

# git am требует идентификацию автора. На машине без глобального
# user.name/user.email патчи не применятся: «unable to auto-detect
# email address». Задаём её локально для этого дерева.
git config user.name "openwrt-pejir01-build"
git config user.email "build@localhost"

step "3. Apply PEJIR01 patch series"
# Серия применяется целиком, поэтому проверяем не HEAD, а историю:
# патч 0001 — это и есть маркер серии.
if git log --oneline | grep -q "Perenio Elegance PEJIR01"; then
  echo "    series already applied, skip"
else
  git am --3way "$REPO_DIR"/patches/*.patch \
    || { echo "git am failed — apply manually: git am patches/*.patch"; exit 1; }
fi

# Версия прошивки, зашиваемая в образ: OTA-модуль должен знать, какая
# сборка установлена. Подставляется в пакет pejir-ota (файл попадает
# в /usr/lib/pejir/version — в ROM, а не в /etc: при sysupgrade с
# сохранением настроек файлы /etc восстанавливаются из старой системы,
# и маркер версии устарел бы).
OTA_VER_FILE="$REPO_DIR/VERSION"
OTA_DST="package/pejir-ota/files/version"
if [ -f "$OTA_VER_FILE" ] && [ -f "$OTA_DST" ]; then
  OTA_VER="$(tr -d ' \t\r\n' <"$OTA_VER_FILE")"
  printf '%s\n' "$OTA_VER" >"$OTA_DST"
  echo "    OTA: версия в образе — $OTA_VER"
else
  echo "    OTA: VERSION не найден, версия в образе останется 0.0.0-dev"
fi

step "4. Vendor binaries from stock 9.0.4 (Perenio public S3)"
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
    curl -sfL --retry 3 --retry-delay 2 --retry-connrefused \
         -o "$SW" "$STOCK_FW_URL" || rm -f "$SW"
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
    if ! ( cd /tmp/pejir-stock && cpio -idm --no-absolute-filenames < "$SW" ); then
      ann error "build.sh: не распаковалась заводская прошивка" \
          "cpio не смог разобрать $SW (размер $(stat -c%s "$SW" 2>/dev/null || echo '?') байт). \
Похоже на оборванную загрузку — скачайте прошивку заново и запустите сборку с STOCK_FW=./pejir-9.0.4.swu"
      exit 2
    fi
    if [ ! -f /tmp/pejir-stock/root.squashfs ]; then
      ann error "build.sh: в заводской прошивке нет root.squashfs" \
          "содержимое: $(ls -1 /tmp/pejir-stock 2>/dev/null | tr '\n' ' ')"
      exit 2
    fi
    # unsquashfs без прав root не может создать device-node'ы (например
    # /dev/console) и завершается с кодом 2 ("non-fatal errors"). Файлы при
    # этом распакованы, поэтому код 2 терпим — важно лишь, что нужные
    # бинари на месте. Если есть sudo, распаковываем от root и код будет 0.
    VENDOR_ROOT=/tmp/pejir-stock/vendor-root
    UNSQUASH_OPTS="-q"
    if unsquashfs -help 2>&1 | grep -q -- "-no-xattrs"; then
      UNSQUASH_OPTS="-q -no-xattrs"
    fi
    UNSQUASH="unsquashfs"
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      UNSQUASH="sudo -n unsquashfs"
    fi
    set +e
    $UNSQUASH $UNSQUASH_OPTS -d "$VENDOR_ROOT" /tmp/pejir-stock/root.squashfs
    urc=$?
    set -e
    if [ "$urc" -ne 0 ]; then
      echo "    WARNING: unsquashfs завершился с кодом $urc"
      echo "             (код 2 = некритичные ошибки: device-node'ы без прав root)"
      if [ "$urc" -ne 2 ]; then
        ann error "build.sh: root.squashfs не распаковался" \
            "код unsquashfs: $urc, файл: $(stat -c%s /tmp/pejir-stock/root.squashfs 2>/dev/null || echo '?') байт"
        exit 2
      fi
    fi

    missing=""
    for f in usr/bin/mcu usr/bin/mcud usr/bin/stm32flash \
             usr/sbin/idata_load usr/sbin/idata_flash usr/sbin/idata_getconf \
             usr/sbin/idata_lib.sh; do
      [ -f "$VENDOR_ROOT/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
      ann error "build.sh: вендорские бинари не извлеклись" \
          "не найдены в root.squashfs:$missing (код unsquashfs: $urc)"
      exit 2
    fi
    if [ "$(id -u)" -ne 0 ]; then
      sudo -n chown -R "$(id -u):$(id -g)" "$VENDOR_ROOT" 2>/dev/null || true
    fi
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

step "5. Feeds + config"
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
# LuCI: страница настройки Wi-Fi (radio) — без неё в образе нет раздела
# «Беспроводная связь» вообще: ни одна зависимость этот модуль не тянет
CONFIG_PACKAGE_luci-mod-wireless=y
# LuCI: веб-интерфейс LXC
CONFIG_PACKAGE_luci-app-lxc=y
# OTA: обновление прошивки кнопкой в LuCI (без автообновления)
CONFIG_PACKAGE_pejir-ota=y
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

step "6. Download sources"
export FORCE_UNSAFE_CONFIGURE=1
make download -j"$JOBS"

step "7. Build (this takes hours)"
make -j"$JOBS" || make -j1 V=s

step "8. Export rootfs for verification"
# В OpenWrt 25.12 отдельного rootfs squashfs не создаётся: rootfs лежит
# внутри sysupgrade-образа под именем "root". Кладём его рядом с образами
# под именем *-rootfs.squashfs, чтобы проверка содержимого образа в CI
# находила rootfs обычным поиском и проверяла реальное содержимое.
BINDIR="bin/targets/ramips/mt7621"
SU="$(ls "$BINDIR"/*squashfs-sysupgrade.bin 2>/dev/null | head -1 || true)"
if [ -n "$SU" ]; then
  rm -rf /tmp/pejir-rootfs && mkdir -p /tmp/pejir-rootfs
  if tar xf "$SU" -C /tmp/pejir-rootfs 2>/dev/null; then
    R="$(find /tmp/pejir-rootfs -type f -name root | head -1 || true)"
    if [ -n "$R" ]; then
      OUT="$BINDIR/$(basename "$SU" -squashfs-sysupgrade.bin)-rootfs.squashfs"
      if cp "$R" "$OUT" 2>/dev/null; then
        echo "  rootfs для проверки: $OUT"
      fi

      # Проверяем, что OTA-модуль действительно попал в образ.
      # unsquashfs -l не требует root и не создаёт device-node'ы,
      # поэтому код возврата здесь всегда 0.
      if command -v unsquashfs >/dev/null 2>&1; then
        ROOTFS_LIST="$(unsquashfs -l "$R" 2>/dev/null || true)"
        OTA_MISSING=""
        for f in usr/bin/pejir-ota usr/lib/pejir/version etc/config/pejir_ota \
                 www/luci-static/resources/view/perenio/ota.js \
                 usr/share/luci/menu.d/luci-app-pejir-ota.json \
                 usr/share/rpcd/acl.d/luci-app-pejir-ota.json; do
          echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || OTA_MISSING="$OTA_MISSING $f"
        done
        if [ -n "$OTA_MISSING" ]; then
          ann error "build.sh: OTA" "В образе нет файлов OTA:$OTA_MISSING"
          # Пакет pejir-ota не попал в образ — сборку считаем проваленной,
          # иначе несоответствие тихо уедет в релиз.
          echo "ОШИБКА: пакет pejir-ota не попал в образ ($OTA_MISSING)"
          exit 1
        else
          echo "  OTA-модуль в образе: OK"
        fi
      fi
    fi
  fi
fi

# Пакеты (.apk) в OpenWrt 25.12 кладутся в bin/targets/<board>/<subtarget>/packages,
# а не в bin/packages/<board>/<subtarget>, как было в 23.05. Складываем ссылки на
# них в bin/packages/ramips/mt7621 — там, где их ищет проверка содержимого образа.
mkdir -p bin/packages/ramips/mt7621
find bin -type f -name '*.apk' 2>/dev/null | while read -r f; do
  ln -sf "$(pwd)/$f" "bin/packages/ramips/mt7621/$(basename "$f")" 2>/dev/null || true
done
echo "  пакетов в bin/packages/ramips/mt7621: $(ls bin/packages/ramips/mt7621 2>/dev/null | wc -l)"

echo ""
echo "============================================================"
echo " DONE. Images:"
ls -la "$BINDIR"/*.bin
echo "============================================================"
