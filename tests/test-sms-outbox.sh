#!/bin/sh
# Тест блока "Исходящие SMS" на странице SMS.
#
# Проблема, которую ловит тест:
#   Раньше страница показывала только ВХОДЯЩИЕ SMS (каталог
#   /var/spool/sms/incoming). Исходящие лежат в трёх каталогах:
#     /var/spool/sms/outgoing - в очереди на отправку,
#     /var/spool/sms/sent     - успешно отправленные,
#     /var/spool/sms/failed   - не отправленные (ошибка).
#   Чтобы страница их показывала, нужны:
#     1) в sms.js - чтение этих каталогов и три таблицы;
#     2) в ACL - права на list/read этих путей (иначе LuCI ответит
#        "Permission denied" - ровно как с диагностикой раньше);
#     3) в po/ru - переводы новых строк (иначе блок будет английским).
#
# Без ACL пути страница отдаст ошибку доступа, поэтому проверяем все
# три места сразу.

set -u

if [ -n "${OW_TEST:-}" ] && [ -d "$OW_TEST/package/luci-app-perenio" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
JS="$PKG/htdocs/luci-static/resources/view/perenio/sms.js"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
PO="$PKG/po/ru/luci-app-perenio.po"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$JS" "$ACL" "$PO"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) страница: каталоги и три списка ----------------------------------
for pat in "/var/spool/sms/outgoing" "/var/spool/sms/sent" "/var/spool/sms/failed"; do
	if grep -qF "$pat" "$JS"; then
		ok "sms.js: есть каталог $pat"
	else
		fail "sms.js: нет каталога $pat"
	fi
done

for id in "sms-out-list" "sms-sent-list" "sms-failed-list"; do
	if grep -qF "$id" "$JS"; then
		ok "sms.js: есть таблица $id"
	else
		fail "sms.js: нет таблицы $id"
	fi
done

if grep -q "readOutbox" "$JS" && grep -q "readOutbox()" "$JS"; then
	ok "sms.js: опрос страницы вызывает readOutbox()"
else
	fail "sms.js: опрос страницы не вызывает readOutbox() - блок не обновляется"
fi

if grep -q "readSpool" "$JS"; then
	ok "sms.js: чтение каталогов вынесено в readSpool()"
else
	fail "sms.js: нет общей функции readSpool()"
fi

# --- 2) ACL: права на чтение исходящих ------------------------------------
for p in "/var/spool/sms/outgoing" "/var/spool/sms/sent" "/var/spool/sms/failed"; do
	if grep -qF "\"$p\"" "$ACL"; then
		ok "ACL: есть доступ к $p"
	else
		fail "ACL: нет доступа к $p - LuCI отдаст Permission denied"
	fi
	if grep -qF "\"$p/*\"" "$ACL"; then
		ok "ACL: есть доступ к файлам $p/*"
	else
		fail "ACL: нет доступа к файлам $p/*"
	fi
done

# ACL должен оставаться валидным JSON
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ACL" 2>/dev/null; then
	ok "ACL: валидный JSON"
else
	fail "ACL: JSON невалиден"
fi

# --- 3) переводы новых строк ---------------------------------------------
for s in "Outgoing SMS" "Recipient" "Sent messages" "Failed messages"; do
	if grep -qF "msgid \"$s\"" "$PO"; then
		# msgstr должен быть непустым и не совпадать с msgid
		t=$(grep -A1 -F "msgid \"$s\"" "$PO" | sed -n 's/^msgstr "\(.*\)"$/\1/p' | head -1)
		if [ -n "$t" ] && [ "$t" != "$s" ]; then
			ok "po: есть перевод '$s' -> '$t'"
		else
			fail "po: строка '$s' есть, но перевод пуст или совпадает"
		fi
	else
		fail "po: нет строки '$s' - блок будет на английском"
	fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты блока 'Исходящие SMS' пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
