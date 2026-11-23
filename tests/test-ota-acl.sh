#!/bin/sh
# Тест прав доступа LuCI для страницы «Обновление прошивки (PEJIR01)».
#
# Ловит баг, из-за которого страница показывала «Доступ запрещён»:
#   грант на запуск помощника был выдан ТОЛЬКО через scope "ubus"
#   (ubus.file = exec), а rpcd дополнительно проверяет права по
#   КОНКРЕТНОМУ пути исполняемого файла. Без записи
#   write.file["/usr/bin/pejir-ota"] = ["exec"] вызов отклоняется.
#
# Для сравнения: в luci-app-perenio.json пути прописаны именно так
# (perenio-diag, pejir-ussd) - там страницы работают.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/pejir-ota"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/pejir-ota"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-pejir-ota.json"
PAGE="$PKG/htdocs/luci-static/resources/view/perenio/ota.js"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$ACL" "$PAGE"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) грант по пути ------------------------------------------------------
if python3 - "$ACL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = d.get('luci-app-pejir-ota', {})
paths = g.get('write', {}).get('file', {})
sys.exit(0 if 'exec' in paths.get('/usr/bin/pejir-ota', []) else 1)
PY
then
	ok "ACL: есть write.file['/usr/bin/pejir-ota'] = ['exec']"
else
	fail "ACL: нет гранта exec по пути /usr/bin/pejir-ota - LuCI отдаст 'Доступ запрещён'"
fi

# --- 2) ACL валиден и грант не потерялся -----------------------------------
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ACL" 2>/dev/null; then
	ok "ACL: валидный JSON"
else
	fail "ACL: JSON невалиден"
fi

if grep -q '"ubus"' "$ACL"; then
	ok "ACL: остался и общий грант ubus.file"
else
	fail "ACL: пропал общий грант ubus.file"
fi

# --- 3) страница вызывает именно этот helper ------------------------------
if grep -q "fs.exec('/usr/bin/pejir-ota'" "$PAGE"; then
	ok "страница OTA вызывает /usr/bin/pejir-ota"
else
	fail "страница OTA вызывает другой helper - сверь путь в ACL"
fi

# --- 4) helper существует в пакете -----------------------------------------
if [ -f "$PKG/files/pejir-ota" ]; then
	ok "helper /usr/bin/pejir-ota есть в пакете"
else
	fail "нет файла helper'а $PKG/files/pejir-ota"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты ACL страницы обновления пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
