#!/bin/sh
# Тест индикаторов в шапке веб-интерфейса: значок батареи и значок
# сети (LTE/3G) рядом с ним - как в стоковой прошивке Perenio.
#
# Что проверяется:
#   1) все файлы индикаторов на месте (в т.ч. в resources/preload/ -
#      LuCI подключает их сам на каждой странице);
#   2) индикаторы вставляются в штатный блок #indicators и имеют
#      собственные data-indicator;
#   3) в ACL есть чтение файла состояния сети;
#   4) демон pejir-signal разбирает ответы модема (CSQ/NWINFO/COPS)
#      и пишет файл состояния; при занятой очереди SMS не лезет в порт;
#   5) новые строки переведены.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"
RES="$LUCI_PKG/htdocs/luci-static/resources"
LTE_PKG="${PEJIR_LTE_PKG:-${OW_TEST:-/workspace/ow-test}/package/pejir-lte-base}"
SIGNAL="$LTE_PKG/root/usr/libexec/pejir-signal"
SIGNAL_INIT="$LTE_PKG/root/etc/init.d/46-pejir-signal"
PO="$LUCI_PKG/po/ru/luci-app-perenio.po"
ACL="$LUCI_PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# --- 1) файлы на месте ------------------------------------------------------
for f in "$RES/perenio-battery.js" "$RES/battery-indicator.js" "$RES/lte-indicator.js" \
         "$RES/preload/battery-indicator.js" "$RES/preload/lte-indicator.js"; do
	if [ -f "$f" ]; then
		ok "файл есть: ${f#$RES/}"
	else
		fail "нет файла: $f"
	fi
done

for f in "$SIGNAL" "$SIGNAL_INIT"; do
	if [ -f "$f" ]; then
		ok "файл есть: $f"
	else
		fail "нет файла: $f"
	fi
done

if [ -x "$SIGNAL" ]; then
	ok "pejir-signal исполняемый"
else
	fail "pejir-signal не исполняемый"
fi

# --- 2) индикаторы в #indicators ---------------------------------------------
for m in battery-indicator lte-indicator; do
	if grep -q "getElementById('indicators')" "$RES/$m.js"; then
		ok "$m.js вставляет индикатор в #indicators"
	else
		fail "$m.js не использует #indicators"
	fi
done

if grep -q 'data-indicator="battery-status"' "$RES/battery-indicator.js"; then
	ok "у индикатора батареи свой data-indicator"
else
	fail "у индикатора батареи нет data-indicator"
fi

if grep -q 'data-indicator="lte-status"' "$RES/lte-indicator.js"; then
	ok "у индикатора сети свой data-indicator"
else
	fail "у индикатора сети нет data-indicator"
fi

# Индикатор батареи обязан брать иконку из общей папки со стоковыми иконками
if grep -q "perenio/images/battery" "$RES/perenio-battery.js"; then
	ok "иконки батареи - стоковые (perenio/images/battery)"
else
	fail "не найден путь к стоковым иконкам батареи"
fi

# --- 3) ACL ------------------------------------------------------------------
if [ -f "$ACL" ] && grep -q '"/tmp/pejir-signal"' "$ACL"; then
	ok "в ACL есть чтение файла состояния сети"
else
	fail "в ACL нет /tmp/pejir-signal"
fi

# --- 3a) браузер не запускает процессы на каждый опрос -----------------------
# Значки читают файлы состояния, которые пишет демон. Если бы браузер
# запускал "/usr/bin/mcu getsys" каждые 15 секунд, rpcd поднимал бы
# процесс на каждый опрос - веб-интерфейс от этого подтормаживал.
if grep -q "fs.read" "$RES/battery-indicator.js"; then
	ok "значок батареи читает файл состояния"
else
	fail "значок батареи не читает файл состояния"
fi
if grep -q "fs.exec" "$RES/battery-indicator.js"; then
	fail "значок батареи запускает процесс из браузера (fs.exec) - интерфейс будет подтормаживать"
else
	ok "значок батареи не запускает процессы из браузера"
fi
if grep -q "fs.exec" "$RES/lte-indicator.js"; then
	fail "значок сети запускает процесс из браузера (fs.exec)"
else
	ok "значок сети не запускает процессы из браузера"
fi
if grep -q "refresh_battery" "$SIGNAL"; then
	ok "демон собирает состояние батареи"
else
	fail "демон не собирает состояние батареи"
fi
if grep -q '"/tmp/pejir-battery"' "$ACL"; then
	ok "в ACL есть чтение файла состояния батареи"
else
	fail "в ACL нет /tmp/pejir-battery"
fi

# --- 4) разбор ответов модема ------------------------------------------------
if [ -f "$SIGNAL" ]; then
	WORK="$(mktemp -d)"
	mkdir -p "$WORK/bin" "$WORK/empty-outbox"
	printf '/dev/ttyUSB2\n' > "$WORK/at-port"

	cat > "$WORK/bin/mdm-at" <<'STUB'
#!/bin/sh
case "$1" in
"AT+CSQ")    echo "+CSQ: 21,99" ;;
"AT+NWINFO") echo "+NWINFO: LTE,FDD,2100,3,5,-95,20,-70,30,7" ;;
"AT+COPS?")  echo '+COPS: 0,0,"MegaFon",2' ;;
*)           echo "OK" ;;
esac
STUB
	chmod 755 "$WORK/bin/mdm-at"

	PATH="$WORK/bin:$PATH" \
	PEJIR_AT_PORT_FILE="$WORK/at-port" \
	PEJIR_SIGNAL_STATE="$WORK/state" \
	PEJIR_SMS_OUTBOX="$WORK/empty-outbox" \
	PEJIR_SIGNAL_LOCK="$WORK/lock" \
		"$SIGNAL" refresh >/dev/null 2>&1

	if [ -f "$WORK/state" ]; then
		ok "файл состояния создан"

		val() { sed -n "s/^$1=//p" "$WORK/state" | head -1; }

		[ "$(val rssi)" = "21" ] && ok "rssi=21 разобран" || fail "rssi разобран неверно: $(val rssi)"
		[ "$(val pct)" = "68" ] && ok "процент сигнала=68" || fail "процент сигнала неверно: $(val pct)"
		[ "$(val net)" = "LTE" ] && ok "тип сети=LTE" || fail "тип сети неверно: $(val net)"
		[ "$(val operator)" = "MegaFon" ] && ok "оператор=MegaFon" || fail "оператор неверно: $(val operator)"
	else
		fail "файл состояния не создан"
	fi

	# 3G вместо LTE
	rm -f "$WORK/state"
	cat > "$WORK/bin/mdm-at" <<'STUB'
#!/bin/sh
case "$1" in
"AT+CSQ")    echo "+CSQ: 9,99" ;;
"AT+NWINFO") echo "+NWINFO: UMTS" ;;
"AT+COPS?")  echo '+COPS: 0,0,"Beeline",3' ;;
*)           echo "OK" ;;
esac
STUB
	chmod 755 "$WORK/bin/mdm-at"

	PATH="$WORK/bin:$PATH" \
	PEJIR_AT_PORT_FILE="$WORK/at-port" \
	PEJIR_SIGNAL_STATE="$WORK/state" \
	PEJIR_SMS_OUTBOX="$WORK/empty-outbox" \
	PEJIR_SIGNAL_LOCK="$WORK/lock" \
		"$SIGNAL" refresh >/dev/null 2>&1

	if [ -f "$WORK/state" ]; then
		net="$(sed -n 's/^net=//p' "$WORK/state" | head -1)"
		op="$(sed -n 's/^operator=//p' "$WORK/state" | head -1)"
		[ "$net" = "3G" ] && ok "тип сети=3G" || fail "тип сети неверно: $net"
		[ "$op" = "Beeline" ] && ok "оператор=Beeline" || fail "оператор неверно: $op"
	else
		fail "файл состояния не создан (3G)"
	fi

	# Модем без AT+NWINFO (модули Gosuncn/Meig): тип сети берётся из
	# кода активности в AT+COPS?.
	rm -f "$WORK/state"
	cat > "$WORK/bin/mdm-at" <<'STUB'
#!/bin/sh
case "$1" in
"AT+CSQ")    echo "+CSQ: 18,99" ;;
"AT+NWINFO") echo "ERROR" ;;
"AT+COPS?")  echo '+COPS: 0,0,"A1 BY",2' ;;
*)           echo "OK" ;;
esac
STUB
	chmod 755 "$WORK/bin/mdm-at"

	PATH="$WORK/bin:$PATH" \
	PEJIR_AT_PORT_FILE="$WORK/at-port" \
	PEJIR_SIGNAL_STATE="$WORK/state" \
	PEJIR_SMS_OUTBOX="$WORK/empty-outbox" \
	PEJIR_SIGNAL_LOCK="$WORK/lock" \
		"$SIGNAL" refresh >/dev/null 2>&1

	if [ -f "$WORK/state" ]; then
		net="$(sed -n 's/^net=//p' "$WORK/state" | head -1)"
		op="$(sed -n 's/^operator=//p' "$WORK/state" | head -1)"
		pct="$(sed -n 's/^pct=//p' "$WORK/state" | head -1)"
		[ "$net" = "LTE" ] && ok "без AT+NWINFO тип сети взят из COPS: LTE" || fail "тип сети без NWINFO неверно: $net"
		[ "$op" = "A1 BY" ] && ok "без AT+NWINFO оператор разобран: A1 BY" || fail "оператор без NWINFO неверно: $op"
		[ "$pct" = "58" ] && ok "процент сигнала без NWINFO: 58" || fail "процент сигнала неверно: $pct"
	else
		fail "файл состояния не создан (без NWINFO)"
	fi

	# Если в очереди SMS есть исходящие - в порт не лезем
	rm -f "$WORK/state"
	mkdir -p "$WORK/outbox"
	: > "$WORK/outbox/1.SMS"

	PATH="$WORK/bin:$PATH" \
	PEJIR_AT_PORT_FILE="$WORK/at-port" \
	PEJIR_SIGNAL_STATE="$WORK/state" \
	PEJIR_SMS_OUTBOX="$WORK/outbox" \
	PEJIR_SIGNAL_LOCK="$WORK/lock" \
		"$SIGNAL" refresh >/dev/null 2>&1

	if [ ! -f "$WORK/state" ]; then
		ok "при занятой очереди SMS модем не опрашивается"
	else
		fail "модем опрошен, хотя очередь SMS не пуста"
	fi

	rm -rf "$WORK"
fi

# --- 5) переводы -------------------------------------------------------------
for m in "Network type" "Operator" "Signal level"; do
	if grep -qF "msgid \"$m\"" "$PO" && grep -A1 -F "msgid \"$m\"" "$PO" | grep -q 'msgstr "[^"]' ; then
		ok "перевод есть: $m"
	else
		fail "нет перевода для: $m"
	fi
done

# --- 6) синтаксис JS ---------------------------------------------------------
if command -v node >/dev/null 2>&1; then
	for m in perenio-battery battery-indicator lte-indicator; do
		if node --check "$RES/$m.js" >/dev/null 2>&1; then
			ok "синтаксис OK: $m.js"
		else
			fail "синтаксис сломан: $m.js"
		fi
	done
else
	echo "ПРОПУСК: нет node - синтаксис JS не проверен"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты индикаторов пройдены"
