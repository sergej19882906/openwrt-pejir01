#!/bin/sh
# Тест системных команд Telegram-моста (/usr/libexec/pejir-sys).
#
# Проверяется поведение на подставных файлах:
#   1) signal  - разбор кеша модема (RSSI, CSQ, оператор, тип сети);
#   2) uptime  - время работы, load average, память;
#   3) battery - разбор ответа STM32 (уровень, напряжение, зарядка);
#   4) led     - вызов идёт в /usr/libexec/pejir-led;
#   5) wifi    - статус, включение/выключение отдельного SSID;
#   6) lte     - смена APN и перезапуск LTE;
#   7) web     - страница читается, HTML-теги вырезаются;
#   8) наличие файла и синтаксис shell.
#
# Тест обязан падать на старом коде (файла pejir-sys ещё нет).

set -u

if [ -n "${OW_TEST:-}" ]; then
	TREE="$OW_TEST"
else
	TREE="${PEJIR_OW_TEST:-/workspace/ow-test}"
	[ -d "$TREE" ] || { echo "FAIL: нет дерева $TREE (задайте OW_TEST)"; exit 1; }
fi

SYS="$TREE/package/pejir-telegram/root/usr/libexec/pejir-sys"
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$SYS" ] || { echo "FAIL: нет $SYS"; exit 1; }
[ -x "$SYS" ] && ok "helper: исполняемый" || fail "helper: не исполняемый"
sh -n "$SYS" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"

WORK="${PEJIR_TEST_WORK:-/tmp/pejir-test-tgsys}"
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/pejir-modem.json" <<'JSONEOF'
{"modem":[{"device":"/dev/ttyUSB2","cops":"25001,MCC MNC","mode":"LTE","csq_per":"99","rssi":"-77"}]}
JSONEOF

cat > "$WORK/pejir-battery" <<'BATEOF'
OK ChrgConn=1 ChrgType=3 ChrgStat=0 BatLev=95% VBat=4164 VBus=12200 VSys=4224 TBat=51
BATEOF

export PEJIR_SYS_MODEM_JSON="$WORK/pejir-modem.json"
export PEJIR_SYS_BATTERY="$WORK/pejir-battery"

# --- 1) signal --------------------------------------------------------------
out="$("$SYS" signal 2>/dev/null)"
printf '%s' "$out" | grep -q '\-77' && ok "signal: RSSI из кеша модема" \
	|| fail "signal: RSSI не показан ($out)"
printf '%s' "$out" | grep -qi 'LTE' && ok "signal: тип сети из кеша модема" \
	|| fail "signal: тип сети не показан ($out)"
printf '%s' "$out" | grep -q 'MCC MNC' && ok "signal: оператор из кеша модема" \
	|| fail "signal: оператор не показан ($out)"

# --- 2) uptime --------------------------------------------------------------
out="$("$SYS" uptime 2>/dev/null)"
printf '%s' "$out" | grep -qi 'время работы' && ok "uptime: время работы" \
	|| fail "uptime: время работы не показано ($out)"

# --- 3) battery -------------------------------------------------------------
out="$("$SYS" battery 2>/dev/null)"
printf '%s' "$out" | grep -q '95' && ok "battery: уровень заряда" \
	|| fail "battery: уровень не показан ($out)"
printf '%s' "$out" | grep -q '4164' && ok "battery: напряжение" \
	|| fail "battery: напряжение не показано ($out)"

# --- 4) led -----------------------------------------------------------------
cat > "$WORK/led" <<'LEDEOF'
#!/bin/sh
printf 'led %s\n' "$*" >> "${TG_SYS_LED_LOG:-/dev/null}"
exit 0
LEDEOF
chmod 0755 "$WORK/led"
export PEJIR_SYS_LED="$WORK/led"
export TG_SYS_LED_LOG="$WORK/led.log"

"$SYS" led status >/dev/null 2>&1
grep -q "led status" "$TG_SYS_LED_LOG" 2>/dev/null \
	&& ok "led: команда уходит в pejir-led" || fail "led: pejir-led не вызван"

# --- 5) wifi ----------------------------------------------------------------
cat > "$WORK/uci" <<'UCIEOF'
#!/bin/sh
printf 'uci %s\n' "$*" >> "${TG_SYS_UCI_LOG:-/dev/null}"
case "$1" in
	-q)
		case "$2" in
		show)
			printf "wireless.radio0=wifi-device\nwireless.radio0.disabled='0'\nwireless.@wifi[0]=wifi-iface\nwireless.@wifi[0].ssid='MyNet'\nwireless.@wifi[0].disabled='0'\n" 
			;;
		*) ;;
		esac
		;;
	get)
		case "$3" in
		*disabled) printf '0\n' ;;
		*) printf '\n' ;;
		esac
		;;
	esac
exit 0
UCIEOF
chmod 0755 "$WORK/uci"
export PEJIR_SYS_UCI="$WORK/uci"
export PEJIR_SYS_WIFI="$WORK/wifi-reload"
export PEJIR_SYS_WIRELESS="$WORK/wireless"
cat > "$WORK/wireless" <<'WCONFEOF'
config wifi-device 'radio0'
	option disabled '0'
config wifi-iface 'default_radio0'
	option ssid 'MyNet'
	option disabled '0'
WCONFEOF
cat > "$WORK/wifi-reload" <<'WEOF'
#!/bin/sh
printf 'reload\n' >> "${TG_SYS_WIFI_LOG:-/dev/null}"
exit 0
WEOF
chmod 0755 "$WORK/wifi-reload"
export TG_SYS_UCI_LOG="$WORK/uci.log"
export TG_SYS_WIFI_LOG="$WORK/wifi.log"

out="$("$SYS" wifi status 2>/dev/null)"
printf '%s' "$out" | grep -q 'MyNet' && ok "wifi status: виден SSID" \
	|| fail "wifi status: SSID не показан ($out)"

"$SYS" wifi ssid MyNet off >/dev/null 2>&1
grep -q "set wireless.@wifi\[0\].disabled=1" "$TG_SYS_UCI_LOG" 2>/dev/null \
	&& ok "wifi ssid off: интерфейс помечен отключённым" \
	|| fail "wifi ssid off: uci set не выполнен"

"$SYS" wifi radio radio0 off >/dev/null 2>&1
grep -q "set wireless.radio0.disabled=1" "$TG_SYS_UCI_LOG" 2>/dev/null \
	&& ok "wifi radio off: радио помечен отключённым" \
	|| fail "wifi radio off: uci set не выполнен"

# --- 6) lte -----------------------------------------------------------------
cat > "$WORK/lte-init" <<'LEOF'
#!/bin/sh
printf 'lte %s\n' "$*" >> "${TG_SYS_LTE_LOG:-/dev/null}"
exit 0
LEOF
chmod 0755 "$WORK/lte-init"
export PEJIR_SYS_LTE_INIT="$WORK/lte-init"
export TG_SYS_LTE_LOG="$WORK/lte.log"

"$SYS" lte apn internet >/dev/null 2>&1
grep -q "set network.lte.apn=internet" "$TG_SYS_UCI_LOG" 2>/dev/null \
	&& ok "lte apn: APN записан" || fail "lte apn: APN не записан"
grep -q "lte restart" "$TG_SYS_LTE_LOG" 2>/dev/null \
	&& ok "lte apn: LTE перезапущен" || fail "lte apn: LTE не перезапущен"

# --- 7) web -----------------------------------------------------------------
cat > "$WORK/wget" <<'WGETEOF'
#!/bin/sh
printf '<html><head><title>T</title></head><body><p>Привет</p></body></html>\n'
exit 0
WGETEOF
chmod 0755 "$WORK/wget"
export PEJIR_SYS_WGET="$WORK/wget"

out="$("$SYS" web https://example.com 2>/dev/null)"
printf '%s' "$out" | grep -q 'Привет' && ok "web: текст страницы получен" \
	|| fail "web: текст не получен ($out)"
printf '%s' "$out" | grep -q '<p>' && fail "web: HTML-теги не вырезаны" \
	|| ok "web: HTML-теги вырезаны"

echo "---"
if [ "$FAILED" -eq 0 ]; then
	echo "PASS: системные команды Telegram-моста"
	exit 0
fi
echo "FAIL: провалено проверок: $FAILED"
exit 1
