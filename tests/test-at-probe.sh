#!/bin/sh
# Тест определения AT-порта: терминатор строки и ответ модема.
#
# Проблема, которую ловит тест:
#   На GM510 ответ зависит от символа конца строки. На "AT\n" (только LF)
#   модем НЕ отвечает, а на "AT\r" отвечает "OK". Проверено на устройстве:
#   6 минут проб "AT\n" - тишина; "AT+CSQ" - ответ "+CSQ: 17,99".
#
#   Прежняя проба в 40-pejir-sms и 47-pejir-lte была ровно "AT\n", поэтому:
#     * 40-pejir-sms не находил порт и не переписывал /etc/smsd.conf;
#     * 47-pejir-lte не находил порт, поэтому не вызывались ensure_lte_section
#       и sync_apn - APN не ставился, PDP-контекст не создавался, и LTE
#       оставался без передачи данных (интерфейс eth1 был, но трафика не
#       было).
#
#   Второй дефект того же класса: smsd (40-pejir-sms, START=92) держит
#   AT-порт открытым и забирает ответы модема себе. 47-pejir-lte стартует
#   позже (START=94) и потому не мог прочитать ответ - он обязан на время
#   AT-обмена остановить smsd, а потом запустить обратно.

set -u

OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
LTE="${LTE:-$OW/package/pejir-lte-base/root/etc/init.d/47-pejir-lte}"
SMS="${SMS:-$OW/package/pejir-sms/root/etc/init.d/40-pejir-sms}"

FAILED=0
ok()   { printf 'OK: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=$((FAILED+1)); }

for f in "$LTE" "$SMS"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) в скриптах нет голой пробы "AT\n" как единственной ------------------
for f in "$LTE" "$SMS"; do
	# в исполняемых строках не должно остаться printf 'AT\n' как пробы
	if grep -vE '^[[:space:]]*#' "$f" | grep -q "printf 'AT\\\\n'"; then
		fail "$(basename "$f"): проба осталась на 'AT\n' - GM510 на LF не отвечает"
	else
		ok "$(basename "$f"): пробы 'AT\\n' не осталось"
	fi
done

# --- 2) есть проба AT\r и запасная AT+CSQ ----------------------------------
for f in "$LTE" "$SMS"; do
	if grep -F 'AT\r' "$f" >/dev/null 2>&1; then
		ok "$(basename "$f"): есть проба AT\\r (как в mdm-at)"
	else
		fail "$(basename "$f"): нет пробы AT\\r"
	fi
	if grep -F 'AT+CSQ' "$f" >/dev/null 2>&1; then
		ok "$(basename "$f"): есть запасная проба AT+CSQ"
	else
		fail "$(basename "$f"): нет запасной пробы AT+CSQ"
	fi
done

# --- 3) 47-pejir-lte отпускает AT-порт у smsd на время обмена -------------
if grep -q 'smsd_pause_for_at' "$LTE" && grep -q 'smsd_resume_after_at' "$LTE"; then
	ok "47-pejir-lte останавливает smsd на время AT-обмена"
else
	fail "47-pejir-lte не отпускает AT-порт у smsd - ответы модема будут съедены"
fi

# --- 4) функциональная проверка: модем отвечает только на AT\r ------------
WORK="$(mktemp -d /tmp/pejir-at-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin"

cat > "$WORK/bin/stty" <<'STTY_EOF'
#!/bin/sh
exit 0
STTY_EOF

cat > "$WORK/bin/atinout" <<'ATINOUT_EOF'
#!/bin/sh
# Мок модема GM510:
#   * на команду с '+' (AT+CSQ) отвечает всегда;
#   * на "AT\r" отвечает "OK";
#   * на "AT\n" (только LF) - МОЛЧИТ (так ведёт себя настоящий GM510).
in="$1"
data="$(cat "$in" 2>/dev/null)"
CR="$(printf '\r')"
case "$data" in
	*+*)
		printf '\r\n+CSQ: 17,99\r\n\r\nOK\r\n'
		exit 0
		;;
esac
case "$data" in
	*"$CR"*) printf '\r\nOK\r\n' ;;
	*) : ;;
esac
exit 0
ATINOUT_EOF
chmod +x "$WORK/bin/stty" "$WORK/bin/atinout"

: > "$WORK/ttyUSB2"
: > "$WORK/ttyUSB1"
: > "$WORK/ttyUSB0"

# Достаём функции из init-скриптов и подставляем пути тестовых портов.
extract_fn() {
	# $1 - файл, $2 - имя функции
	sed -n "/^$2()/,/^}/p" "$1"
}

prepare() {
	# $1 - исходный скрипт, $2 - пригодный для запуска
	sed "s#/dev/ttyUSB#$WORK/ttyUSB#g; s#/dev/ttyACM#$WORK/ttyACM#g; \
	     s#\[ -c \"\\\$p\" \]#[ -e \"\$p\" ]#g" "$1" > "$2"
}

run_probe() {
	# $1 - пригодная копия скрипта (с путями тестовых портов!)
	{
		printf '%s\n' 'set -u' 'AT_TIMEOUT=5' 'AT_BAUD=115200'
		extract_fn "$1" set_port_speed
		extract_fn "$1" at_ask
		extract_fn "$1" at_port_candidates
		extract_fn "$1" detect_at_port
		printf '%s\n' 'detect_at_port'
	} > "$WORK/probe.sh"
	PATH="$WORK/bin:$PATH" sh "$WORK/probe.sh" 2>/dev/null
}

prepare "$SMS" "$WORK/sms"
out="$(run_probe "$WORK/sms")"
if [ "$out" = "$WORK/ttyUSB2" ]; then
	ok "40-pejir-sms находит AT-порт (модем отвечает только на AT\\r)"
else
	fail "40-pejir-sms вернул '$out' (ожидался $WORK/ttyUSB2) - порт не найден"
fi

prepare "$LTE" "$WORK/lte"
out="$(run_probe "$WORK/lte")"
if [ "$out" = "$WORK/ttyUSB2" ]; then
	ok "47-pejir-lte находит AT-порт (модем отвечает только на AT\\r)"
else
	fail "47-pejir-lte вернул '$out' (ожидался $WORK/ttyUSB2) - порт не найден"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты определения AT-порта пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
