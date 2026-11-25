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
BLOBS_URL="https://github.com/sergej19882906/openwrt-pejir01/releases/download/v25.12.6-pejir01.5/pejir-vendor-blobs-9.0.4.zip"
BLOBS_URL_ALT="https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/pejir-vendor-blobs-9.0.4.zip"
# sha256 ассета с вендорскими блобами (v25.12.6-pejir01.5). Без проверки
# некто с правом на изменение релиза мог бы подменить бинарники - supply chain.
BLOBS_SHA256="eb6d846f8ce4055400229a959940438c89312b97da9b00ee877704f6489b64b6"
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

  # ЗАЩИТА ОТ РАСХОЖДЕНИЯ ВЕРСИИ. Сборка идёт по тегу, а маркер версии
  # берётся из файла VERSION в репозитории. Если забыть его поднять,
  # образ получится с ЧУЖОЙ версией: устройство будет показывать старую,
  # а pejir-upgrade-purge сравнивает маркер с меткой в overlay - чистка
  # остатков стока просто не запустится (ровно так и вышло с релизом
  # .58, собранным с маркером .57).
  BUILD_TAG=""
  if [ -n "${GITHUB_REF_NAME:-}" ]; then
    BUILD_TAG="$GITHUB_REF_NAME"
  else
    BUILD_TAG="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"
  fi
  # Сверяем ТОЛЬКО с тегом релиза: сборки ветки main версию не несут
  # (там VERSION ещё не поднят под следующий релиз).
  case "$BUILD_TAG" in
  v*pejir01.*)
    TAG_VER="${BUILD_TAG#v}"
    if [ "$TAG_VER" != "$OTA_VER" ]; then
      echo "ОШИБКА: тег сборки $BUILD_TAG, а в VERSION — $OTA_VER"
      echo "        образ получится с неверной версией. Поднимите VERSION до $TAG_VER"
      exit 1
    fi
    echo "    OTA: версия совпадает с тегом сборки ($BUILD_TAG)"
    ;;
  *)
    echo "    OTA: сборка не по тегу релиза ($BUILD_TAG) - сверка версии пропущена"
    ;;
  esac
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

  # 4c. ассет релиза с уже распакованными блобами.
  # Основной URL закреплён на конкретный релиз: ассет с блобами лежит
  # только в v25.12.6-pejir01.5, а releases/latest отдаёт 404 — если
  # публичный S3 Perenio однажды отвалится, сборка должна найти блобы
  # на GitHub. Второй URL — на случай, если новый релиз снова будет
  # нести такой ассет.
  ZIP="/tmp/pejir-vendor-blobs.zip"
  if [ ! -f "$SW" ] && [ ! -f "$ZIP" ]; then
    for u in "$BLOBS_URL" "$BLOBS_URL_ALT"; do
      curl -sfL --retry 3 --retry-delay 2 -o "$ZIP" "$u" && break || rm -f "$ZIP"
    done
  fi

  if [ -f "$ZIP" ]; then
    if command -v sha256sum >/dev/null && [ -n "$BLOBS_SHA256" ]; then
      got="$(sha256sum "$ZIP" | cut -d' ' -f1)"
      if [ "$got" != "$BLOBS_SHA256" ]; then
        if [ "${PEJIR_ALLOW_BROKEN_BLOBS:-0}" = "1" ]; then
          echo "    WARNING: sha256 of vendor blobs differs (PEJIR_ALLOW_BROKEN_BLOBS=1)"
          echo "            expected $BLOBS_SHA256"
          echo "            got      $got"
        else
          ann error "build.sh: sha256 ассета с вендорскими блобами не совпал" \
              "ожидался $BLOBS_SHA256, получен $got. Блобы могли быть подменены. \
Если это осознанная замена ассета - обновите BLOBS_SHA256 в build.sh или \
запустите сборку с PEJIR_ALLOW_BROKEN_BLOBS=1"
          exit 2
        fi
      else
        echo "    vendor blobs sha256 OK"
      fi
    elif [ -z "$BLOBS_SHA256" ]; then
      echo "    WARNING: BLOBS_SHA256 не задан - блобы не проверены"
    fi
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
        if [ "${PEJIR_ALLOW_BROKEN_STOCK:-0}" = "1" ]; then
          echo "    WARNING: sha256 of stock firmware differs (PEJIR_ALLOW_BROKEN_STOCK=1)"
          echo "            expected $STOCK_SHA256"
          echo "            got      $got"
          echo "            vendor binaries will be extracted from an unverified image"
        else
          ann error "build.sh: sha256 заводской прошивки не совпал" \
              "ожидался $STOCK_SHA256, получен $got. Файл мог быть подменён или \
это другая версия прошивки. Если заводской образ обновлён сознательно - \
обновите STOCK_SHA256 в build.sh или запустите с PEJIR_ALLOW_BROKEN_STOCK=1"
          exit 2
        fi
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
CONFIG_PACKAGE_pejir-extroot=y
# Автонастройка после установки: перенос overlay на флешку + Zigbee HOMEd
CONFIG_PACKAGE_pejir-autosetup=y
# timeout нужен AT-скриптам: без ограничения времени чтение с
# последовательного порта, на который модем не отвечает, висит вечно
# и не даёт init-скриптам дойти до конца.
CONFIG_PACKAGE_coreutils-timeout=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-storage-uas=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_coreutils-stty=y
# bind-host даёт /usr/bin/host. LuCI DDNS проверяет наличие host/khost/drill
# (переменная has_bindhost в rpcd/ucode/ddns.uc) и, если их нет, не
# показывает опцию "Force TCP on DNS" и ругается подсказкой про
# bind-host/knot-host/drill. BusyBox-nslookup не умеет TCP и не
# корректно работает с заданным DNS-сервером, поэтому для DDNS нужен
# именно bind-host.
CONFIG_PACKAGE_bind-host=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-serial-option=y
# LTE-модем: ModemManager из образа УДАЛЁН.
#
# Он сам находит AT-порт модема и забирает его себе, а LTE и SMS у нас
# ведут собственные скрипты (47-pejir-lte, 40-pejir-sms) через тот же
# /dev/ttyUSB2. Одновременно работать они не могут: модем отвечает
# только одному из них. Поэтому демон, его rpcd-плагин и страница LuCI
# "Модем" больше не ставятся; LTE работает через ECM (cdc_ether) и
# собственные AT-команды.
#
# Модули ядра для разных протоколов модема остаются (option, cdc-mbim,
# qmi-wwan и далее) - они нужны uqmi/umbim и другим модемам.
CONFIG_PACKAGE_xz-utils=y
CONFIG_PACKAGE_mosquitto-nossl=y
CONFIG_PACKAGE_mosquitto-client-nossl=y
CONFIG_PACKAGE_kmod-amneziawg=y
CONFIG_PACKAGE_amneziawg-tools=y
CONFIG_PACKAGE_luci-proto-amneziawg=y
CONFIG_PACKAGE_pejir-lte-base=y
CONFIG_PACKAGE_smstools3=y
CONFIG_PACKAGE_pejir-sms=y
# Восстановление файлов пакетов из /rom при загрузке: верхний слой
# overlay переживает sysupgrade, и протухшие копии файлов пакетов
# перекрывают свежие файлы нового образа.
CONFIG_PACKAGE_pejir-sync=y
CONFIG_PACKAGE_pejir-homed-feed=y
CONFIG_PACKAGE_pejir-zigbee-ncp=y
# Мост Telegram: пересылка всех входящих SMS в чат и команды из чата.
# Зависит от wget-ssl (TLS), который в образе уже есть.
CONFIG_PACKAGE_pejir-telegram=y
# stock migration: Wi-Fi SSID/keys, country, root password from idata
CONFIG_PACKAGE_pejir-idata=y
# LuCI: battery/power status and SMS pages for PEJIR01
CONFIG_PACKAGE_luci-app-perenio=y
# Страница «Беспроводная связь» в LuCI 25.12 — это view/network/wireless.js,
# он приходит с пакетом luci-mod-network. Отдельного luci-mod-wireless в
# фиде LuCI 25.12 больше нет, поэтому отдельной строки CONFIG_PACKAGE_* здесь
# не нужно: luci-mod-network и так ставится (он нужен luci-mod-admin-full).
# Русский интерфейс LuCI: переводы базовых модулей и всех приложений,
# которые стоят в образе. Язык по умолчанию — русский (uci-defaults
# 50-perenio-ru выставляет luci.main.lang=ru).
#
# ВАЖНО: пакеты luci-i18n-* в LuCI 25.12 объявлены HIDDEN:=1, то есть это
# tristate-символы без prompt. Значение, заданное напрямую как
# CONFIG_PACKAGE_luci-i18n-*-ru=y, сбрасывается командой "make defconfig"
# ("# CONFIG_... is not set") — проверено экспериментом на kconfig из
# OpenWrt 25.12. Переключатель другой: опция LUCI_LANG_ru в конфиге
# luci-base (menu "Translations"). При CONFIG_LUCI_LANG_ru=y пакеты
# luci-i18n-*-ru становятся "y" по умолчанию (DEFAULT:=LUCI_LANG_ru||(ALL&&m))
# и собираются для всех модулей LuCI, присутствующих в образе.
# Переводы кладутся в /usr/lib/lua/luci/i18n/<домен>.ru.lmo — туда же,
# откуда их читает LuCI 25.12 (load_catalog в dispatcher.uc).
CONFIG_LUCI_LANG_ru=y
# LuCI: веб-интерфейс LXC
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
# Профиль модема Gosuncnwelink GM510 (наш LTE-модем). Без него в образе
# нет /usr/share/modeminfo/scripts/GOSUN.at, и modeminfo не может опросить
# модем, даже если секция config modeminfo создана.
CONFIG_PACKAGE_modeminfo-serial-gosun=y
CONFIG_PACKAGE_pingcontrol=y
CONFIG_PACKAGE_qminfo=y
CONFIG_PACKAGE_xmm-modem=y
# qminfo использует сообщения QMI, которых нет в коллекции basic:
# DMS GET SOFTWARE_VERSION, DMS GET POWER_STATE, NAS GET LTE_CPHY_CA_INFO.
# В libqmi 1.36 они лежат только в коллекции full (data/qmi-collection-
# basic.json), а OpenWrt по умолчанию собирает именно basic — свой
# дефолт libqmi как раз full. Без этой строки qminfo не компилируется:
# "implicit declaration of function 'qmi_client_dms_get_software_version'".
CONFIG_LIBQMI_COLLECTION_FULL=y
# theme
# Argon — основная тема LuCI, ставится по умолчанию (uci-defaults
# 35-pejir-theme-argon выставляет luci.main.mediaurlbase=/luci-static/argon).
# Cyberpunk остаётся в образе как альтернатива: он виден в списке
# "Design" на странице "Система" наряду с Argon.
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-theme-cyberpunk=y
# dynamic DNS
CONFIG_PACKAGE_ddns-scripts=y
CONFIG_PACKAGE_ddns-scripts-services=y
CONFIG_PACKAGE_luci-app-ddns=y
CONFIG_PACKAGE_dropbear=y
# ccache: ускоряет пересборку в CI (кеш-путь openwrt/.ccache в build.yml)
CONFIG_CCACHE=y
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

        # Размер rootfs не должен превышать размер тома UBI "rootfs" на
        # устройстве (23 998 464 байта). Именно из-за нехватки места OTA
        # в релиз .25 не мог записать rootfs и обрывался на "Permission
        # denied"/нехватке места. Сборка обязана падать здесь, а не
        # выпускать образ, который на устройстве не влезает.
        ROOTFS_MAX=23998464
        RZ="$(stat -c%s "$R" 2>/dev/null || echo 0)"
        if [ "$RZ" -gt "$ROOTFS_MAX" ]; then
          ann error "build.sh: rootfs size" "rootfs $RZ байт больше тома UBI $ROOTFS_MAX байт"
          echo "ОШИБКА: rootfs ($RZ байт) не влезает в том UBI rootfs ($ROOTFS_MAX байт)"
          echo "ОШИБКА: OTA на устройстве запишет rootfs не полностью"
          exit 1
        fi
        echo "  размер rootfs: $RZ байт (предел тома UBI $ROOTFS_MAX) - OK"
      fi

      # Проверяем, что OTA-модуль действительно попал в образ.
      # unsquashfs -l не требует root и не создаёт device-node'ы,
      # поэтому код возврата здесь всегда 0.
      if command -v unsquashfs >/dev/null 2>&1; then
        ROOTFS_LIST="$(unsquashfs -l "$R" 2>/dev/null || true)"

        # Пакеты, которые мы намеренно убрали из образа. Если они
        # вернутся (зависимость от другого пакета, забытый CONFIG), то
        # либо rootfs перестанет влезать в том UBI, либо появится
        # нерабочее меню в веб-интерфейсе.
        # Проверка по списку файлов - unsquashfs -l его отдаёт.
        ABSENT_MISSING=""
        # LXC нет и не должен появляться: стоковая прошивка его ставит,
        # и после sysupgrade остатки (rpcd-плагин lxc.so, контроллер
        # LuCI lxc.lua) остаются в верхнем слое - тогда в меню LuCI
        # появляется пункт "LXC Containers", хотя LXC в образе нет.
        for f in usr/bin/sing-box usr/sbin/sing-box \
                 usr/bin/lxc-start usr/bin/lxc-create usr/bin/lxc-config \
                 usr/lib/liblxc.so.1.9.0 usr/lib/liblxc.so.1 \
                 usr/lib/rpcd/lxc.so \
                 usr/lib/lua/luci/controller/lxc.lua \
                 usr/lib/lua/luci/view/lxc.htm \
                 usr/share/luci/menu.d/luci-app-lxc.json \
                 etc/init.d/cgroup2; do
          if echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f"; then
            ABSENT_MISSING="$ABSENT_MISSING $f"
          fi
        done
        if [ -n "$ABSENT_MISSING" ]; then
          ann error "build.sh: extra packages" "в образе есть лишние пакеты:$ABSENT_MISSING"
          echo "ОШИБКА: в образе есть пакеты, которые убраны намеренно:$ABSENT_MISSING"
          exit 1
        fi
        echo "  sing-box и LXC в образе отсутствуют - OK"
        OTA_MISSING=""
        for f in usr/bin/pejir-ota usr/bin/pejir-ovl-purge usr/lib/pejir/version \
                 etc/config/pejir_ota \
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

        # Helper очистки верхнего слоя обязан уметь показывать найденный
        # каталог (--print-upper): без этого режима нечем проверить на
        # устройстве, что разбор /proc/mounts вообще работает. Регрессия
        # патча 0083 (upperdir= искался по полям, а опции mount'а - одно
        # поле с запятыми) внешне выглядела бы как "чистить нечего".
        if echo "$ROOTFS_LIST" | grep -q "squashfs-root/usr/bin/pejir-ovl-purge"; then
          OVLPURGE_SRC="$(unsquashfs -cat "$R" "usr/bin/pejir-ovl-purge" 2>/dev/null || true)"
          if echo "$OVLPURGE_SRC" | grep -q -- "--print-upper"; then
            echo "  helper очистки умеет --print-upper: OK"
          else
            ann error "build.sh: OTA" "pejir-ovl-purge без --print-upper - нечем проверить разбор /proc/mounts"
            echo "ОШИБКА: pejir-ovl-purge без режима --print-upper"
            exit 1
          fi
          # Разбор /proc/mounts обязан искать upperdir= по ВСЕЙ строке:
          # опции mount'а - одно поле с запятыми, поэтому поиск по
          # отдельным полям (awk) не находит ничего (регрессия 0083).
          if echo "$OVLPURGE_SRC" | grep -q "upperdir="; then
            echo "  helper очистки ищет upperdir= в /proc/mounts: OK"
          else
            ann error "build.sh: OTA" "pejir-ovl-purge не ищет upperdir= в /proc/mounts"
            echo "ОШИБКА: pejir-ovl-purge без разбора /proc/mounts"
            exit 1
          fi
        fi

        # Прошивка NCP-прошивки Zigbee-модуля (пакет pejir-zigbee-ncp)
        # обязана попасть в образ: без неё Zigbee не заработает, если
        # модуль не отвечает по EZSP. Отсутствие этих файлов - тихий
        # дефект, поэтому проверяем явно.
        NCP_MISSING=""
        for f in usr/bin/pejir-ncp-flash usr/bin/pejir-zigbee-ncp \
                 usr/share/pejir/zigbee-setup.sh; do
            echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || NCP_MISSING="$NCP_MISSING $f"
        done
        if [ -n "$NCP_MISSING" ]; then
            ann error "build.sh: Zigbee NCP" "В образе нет файлов прошивки NCP:$NCP_MISSING"
            echo "ОШИБКА: пакет pejir-zigbee-ncp не попал в образ ($NCP_MISSING)"
            exit 1
        else
            echo "  прошивка NCP (pejir-zigbee-ncp) в образе: OK"
        fi

        # 40-pejir-sms обязан содержать ensure_charset_options(): без него
        # опции кодировки пишутся только после успешного AT-ответа, а
        # модем не отвечает, пока активен LTE-вызов (патч 0083).
        SMS_INIT_SRC="$(unsquashfs -cat "$R" "etc/init.d/40-pejir-sms" 2>/dev/null || true)"
        if echo "$SMS_INIT_SRC" | grep -q "ensure_charset_options"; then
          echo "  40-pejir-sms содержит ensure_charset_options(): OK"
        else
          ann error "build.sh: SMS" "В 40-pejir-sms нет ensure_charset_options() - кодировка зависит от AT-ответа"
          echo "ОШИБКА: 40-pejir-sms без ensure_charset_options()"
          exit 1
        fi

        # Init-скрипты обязаны РЕАЛЬНО стартовать при загрузке.
        # /etc/rc.common вызывает start_service() только если скрипт
        # объявил USE_PROCD=1; без этого флага вызывается собственный
        # start() { return 0; } и скрипт молча ничего не делает (патч
        # 0085). Проверяем, что у каждого нашего init-скрипта есть
        # рабочий способ запуска.
        # Детектор вынесен в scripts/init-start-check.sh, чтобы
        # build.sh и тест tests/test-build-init-check.sh проверяли ОДНУ
        # и ту же логику.
        #
        # ВАЖНО: USE_PROCD=1 ищется ЯКОРНЫМ grep -E '^[[:space:]]*'.
        # Простой grep совпадает с КОММЕНТАРИЕМ ("# Объявляем
        # USE_PROCD=1 нельзя: ...") и объявляет исправный скрипт
        # годным, скрывая дефект - проверка становится пустой.
        INIT_START_BAD=""
        INIT_CHECK="$REPO_DIR/scripts/init-start-check.sh"
        if [ ! -f "$INIT_CHECK" ]; then
          ann error "build.sh: init" "нет детектора $INIT_CHECK"
          echo "ОШИБКА: нет scripts/init-start-check.sh"
          exit 1
        fi
        for f in etc/init.d/40-pejir-sms etc/init.d/41-pejir-modem \
                 etc/init.d/47-pejir-lte etc/init.d/41-pejir-sync \
                 etc/init.d/pejir-sms-spool; do
            echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || continue
            TMPF="$(mktemp)"
            unsquashfs -cat "$R" "$f" > "$TMPF" 2>/dev/null || true
            if [ ! -s "$TMPF" ]; then
                rm -f "$TMPF"
                INIT_START_BAD="$INIT_START_BAD $f(нет)"
                continue
            fi
            if sh "$INIT_CHECK" "$TMPF" >/dev/null 2>&1; then
                rm -f "$TMPF"
                continue
            fi
            sh "$INIT_CHECK" "$TMPF" 2>/dev/null | sed 's/^/       /' || true
            rm -f "$TMPF"
            INIT_START_BAD="$INIT_START_BAD $f"
        done
        if [ -n "$INIT_START_BAD" ]; then
            ann error "build.sh: init" "init-скрипты без рабочего способа запуска:$INIT_START_BAD"
            echo "ОШИБКА: start_service() без USE_PROCD=1 и без start() - скрипты молчат при загрузке"
            exit 1
        else
            echo "  init-скрипты имеют рабочий способ запуска: OK"
        fi

        # Вендорные бинари mcu/mcud ищут libubox.so/libubus.so по обычному
        # имени, поэтому в образе обязаны быть symlink'и на версионные
        # библиотеки в /lib. Если рецепт install'а по какой-то причине не
        # отработал (например, '#' в рецепте съедал остальные команды),
        # пакет не пройдёт проверку зависимостей — но лишняя проверка не даст
        # такому случаю уехать в релиз молча.
        MCU_MISSING=""
        for f in usr/bin/mcu usr/bin/mcud usr/lib/libubox.so usr/lib/libubus.so; do
          echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || MCU_MISSING="$MCU_MISSING $f"
        done
        if [ -n "$MCU_MISSING" ]; then
          ann error "build.sh: MCU" "В образе нет вендорных файлов:$MCU_MISSING"
          echo "ОШИБКА: вендорные бинари или symlink'и libubox/libubus не попали в образ ($MCU_MISSING)"
          exit 1
        fi
        echo "  вендорные бинари и symlink'и libubox/libubus: OK"

        # bind-host (команда host) нужен странице DDNS: LuCI проверяет
        # наличие host/khost/drill (has_bindhost) и без них не даёт
        # включить "Force TCP on DNS" и неверно определяет зарегистрированный
        # IP. Если пакета нет в образе - DDNS работает вслепую.
        HOST_MISSING=""
        for f in usr/bin/host; do
          echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || HOST_MISSING="$HOST_MISSING $f"
        done
        if [ -n "$HOST_MISSING" ]; then
          ann error "build.sh: DDNS" "в образе нет bind-host:$HOST_MISSING"
          echo "ОШИБКА: bind-host не попал в образ ($HOST_MISSING)"
          exit 1
        fi
        echo "  bind-host (host) в образе: OK"

        # LTE-модем: модули ядра для USB-протоколов модема (CDC, MBIM, QMI)
        # и AT-порт (option). ModemManager в образе быть НЕ должно: он
        # забирает AT-порт и конфликтует с нашими скриптами LTE/SMS.
        MM_MISSING=""
        for m in option.ko cdc_ether.ko cdc_mbim.ko qmi_wwan.ko; do
          echo "$ROOTFS_LIST" | grep -q "$m" || MM_MISSING="$MM_MISSING $m"
        done
        if [ -n "$MM_MISSING" ]; then
          ann error "build.sh: модули модема" "в образе нет файлов:$MM_MISSING"
          echo "ОШИБКА: модули ядра для модема не попали в образ ($MM_MISSING)"
          exit 1
        fi
        if echo "$ROOTFS_LIST" | grep -qiE "modemmanager"; then
          ann error "build.sh: ModemManager" "ModemManager попал в образ, а он конфликтует с 47-pejir-lte/40-pejir-sms"
          echo "ОШИБКА: ModemManager не должен попадать в образ"
          exit 1
        fi
        echo "  LTE: модули ядра (option, cdc_ether, cdc_mbim, qmi_wwan): OK"
        echo "  LTE: ModemManager в образе отсутствует: OK"

        # Файлы страниц LuCI порта, init-скриптов и uci-defaults.
        #
        # У пакетов с собственным рецептом install каталог root/ копируется
        # поимённо, и любой забытый файл молча не попадает в образ. Так
        # потерялся etc/uci-defaults/50-perenio-ru (русский язык по
        # умолчанию): файл лежал в дереве пакета, но в образ не попал.
        # Проверяем список явно, чтобы такой случай больше не уезжал
        # в релиз тихо.
        PERENIO_MISSING=""
        for f in etc/uci-defaults/50-perenio-ru etc/uci-defaults/20-pejir-idata \
                 etc/init.d/40-pejir-sms etc/init.d/41-pejir-modem \
                 etc/init.d/47-pejir-lte \
                 etc/uci-defaults/51-pejir-wifi-dualband \
                 etc/uci-defaults/52-perenio-ru-lang \
                 usr/share/pejir/wifi-config.sh \
                 etc/config/cron \
                 www/luci-static/resources/view/perenio/battery.js \
                 www/luci-static/resources/view/perenio/sms.js \
                 www/luci-static/resources/view/perenio/idata.js \
                 www/luci-static/resources/view/perenio/diag.js \
                 usr/share/luci/menu.d/luci-app-perenio.json \
                 usr/share/rpcd/acl.d/luci-app-perenio.json \
                 usr/libexec/perenio-diag \
                 usr/libexec/pejir-ussd \
                 usr/libexec/pejir-led \
                 usr/libexec/pejir-lte-apn \
                 usr/libexec/pejir-modem-ctl \
                 www/luci-static/resources/view/perenio/lte.js \
                 etc/init.d/pejir-led \
                 etc/init.d/41-pejir-sync \
                 etc/init.d/pejir-sms-spool \
                 etc/uci-defaults/80-pejir-sync; do
          echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || PERENIO_MISSING="$PERENIO_MISSING $f"
        done
        if [ -n "$PERENIO_MISSING" ]; then
          ann error "build.sh: Perenio LuCI" "В образе нет файлов порта:$PERENIO_MISSING"
          echo "ОШИБКА: файлы страниц/init-скриптов LuCI порта не попали в образ ($PERENIO_MISSING)"
          exit 1
        fi
        echo "  страницы LuCI, init-скрипты и uci-defaults порта: OK"

        # Постоянная очередь SMS (патч 0086). Если скрипт не попал в
        # образ или потерял права, очередь молча вернётся в tmpfs, и
        # принятые SMS снова будут пропадать после перезагрузки - без
        # всякой ошибки на экране.
        SPOOL_SRC="$(unsquashfs -cat "$R" "etc/init.d/pejir-sms-spool" 2>/dev/null || true)"
        if [ -z "$SPOOL_SRC" ]; then
          ann error "build.sh: SMS spool" "нет etc/init.d/pejir-sms-spool - очередь SMS не будет постоянной"
          echo "ОШИБКА: в образе нет etc/init.d/pejir-sms-spool"
          exit 1
        fi
        echo "$SPOOL_SRC" | grep -q "mount --bind" || {
          ann error "build.sh: SMS spool" "pejir-sms-spool без mount --bind"
          echo "ОШИБКА: pejir-sms-spool не делает bind-mount очереди SMS"
          exit 1
        }
        if ! echo "$ROOTFS_LIST" | grep -q "squashfs-root/etc/init.d/pejir-sms-spool"; then
          ann error "build.sh: SMS spool" "pejir-sms-spool не попал в образ"
          echo "ОШИБКА: etc/init.d/pejir-sms-spool отсутствует в списке образа"
          exit 1
        fi
        # Права 0755: без исполняемого бита init-скрипт не запускается,
        # и очередь молча остаётся в tmpfs.
        ROOTFS_LONG="$(unsquashfs -ll "$R" 2>/dev/null || true)"
        if ! echo "$ROOTFS_LONG" | grep "squashfs-root/etc/init.d/pejir-sms-spool" | grep -q "^-rwxr-xr-x"; then
          ann error "build.sh: SMS spool" "у pejir-sms-spool нет прав 0755"
          echo "ОШИБКА: etc/init.d/pejir-sms-spool без прав 0755"
          exit 1
        fi
        echo "  постоянная очередь SMS (pejir-sms-spool): OK"

        # Русский каталог переводов страницы обновления прошивки (патч
        # 0087). Без .lmo английский msgid показывается как есть, то
        # есть страница в русской локали остаётся наполовину
        # английской - ровно тот дефект, который закрывал патч.
        if ! echo "$ROOTFS_LIST" | grep -q "luci-app-pejir-ota.ru.lmo"; then
          ann error "build.sh: OTA i18n" "нет .lmo с переводом страницы обновления прошивки"
          echo "ОШИБКА: в образе нет usr/lib/lua/luci/i18n/luci-app-pejir-ota.ru.lmo"
          exit 1
        fi
        echo "  перевод страницы обновления прошивки (pejir-ota.ru.lmo): OK"

        # Инструменты для модемов. qminfo и xmm-modem лежали в дереве
        # пакетов, но без CONFIG_PACKAGE_*=y в образ не попадали, а у
        # qminfo вдобавок не было Build/Prepare/Build/Compile — собрать
        # его было нельзя. Проверяем явно.
        MODEM_MISSING=""
        # pingcontrol ставится в /bin (в 25.12 /bin — настоящий каталог,
        # а не ссылка на /usr/bin), поэтому путь именно bin/pingcontrol.
        for f in usr/bin/qminfo usr/bin/atinout bin/pingcontrol \
                 lib/netifd/proto/xmm.sh etc/gcom/xmm-connect.gcom \
                 usr/bin/modeminfo usr/share/modeminfo/scripts/GOSUN.at \
                 usr/share/modeminfo/scripts/GOSUN \
                 etc/uci-defaults/60-perenio-modeminfo; do
          echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || MODEM_MISSING="$MODEM_MISSING $f"
        done
        if [ -n "$MODEM_MISSING" ]; then
          ann error "build.sh: Modem tools" "В образе нет модемных утилит:$MODEM_MISSING"
          echo "ОШИБКА: модемные утилиты не попали в образ ($MODEM_MISSING)"
          exit 1
        fi
        echo "  модемные утилиты (qminfo/atinout/pingcontrol/xmm-modem/modeminfo+GOSUN): OK"

        # Тема Argon и русские переводы LuCI.
        #
        # Тема: вендорится в дерево как package/luci-theme-argon, поэтому
        # проверяем и файлы темы, и uci-defaults, который переключает
        # тему по умолчанию.
        #
        # Переводы: пакеты luci-i18n-*-ru объявлены HIDDEN в luci.mk
        # (tristate без prompt), поэтому make defconfig сбрасывает
        # заданное напрямую CONFIG_PACKAGE_luci-i18n-*-ru=y. Переключатель
        # другой — CONFIG_LUCI_LANG_ru=y в build.sh. Проверяем, что
        # каталоги переводов (.lmo) реально попали в образ: без них
        # интерфейс LuCI остаётся английским, несмотря на lang=ru.
        THEME_MISSING=""
        for f in www/luci-static/argon/css/cascade.css \
                 www/luci-static/resources/view/argon-config.js \
                 www/luci-static/resources/argon-appearance.js \
                 usr/share/ucode/luci/template/themes/argon/header.ut \
                 usr/share/ucode/luci/template/themes/argon/footer.ut \
                 etc/config/argon \
                 etc/uci-defaults/35-pejir-theme-argon \
                 usr/share/luci/menu.d/luci-app-argon-config.json \
                 usr/share/rpcd/acl.d/luci-app-argon-config.json; do
          echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f" || THEME_MISSING="$THEME_MISSING $f"
        done
        if [ -n "$THEME_MISSING" ]; then
          ann error "build.sh: Argon theme" "В образе нет файлов темы Argon:$THEME_MISSING"
          echo "ОШИБКА: тема Argon не попала в образ ($THEME_MISSING)"
          exit 1
        fi
        echo "  тема Argon: OK"

        # Каталог русских переводов LuCI: /usr/lib/lua/luci/i18n/*.ru.lmo.
        # Проверяем, что файлы есть и что их не один, а сколько-то.
        I18N_COUNT="$(echo "$ROOTFS_LIST" | grep -c 'squashfs-root/usr/lib/lua/luci/i18n/.*\.ru\.lmo' || true)"
        if [ "${I18N_COUNT:-0}" -lt 1 ]; then
          ann error "build.sh: LuCI i18n" "В образе нет русских переводов LuCI (.ru.lmo)"
          echo "ОШИБКА: русские переводы LuCI не попали в образ (CONFIG_LUCI_LANG_ru не сработал?)"
          exit 1
        fi
        echo "  русских переводов LuCI (.ru.lmo): $I18N_COUNT"

        # Переводы САМОЙ темы Argon. Домен = имя .po-файла, поэтому файл
        # называется argon-config.ru.lmo (не argon.ru.lmo). Проверяем
        # явно: без него интерфейс темы (страница настроек Argon) остаётся
        # английским, хотя общий перевод LuCI уже есть.
        if ! echo "$ROOTFS_LIST" | grep -q 'squashfs-root/usr/lib/lua/luci/i18n/argon-config\.ru\.lmo'; then
          ann error "build.sh: Argon i18n" "В образе нет переводов темы Argon (argon-config.ru.lmo)"
          echo "ОШИБКА: переводы темы Argon не попали в образ"
          exit 1
        fi
        echo "  переводы темы Argon (argon-config.ru.lmo): OK"

        # Русский перевод наших страниц порта: luci-app-perenio.ru.lmo.
        # Без него страницы батареи/SMS/заводских данных остаются
        # английскими даже при русском языке интерфейса.
        if ! echo "$ROOTFS_LIST" | grep -q 'squashfs-root/usr/lib/lua/luci/i18n/luci-app-perenio\.ru\.lmo'; then
          ann error "build.sh: LuCI i18n" "В образе нет перевода страниц порта"
          echo "ОШИБКА: нет luci-app-perenio.ru.lmo (переводы страниц порта)"
          exit 1
        fi
        echo "  переводы страниц порта (luci-app-perenio.ru.lmo): OK"

        # Скрипт переноса overlay на флешку (extroot). Без него в образе
        # нет /usr/bin/pejir-extroot, и перенести overlay на USB-флешку
        # штатными средствами нечем.
        if ! echo "$ROOTFS_LIST" | grep -q 'squashfs-root/usr/bin/pejir-extroot'; then
          ann error "build.sh: extroot" "В образе нет /usr/bin/pejir-extroot"
          echo "ОШИБКА: пакет pejir-extroot не попал в образ"
          exit 1
        fi
        echo "  скрипт extroot (/usr/bin/pejir-extroot): OK"

        # Автонастройка после установки: init-скрипт pejir-autosetup
        # переносит overlay на флешку и ставит Zigbee-стек HOMEd.
        # Без него после прошивки всё приходится делать руками.
        for f in etc/init.d/pejir-autosetup usr/share/pejir/zigbee-setup.sh; do
          if ! echo "$ROOTFS_LIST" | grep -q "squashfs-root/$f"; then
            ann error "build.sh: autosetup" "В образе нет $f"
            echo "ОШИБКА: пакет pejir-autosetup не попал в образ ($f)"
            exit 1
          fi
        done
        echo "  автонастройка (pejir-autosetup + zigbee-setup.sh): OK"

        # ACL страниц порта. В LuCI 25.12 fs.read/fs.exec проверяются по
        # scope "file" с указанием пути (в rpcd/plugins/file.c вызов
        # session_access(sid, "file", path, perm)). Одного "ubus": {"file":
        # [...]} недостаточно - без раздела "file" все страницы порта
        # (батарея, SMS, заводские данные, диагностика) отдают
        # "Permission denied".
        ACL_FILE="squashfs-root/usr/share/rpcd/acl.d/luci-app-perenio.json"
        if ! echo "$ROOTFS_LIST" | grep -q "$ACL_FILE"; then
          ann error "build.sh: Perenio ACL" "В образе нет ACL luci-app-perenio"
          echo "ОШИБКА: ACL страниц порта не попал в образ"
          exit 1
        fi
        # Содержимое ACL смотрим в самом squashfs: unsquashfs -l даёт
        # только список файлов. Распаковываем один файл во временный
        # каталог (unsquashfs -cat не требует root).
        ACL_SRC=""
        if command -v unsquashfs >/dev/null 2>&1; then
          ACL_SRC="$(unsquashfs -cat "$R" "usr/share/rpcd/acl.d/luci-app-perenio.json" 2>/dev/null || true)"
        fi
        if [ -z "$ACL_SRC" ]; then
          ann error "build.sh: Perenio ACL" "Не удалось прочитать ACL из rootfs"
          echo "ОШИБКА: не удалось прочитать ACL luci-app-perenio из образа"
          exit 1
        fi
        if ! echo "$ACL_SRC" | grep -q '"/usr/libexec/perenio-diag"'; then
          ann error "build.sh: Perenio ACL" "В ACL нет scope file с путями"
          echo "ОШИБКА: ACL luci-app-perenio без раздела file (fs.read/fs.exec будут запрещены)"
          exit 1
        fi
        echo "  ACL страниц порта (scope file): OK"
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
