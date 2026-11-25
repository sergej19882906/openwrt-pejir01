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

# --- 2) LTE как резервный канал (mwan3) ----------------------------------
MWAN3="$LTE/root/usr/libexec/pejir-mwan3"
if [ ! -f "$MWAN3" ]; then
	fail "нет helper'а pejir-mwan3 ($MWAN3)"
else
	sh -n "$MWAN3" 2>/dev/null || fail "синтаксис pejir-mwan3"
	if grep -q "pejir-mwan3" "$LTE/Makefile"; then
		ok "helper pejir-mwan3 ставится в образ"
	else
		fail "helper pejir-mwan3 не ставится в образ"
	fi
	if grep -q "mwan3" "$MWAN3" && grep -q "lte_backup" "$MWAN3"; then
		ok "pejir-mwan3 настраивает LTE как резервный участник"
	else
		fail "pejir-mwan3 не настраивает LTE как резервный участник"
	fi
	# Интерфейсы mwan3 не должны ставить свой маршрут по умолчанию:
	# иначе netifd и mwan3 спорят за default route. И remove должен
	# возвращать это право, иначе роутер останется без интернета.
	if grep -q 'network.\$i.defaultroute=0' "$MWAN3"; then
		ok "pejir-mwan3: интерфейсам отдан маршрут по умолчанию (defaultroute=0)"
	else
		fail "pejir-mwan3: не отключает свой default route у интерфейсов mwan3"
	fi
	if grep -q 'delete "network.\$i.defaultroute"' "$MWAN3"; then
		ok "pejir-mwan3: remove возвращает маршрут по умолчанию"
	else
		fail "pejir-mwan3: remove не возвращает default route - роутер останется без интернета"
	fi
	# Настройка должна быть ОПЦИОНАЛЬНОЙ: молча менять маршрутизацию нельзя.
	if grep -q "cmd_setup" "$MWAN3" && grep -q "cmd_remove" "$MWAN3"; then
		ok "настройка mwan3 включается и выключается по явной команде"
	else
		fail "у pejir-mwan3 нет команд setup/remove"
	fi
fi
if grep -q '"/usr/libexec/pejir-mwan3"' "$LUCI/root/usr/share/rpcd/acl.d/luci-app-perenio.json"; then
	ok "в ACL есть грант exec на pejir-mwan3"
else
	fail "в ACL нет гранта на pejir-mwan3"
fi
if grep -q "pejir-mwan3" "$LUCI/htdocs/luci-static/resources/view/perenio/lte.js"; then
	ok "на странице LTE есть блок резервного канала"
else
	fail "на странице LTE нет блока резервного канала"
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

