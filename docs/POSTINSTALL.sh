#!/bin/sh
# ============================================================
# Perenio PEJIR01 / OpenWrt 25.12.6 — пост-установка
# Запускать НА РОУТЕРЕ:  sh POSTINSTALL.sh
# Скрипт делает ОДНО: переносит overlay (/overlay) на USB-флешку (extroot).
# Нужна USB-флешка (ext4 будет создана, данные сотрутся!)
# ============================================================
#
# ВАЖНО про обновления:
#   * extroot — это и есть /overlay. При sysupgrade БЕЗ галочки
#     «Сохранить настройки» overlay затирается, и вместе с ним теряется
#     fstab: флешка перестаёт монтироваться, а настройки, созданные
#     вручную, приходится делать заново.
#   * С галочкой «Сохранить настройки» конфиг переносится, extroot
#     перемонтируется и данные на флешке сохраняются.
#   * То же касается OTA-кнопки в LuCI (Система → Firmware update):
#     sysupgrade по умолчанию сохраняет настройки, так что extroot
#     переживает обновление. Если в /etc/config/pejir_ota выставлено
#     keep_settings=0 — не переживёт.
# ============================================================
set -e

echo "== 1. Extroot: перенос overlay на USB =="
DEV=""
for d in /dev/sda /dev/sdb; do
  [ -b "$d" ] && DEV="$d" && break
done
[ -z "$DEV" ] && { echo "USB-диск не найден"; exit 1; }
echo "Использую $DEV — ВСЕ ДАННЫЕ БУДУТ СТЁРТЫ через 10 сек"
sleep 10

apk add --no-cache block-mount e2fsprogs || true
mkfs.ext4 -F -L extroot "$DEV"1

block detect > /etc/config/fstab
# первый mount = наш диск: целевой /overlay (extroot)
uci set fstab.@mount[0].target='/overlay'
uci set fstab.@mount[0].enabled='1'
uci set fstab.@mount[0].fstype='ext4'
uci commit fstab
echo "Extroot настроен. Перезагрузка обязательна: reboot"
echo "После ребута: df -h /overlay -> должен показать размер флешки"
exit 0
