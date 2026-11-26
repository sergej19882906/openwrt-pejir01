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

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
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

# Патч 0109: три списка объединены в одну переписку (пузыри), поэтому
# отдельных таблиц sms-out-list/sms-sent-list/sms-failed-list больше
# нет - проверяем, что все три категории попадают в общий список.
for dir in "queued" "out" "err"; do
	if grep -q "dir == '$dir'" "$JS" || grep -q "dir: '$dir'" "$JS" \
		|| grep -q "'$dir'" "$JS"; then
		ok "sms.js: категория '$dir' учитывается в переписке"
	else
		fail "sms.js: категория '$dir' не учитывается - сообщения пропадут из вида"
	fi
done

if grep -q "sms-chat" "$JS"; then
	ok "sms.js: есть общий контейнер переписки sms-chat"
else
	fail "sms.js: нет контейнера sms-chat"
fi

for id in "sms-tab-all" "sms-tab-inbox" "sms-tab-out" "sms-tab-failed"; do
	if grep -qF "$id" "$JS"; then
		ok "sms.js: есть счётчик вкладки $id"
	else
		fail "sms.js: нет счётчика вкладки $id"
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

# --- 1b) ACL: права по РАЗЫМЕНОВАННОМУ пути (/tmp/...) ----------------------
# rpcd сверяет права доступа к файлу не по текстовому пути, а по
# разыменованному (rpcd/file.c: rpc_check_symlink_access -> realpath()).
# В OpenWrt /var - симлинк на /tmp, поэтому реальные пути очереди и
# журнала - /tmp/spool/sms/... и /tmp/log/smsd.log. Без грантов на них
# LuCI не видела ни входящих, ни исходящих сообщений.
for p in "/tmp/spool/sms/incoming" "/tmp/spool/sms/outgoing" \
	 "/tmp/spool/sms/sent" "/tmp/spool/sms/failed"; do
	if grep -qF "\"$p\"" "$ACL"; then
		ok "ACL: есть доступ к $p (реальный путь)"
	else
		fail "ACL: нет доступа к $p - LuCI отдаст Permission denied"
	fi
	if grep -qF "\"$p/*\"" "$ACL"; then
		ok "ACL: есть доступ к файлам $p/* (реальный путь)"
	else
		fail "ACL: нет доступа к файлам $p/* (реальный путь)"
	fi
done
for p in "/tmp/log/smsd.log" "/tmp/log/smsd.log.1"; do
	if grep -qF "\"$p\"" "$ACL"; then
		ok "ACL: есть доступ к журналу $p (реальный путь)"
	else
		fail "ACL: нет доступа к журналу $p (реальный путь)"
	fi
done

# Журнал читает helper, а не браузер: файл растёт без ограничения
# (loglevel 5), и LuCI тянул его целиком при каждом опросе страницы
# (раз в 20 с) - страница заметно подтормаживала.
if grep -q "SMSCTL, \[ 'log'" "$JS" || grep -q "SMSCTL, \['log'" "$JS"; then
	ok "sms.js: журнал читается через helper (pejir-sms-ctl log)"
else
	fail "sms.js: журнал читается не через helper - страница будет подтормаживать"
fi
if grep -q "fs.read(LOG)" "$JS"; then
	fail "sms.js: журнал всё ещё читается браузером (fs.read)"
else
	ok "sms.js: браузер не тянет журнал целиком"
fi

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

# --- 4) вкладки, тема Argon и сохранение настроек моста ------------------
# Вкладка "Все сообщения" должна быть такой же кнопкой, как остальные:
# раньше у неё не было обработчика, и после перехода на другую вкладку
# вернуться было нельзя.
if grep -q "tabBtn('all'" "$JS"; then
	ok "sms.js: вкладка 'Все сообщения' сделана кнопкой (есть обработчик)"
else
	fail "sms.js: вкладка 'Все сообщения' без обработчика - вернуться нельзя"
fi

# Страница должна следовать за темой Argon (светлая/тёмная): цвета
# берём из переменных темы, а не задаём свои.
CSS="$PKG/htdocs/luci-static/resources/view/perenio/sms.css"
if [ -f "$CSS" ]; then
	for v in "var(--primary" "var(--surface-color" "var(--text-color" "var(--border-color" "var(--input-bg"; do
		if grep -q -- "$v" "$CSS"; then
			ok "sms.css: используется переменная темы $v"
		else
			fail "sms.css: нет переменной темы $v - страница не сменит тему"
		fi
	done
else
	fail "sms.css: файла нет"
fi

# Настройки моста Telegram: конфиг надо загрузить, иначе LuCI молча
# игнорирует uci.set() и apply падает с "данные не получены".
if grep -q "uci.load('pejir_telegram')" "$JS"; then
	ok "sms.js: конфиг моста загружается перед сохранением"
else
	fail "sms.js: нет uci.load('pejir_telegram') - сохранение не сработает"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты блока 'Исходящие SMS' пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
