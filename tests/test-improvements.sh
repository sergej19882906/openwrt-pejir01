#!/bin/sh
# Тест улучшений релиза .59:
#   1) резервная копия настроек (sysupgrade -b) и скачивание из браузера;
#   2) LTE как резервный канал (mwan3);
#   3) отдельная страница «Zigbee»;
#   4) перезапуск Zigbee-модуля через STM32 (setpwr);
#   5) сохранение сырого ответа USSD;
#   6) версия залитой NCP-прошивки;
#   7) сокращённое ожидание модема при загрузке;
#   8) поиск, экспорт и шаблоны в SMS;
#   9) все поля STM32 на странице батареи.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	OW="$OW_TEST"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW"; exit 1; }
else
	OW="/workspace/ow-test"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST)"; exit 1; }
fi

LUCI="$OW/package/luci-app-perenio"
OTA="$OW/package/pejir-ota"
SMS="$OW/package/pejir-sms"
LTE="$OW/package/pejir-lte-base"
NCP="$OW/package/pejir-zigbee-ncp"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# --- 1) резервная копия настроек -----------------------------------------
OTA_HELPER="$OTA/files/pejir-ota"
OTA_PAGE="$OTA/htdocs/luci-static/resources/view/perenio/ota.js"
OTA_ACL="$OTA/root/usr/share/rpcd/acl.d/luci-app-pejir-ota.json"
if [ ! -f "$OTA_HELPER" ]; then
	fail "нет helper'а OTA ($OTA_HELPER)"
else
	if grep -q "cmd_backup" "$OTA_HELPER"; then
		ok "helper OTA умеет делать резервную копию"
	else
		fail "helper OTA не умеет делать резервную копию"
	fi
	if grep -q "sysupgrade -b" "$OTA_HELPER"; then
		ok "резервная копия делается через sysupgrade -b"
	else
		fail "в helper'е OTA нет sysupgrade -b"
	fi
	# Файл кладём в /www: uhttpd отдаёт его статически, поэтому браузер
	# скачивает архив целиком (через rpcd двоичный файл не передать).
	if grep -q "/www/pejir-backup" "$OTA_HELPER"; then
		ok "резервная копия кладётся в /www (её отдаёт uhttpd)"
	else
		fail "резервная копия не кладётся в /www"
	fi
fi
if [ -f "$OTA_PAGE" ]; then
	if grep -q "handleBackup" "$OTA_PAGE" && grep -q "'backup'" "$OTA_PAGE"; then
		ok "на странице прошивки есть кнопка резервной копии"
	else
		fail "на странице прошивки нет кнопки резервной копии"
	fi
	if grep -q "download" "$OTA_PAGE"; then
		ok "страница прошивки умеет отдать ссылку на скачивание"
	else
		fail "страница прошивки не умеет отдавать ссылку на скачивание"
	fi
else
	fail "нет страницы прошивки ($OTA_PAGE)"
fi

# --- 2) LTE как резервный канал (без mwan3) -------------------------------
#
# mwan3 убран из образа (релиз .63): в OpenWrt 25.12 он работает
# только через iptables и на старте со стоковым конфигом из образа
# навешивал "устаревшие правила iptables". Резервный канал WAN/LTE
# работает штатно: основной маршрут у network.wan, резервный (metric
# 30) у network.lte - этим управляет netifd.
MWAN3="$LTE/root/usr/libexec/pejir-mwan3"
if [ ! -f "$MWAN3" ]; then
	ok "helper pejir-mwan3 удалён из образа"
else
	fail "helper pejir-mwan3 всё ещё есть в пакете ($MWAN3)"
fi
if grep -q "pejir-mwan3" "$LTE/Makefile"; then
	fail "helper pejir-mwan3 всё ещё ставится в образ"
else
	ok "helper pejir-mwan3 не ставится в образ"
fi
if grep -q '"/usr/libexec/pejir-mwan3"' "$LUCI/root/usr/share/rpcd/acl.d/luci-app-perenio.json"; then
	fail "в ACL остался грант exec на pejir-mwan3"
else
	ok "в ACL нет гранта на pejir-mwan3"
fi
if grep -q "pejir-mwan3" "$LUCI/htdocs/luci-static/resources/view/perenio/lte.js"; then
	fail "страница LTE всё ещё вызывает pejir-mwan3"
else
	ok "страница LTE не вызывает pejir-mwan3"
fi
# Страница должна объяснять, как работает переключение на модем.
if grep -q "LTE as a backup link" "$LUCI/htdocs/luci-static/resources/view/perenio/lte.js"; then
	ok "на странице LTE есть справочный блок про резервный канал"
else
	fail "на странице LTE нет справочного блока про резервный канал"
fi
# Чистка остатков mwan3 из верхнего слоя - в скрипте чистки после
# sysupgrade: без неё старый /etc/config/mwan3 и init-скрипт пережили
# бы прошивку и mwan3 продолжал бы стартовать.
PURGE="$OTA/files/pejir-upgrade-purge"
if grep -q "mwan3" "$PURGE" 2>/dev/null; then
	ok "скрипт чистки после прошивки убирает остатки mwan3"
else
	fail "скрипт чистки после прошивки не убирает остатки mwan3"
fi
# Возврат маршрута по умолчанию: прежний helper ставил defaultroute=0,
# и без возврата интернет не пошёл бы через модем.
if grep -q 'defaultroute' "$PURGE" 2>/dev/null; then
	ok "скрипт чистки возвращает интерфейсам defaultroute"
else
	fail "скрипт чистки не возвращает интерфейсам defaultroute"
fi

# --- 3) страница Zigbee ---------------------------------------------------
ZB_PAGE="$LUCI/htdocs/luci-static/resources/view/perenio/zigbee.js"
if [ ! -f "$ZB_PAGE" ]; then
	fail "нет страницы Zigbee ($ZB_PAGE)"
else
	node --check "$ZB_PAGE" 2>/dev/null || fail "синтаксис страницы Zigbee"
	ok "страница Zigbee есть и синтаксически корректна"
	for pat in "pejir-zigbee-ncp" "homed-zigbee" "umxtty1"; do
		if grep -q "$pat" "$ZB_PAGE"; then
			ok "страница Zigbee упоминает $pat"
		else
			fail "страница Zigbee не упоминает $pat"
		fi
	done
fi
if grep -q '"perenio/zigbee"' "$LUCI/root/usr/share/luci/menu.d/luci-app-perenio.json"; then
	ok "в меню есть пункт страницы Zigbee"
else
	fail "в меню нет пункта страницы Zigbee"
fi

# --- 4) перезапуск модуля через STM32 -------------------------------------
if grep -q "setpwr zigbee=off" "$NCP/files/pejir-zigbee-ncp" && \
   grep -q "setpwr zigbee=on" "$NCP/files/pejir-zigbee-ncp"; then
	ok "обёртка перезапускает модуль через STM32 (setpwr zigbee=off/on)"
else
	fail "обёртка не перезапускает модуль через STM32"
fi

# --- 5) сырой ответ USSD --------------------------------------------------
USSD="$LUCI/root/usr/libexec/pejir-ussd"
if [ ! -f "$USSD" ]; then
	fail "нет helper'а USSD ($USSD)"
else
	if grep -q "pejir-ussd-raw" "$USSD"; then
		ok "helper USSD сохраняет сырой ответ модема"
	else
		fail "helper USSD не сохраняет сырой ответ модема"
	fi
	if grep -q "hexdump" "$USSD"; then
		ok "сырой ответ сохраняется в hex-виде"
	else
		fail "сырой ответ USSD сохраняется без hex-вида"
	fi
fi

# --- 6) версия NCP --------------------------------------------------------
if grep -q "ncp-version" "$NCP/files/pejir-zigbee-ncp"; then
	ok "обёртка запоминает версию залитой NCP-прошивки"
else
	fail "обёртка не запоминает версию NCP-прошивки"
fi
if grep -q "ncp-version" "$LUCI/root/usr/libexec/perenio-diag"; then
	ok "в диагностике показывается версия NCP"
else
	fail "в диагностике не показывается версия NCP"
fi

# --- 7) сокращённое ожидание модема --------------------------------------
LTE_INIT="$LTE/root/etc/init.d/47-pejir-lte"
if grep -q "at-port" "$LTE_INIT"; then
	ok "init-скрипт LTE использует уже проверенный порт (/etc/pejir/at-port)"
else
	fail "init-скрипт LTE не использует /etc/pejir/at-port - загрузка дольше"
fi

# --- 8) SMS: поиск, экспорт, шаблоны -------------------------------------
SMSCTL="$SMS/root/usr/libexec/pejir-sms-ctl"
if [ ! -f "$SMSCTL" ]; then
	fail "нет helper'а pejir-sms-ctl ($SMSCTL)"
else
	sh -n "$SMSCTL" 2>/dev/null || fail "синтаксис pejir-sms-ctl"
	if grep -q "pejir-sms-ctl" "$SMS/Makefile"; then
		ok "helper pejir-sms-ctl ставится в образ"
	else
		fail "helper pejir-sms-ctl не ставится в образ"
	fi
	if grep -q '"/usr/libexec/pejir-sms-ctl"' "$LUCI/root/usr/share/rpcd/acl.d/luci-app-perenio.json"; then
		ok "в ACL есть грант exec на pejir-sms-ctl"
	else
		fail "в ACL нет гранта на pejir-sms-ctl"
	fi
	# Поведение helper'а: экспорт и шаблоны на моке очереди.
	WORK="$(mktemp -d)"
	mkdir -p "$WORK/pool/incoming" "$WORK/pool/sent" "$WORK/www"
	printf '+79990000000\n2026-11-25 10:00:00\nПривет, это проверка\n' \
		> "$WORK/pool/incoming/msg1"
	printf '+79991111111\n2026-11-25 10:05:00\nОтвет\n' > "$WORK/pool/sent/msg2"
	out="$(PEJIR_SPOOL_POOL="$WORK/pool" PEJIR_SMS_WWW="$WORK/www" \
		PEJIR_SMS_TEMPLATES="$WORK/tpl" sh "$SMSCTL" export 2>&1)"
	if printf '%s' "$out" | grep -q "OK $WORK/www/sms-export"; then
		ok "экспорт SMS создаёт файл"
	else
		fail "экспорт SMS не создал файл: $out"
	fi
	if grep -q "Привет, это проверка" "$WORK"/www/sms-export-*.txt 2>/dev/null; then
		ok "в экспорте есть текст сообщения"
	else
		fail "в экспорте нет текста сообщения"
	fi
	if grep -q "+79990000000" "$WORK"/www/sms-export-*.txt 2>/dev/null; then
		ok "в экспорте есть номер отправителя"
	else
		fail "в экспорте нет номера отправителя"
	fi
	out="$(PEJIR_SMS_TEMPLATES="$WORK/tpl" sh "$SMSCTL" template-add "Проверка связи" 2>&1)"
	if printf '%s' "$out" | grep -q "OK"; then
		ok "шаблон добавляется"
	else
		fail "шаблон не добавился: $out"
	fi
	out="$(PEJIR_SMS_TEMPLATES="$WORK/tpl" sh "$SMSCTL" templates 2>&1)"
	if printf '%s' "$out" | grep -q "Проверка связи"; then
		ok "шаблоны показываются"
	else
		fail "шаблоны не показались: $out"
	fi
	out="$(PEJIR_SMS_TEMPLATES="$WORK/tpl" sh "$SMSCTL" template-del 1 2>&1)"
	if [ ! -s "$WORK/tpl" ]; then
		ok "шаблон удаляется"
	else
		fail "шаблон не удалился: $out"
	fi
	# Команда log: хвост журнала smsd (её зовёт страница SMS).
	# Журнал растёт без ограничения, поэтому helper отдаёт только хвост.
	printf 'строка1\nстрока2\nстрока3\nстрока4\n' > "$WORK/smsd.log"
	out="$(PEJIR_SMS_LOG="$WORK/smsd.log" sh "$SMSCTL" log 2 2>&1)"
	if [ "$(printf '%s\n' "$out" | wc -l)" = "2" ] && \
	   printf '%s' "$out" | grep -q 'строка4'; then
		ok "log отдаёт только хвост журнала"
	else
		fail "log отдаёт неверный хвост журнала: $out"
	fi
	out="$(PEJIR_SMS_LOG="$WORK/smsd.log" sh "$SMSCTL" log 2 2>&1)"
	if printf '%s' "$out" | grep -q 'строка1'; then
		fail "log отдаёт больше строк, чем просили"
	else
		ok "log уважает заданное число строк"
	fi
	out="$(PEJIR_SMS_LOG="$WORK/no-such.log" sh "$SMSCTL" log 8 2>&1)"
	if printf '%s' "$out" | grep -q 'не найден'; then
		ok "log сообщает, что журнала нет"
	else
		fail "log не сообщает об отсутствии журнала: $out"
	fi
	rm -rf "$WORK"
fi
SMS_PAGE="$LUCI/htdocs/luci-static/resources/view/perenio/sms.js"
if [ -f "$SMS_PAGE" ]; then
	for pat in "sms-filter" "sms-export" "sms-templates"; do
		if grep -q "$pat" "$SMS_PAGE"; then
			ok "на странице SMS есть $pat"
		else
			fail "на странице SMS нет $pat"
		fi
	done
else
	fail "нет страницы SMS"
fi

# --- 9) батарея: все поля STM32 ------------------------------------------
BATT_PAGE="$LUCI/htdocs/luci-static/resources/view/perenio/battery.js"
if [ ! -f "$BATT_PAGE" ]; then
	fail "нет страницы батареи"
else
	for pat in "batt-ichrg" "batt-vbus" "batt-vsys" "batt-temp" "batt-chg-info" "batt-present"; do
		if grep -q "$pat" "$BATT_PAGE"; then
			ok "на странице батареи есть поле $pat"
		else
			fail "на странице батареи нет поля $pat"
		fi
	done
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты улучшений пройдены"
exit 0
# --- 10) страница «Заводские данные»: кнопка загрузки ----------------------
# Внутри then() this равен undefined (строгий режим), поэтому this.refresh()
# в обработчике всегда падало: "Cannot read properties of undefined".
IDATA_JS="$LUCI/htdocs/luci-static/resources/view/perenio/idata.js"
if [ -f "$IDATA_JS" ]; then
	if grep -q "var self = this" "$IDATA_JS" && grep -q "self.refresh()" "$IDATA_JS"; then
		ok "idata.js: this сохранён до then() - кнопка загрузки работает"
	else
		fail "idata.js: this используется внутри then() - кнопка загрузки падает"
	fi
else
	fail "idata.js: файла нет"
fi

