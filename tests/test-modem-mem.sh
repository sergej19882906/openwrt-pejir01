#!/bin/sh
# Тест helper'а очистки памяти модема (SIM) для SMS.
#
# Зачем он нужен. Модем принимает входящие SMS в память SIM
# (smsd.conf: init = AT+CPMS="SM","SM","SM"). Если память забита, модем
# не может принять новое сообщение: в журнале smsd каждые 33 секунды
# появляется "Message 0, not enough storage space.", а входящие SMS не
# доходят до роутера.
#
# Проверяется:
#   1) helper есть, ставится в образ, есть грант ACL;
#   2) status разбирает ответ AT+CPMS? (сколько занято / сколько всего);
#   3) clean удаляет сообщения (уходит AT+CMGD=1,4) и показывает
#      состояние памяти до и после;
#   4) на странице SMS есть кнопка очистки.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"

LTE="$TREE/package/pejir-lte-base"
LUCI="$TREE/package/luci-app-perenio"
HELPER="$LTE/root/usr/libexec/pejir-modem-sms-clean"
ACL="$LUCI/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
PAGE="$LUCI/htdocs/luci-static/resources/view/perenio/sms.js"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$HELPER" "$ACL" "$PAGE"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done
sh -n "$HELPER" 2>/dev/null || { echo "FAIL: синтаксис helper"; exit 1; }
ok "helper на месте, синтаксис в порядке"

if grep -q "pejir-modem-sms-clean" "$LTE/Makefile"; then
	ok "helper ставится в образ"
else
	fail "helper не ставится в образ"
fi
if grep -qF '"/usr/libexec/pejir-modem-sms-clean"' "$ACL"; then
	ok "в ACL есть грант exec на helper"
else
	fail "в ACL нет гранта exec на helper"
fi
if grep -q "pejir-modem-sms-clean" "$PAGE"; then
	ok "на странице SMS есть кнопка очистки памяти модема"
else
	fail "на странице SMS нет кнопки очистки памяти модема"
fi

# --- поведение helper'а на моке mdm-at ------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/bin"
cat > "$WORK/bin/mdm-at" <<'EOF'
#!/bin/sh
# Мок mdm-at: на AT+CPMS? отвечает "+CPMS: 12,30", на AT+CMGD - OK.
case "$1" in
*CPMS*) echo "+CPMS: 12,30,12,30,12,30" ;;
*CMGD*) echo "OK" ;;
*)     echo "OK" ;;
esac
echo "$1" >> /tmp/modem-sms-clean-test.calls
EOF
chmod 755 "$WORK/bin/mdm-at"
export PATH="$WORK/bin:$PATH"

printf '/dev/ttyUSB2\n' > "$WORK/at-port"

out="$(PEJIR_AT_PORT_FILE="$WORK/at-port" sh "$HELPER" status 2>&1)"
if printf '%s' "$out" | grep -q "^USED=12$"; then
	ok "status: разобрано число занятых сообщений"
else
	fail "status: не разобрано число занятых сообщений: $out"
fi
if printf '%s' "$out" | grep -q "^TOTAL=30$"; then
	ok "status: разобрано число всего места"
else
	fail "status: не разобрано число всего места: $out"
fi

rm -f "/tmp/modem-sms-clean-test.calls"
out="$(PEJIR_AT_PORT_FILE="$WORK/at-port" sh "$HELPER" clean 2>&1)"
if printf '%s' "$out" | grep -q "до:    12/30"; then
	ok "clean: показывает состояние памяти до очистки"
else
	fail "clean: не показывает состояние памяти до очистки: $out"
fi
if grep -q "AT+CMGD=1,4" "/tmp/modem-sms-clean-test.calls" 2>/dev/null; then
	ok "clean: удаляет сообщения в памяти модема (AT+CMGD=1,4)"
else
	fail "clean: не удаляет сообщения в памяти модема"
fi
rm -f "/tmp/modem-sms-clean-test.calls"

# Без модема (порт не задан) - понятная ошибка, а не пустота.
out="$(PEJIR_AT_PORT_FILE="$WORK/nope" sh "$HELPER" status 2>&1)"
if printf '%s' "$out" | grep -q "ERROR"; then
	ok "status без AT-порта: понятная ошибка"
else
	fail "status без AT-порта: нет сообщения об ошибке: $out"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты памяти модема пройдены"
