#!/bin/sh
# Тест: восстановление настроек из файла на компьютере (страница OTA).
#
# Что проверяем:
#   * страница "Обновление прошивки (PEJIR01)" умеет принимать файл
#     резервной копии с компьютера, проверять его и восстанавливать
#     настройки (sysupgrade --restore-backup) с перезагрузкой;
#   * ACL разрешает загрузку файла (cgi-io upload), запись в
#     /tmp/backup.tar.gz и запуск нужных команд;
#   * новые строки есть в русском переводе.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева OpenWrt $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева OpenWrt $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

OTA_JS="$DEFAULT_TREE/package/pejir-ota/htdocs/luci-static/resources/view/perenio/ota.js"
OTA_ACL="$DEFAULT_TREE/package/pejir-ota/root/usr/share/rpcd/acl.d/luci-app-pejir-ota.json"
OTA_PO="$DEFAULT_TREE/package/pejir-ota/po/ru/luci-app-pejir-ota.po"

for f in "$OTA_JS" "$OTA_ACL" "$OTA_PO"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. Страница -----------------------------------------------------------
grep -q "handleRestore" "$OTA_JS" && ok "на странице есть обработчик восстановления" \
	|| fail "на странице нет обработчика восстановления"
grep -q "cgi-upload" "$OTA_JS" && ok "файл загружается на роутер через cgi-upload" \
	|| fail "файл не загружается (нет cgi-upload)"
grep -q "'/tmp/backup.tar.gz'" "$OTA_JS" && ok "файл кладут в /tmp/backup.tar.gz" \
	|| fail "файл сохраняется не в /tmp/backup.tar.gz"
grep -q "'-tzf'" "$OTA_JS" && ok "архив проверяется (tar -tzf)" \
	|| fail "архив не проверяется перед восстановлением"
grep -q "'--restore-backup'" "$OTA_JS" && ok "настройки восстанавливаются (sysupgrade --restore-backup)" \
	|| fail "нет восстановления настроек (sysupgrade --restore-backup)"
grep -q "'/sbin/reboot'" "$OTA_JS" && ok "после восстановления роутер перезагружается" \
	|| fail "нет перезагрузки после восстановления"
grep -q "pejir-ota-restore-file" "$OTA_JS" && ok "на странице есть выбор файла" \
	|| fail "нет поля выбора файла"

# --- 2. ACL ----------------------------------------------------------------
grep -q '"cgi-io"' "$OTA_ACL" && ok "ACL разрешает загрузку файла (cgi-io)" \
	|| fail "ACL не разрешает загрузку файла - восстановление не заработает"
grep -q '"upload"' "$OTA_ACL" && ok "ACL разрешает операцию upload" \
	|| fail "ACL не разрешает операцию upload"
grep -q '"/tmp/backup.tar.gz"' "$OTA_ACL" && ok "ACL разрешает запись файла /tmp/backup.tar.gz" \
	|| fail "ACL не разрешает запись файла бэкапа"
grep -q '/bin/tar -tzf /tmp/backup.tar.gz' "$OTA_ACL" && ok "ACL разрешает проверку архива" \
	|| fail "ACL не разрешает проверку архива"
grep -q '/sbin/sysupgrade --restore-backup /tmp/backup.tar.gz' "$OTA_ACL" && ok "ACL разрешает восстановление настроек" \
	|| fail "ACL не разрешает sysupgrade --restore-backup"
grep -q '"/sbin/reboot"' "$OTA_ACL" && ok "ACL разрешает перезагрузку" \
	|| fail "ACL не разрешает перезагрузку"

# --- 3. Перевод ------------------------------------------------------------
for s in "Restore settings from a file" "Restore settings" "Uploading the file..." \
	"Restoring the settings..." "Settings restored, rebooting..."; do
	grep -q "msgid \"$s\"" "$OTA_PO" && ok "есть перевод: $s" \
		|| fail "нет перевода: $s"
done

echo
if [ "$FAILED" -eq 0 ]; then
	echo "ИТОГ: все проверки пройдены"
	exit 0
fi
echo "ИТОГ: провалено проверок: $FAILED"
exit 1
