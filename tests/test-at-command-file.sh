#!/bin/sh
# Тест: AT-команды модему уходят с завершающим LF.
#
# Дефект, который закрывает тест: atinout требует, чтобы строка команды
# в файле заканчивалась LF. Его функция tr_lf_cr() иначе печатает
# "invalid string" и ВООБЩЕ НИЧЕГО не отправляет модему. Наши хелперы
# писали файл как "AT+CPIN?\r" - без LF, поэтому ни одна команда не
# уходила модему: "Показать номер" отвечал "модем не ответил на
# AT+CNUM", mdm-at не находил AT-порт ("no AT port found"), сторож
# AT-порта считал порт зависшим и перепривязывал USB-драйвер, а
# init-скрипт LTE не отправлял модему AT+CGDCONT/AT+ZECMCALL - из-за
# этого LTE не поднимал PDP-контекст и не давал интернет.
#
# Мок atinout здесь повторяет правила настоящего: файл без завершающего
# LF - ошибка и пустой вывод.

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

MDM_AT="$DEFAULT_TREE/package/pejir-lte-base/root/usr/bin/mdm-at"
MODEM_CTL="$DEFAULT_TREE/package/pejir-lte-base/root/usr/libexec/pejir-modem-ctl"
BAND="$DEFAULT_TREE/package/pejir-lte-base/root/usr/libexec/pejir-band"
LTE_INIT="$DEFAULT_TREE/package/pejir-lte-base/root/etc/init.d/47-pejir-lte"
SMS_INIT="$DEFAULT_TREE/package/pejir-sms/root/etc/init.d/40-pejir-sms"

for f in "$MDM_AT" "$MODEM_CTL" "$BAND" "$LTE_INIT" "$SMS_INIT"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

WORK="${PEJIR_AT_FILE_WORK:-/tmp/pejir-at-file-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

# --- мок atinout: как настоящий, но с проверкой завершающего LF -----------
cat > "$WORK/bin/atinout" <<'EOF'
#!/usr/bin/env python3
"""Мок atinout: требует завершающий LF в файле команды (как tr_lf_cr)."""
import sys

path, dev, out = sys.argv[1:4]
try:
    data = open(path, "rb").read()
except OSError:
    sys.exit(1)

if not data.endswith(b"\n"):
    sys.stderr.write("invalid string: %r\n" % data)
    sys.exit(1)

sys.stdout.write("\r\nOK\r\n")
EOF
chmod +x "$WORK/bin/atinout"

cat > "$WORK/bin/stty" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$WORK/bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF

cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$WORK/bin/stty" "$WORK/bin/timeout" "$WORK/bin/logger"

# --- 1) helper управления модемом получает ответ --------------------------
out="$(PATH="$WORK/bin:$PATH" PEJIR_AT_PORT="$WORK/ttyFAKE" sh "$MODEM_CTL" pin-status 2>&1)"
case "$out" in
	*"не ответил"*) fail "modem-ctl: модем не ответил - команда не отправлена" ;;
	*) ok "modem-ctl: ответ модема получен" ;;
esac

# --- 2) helper диапазонов получает ответ ---------------------------------
out="$(PATH="$WORK/bin:$PATH" PEJIR_AT_PORT="$WORK/ttyFAKE" sh "$BAND" show 2>&1)"
case "$out" in
	*"не ответил"*) fail "pejir-band: модем не ответил - команда не отправлена" ;;
	*) ok "pejir-band: ответ модема получен" ;;
esac

# --- 3) mdm-at: проба порта пишется с LF ---------------------------------
# Файл "AT\r" atinout считает некорректным, порт не находится никогда,
# и mdm-at отвечает "no AT port found".
if grep -qF "printf 'AT\r\n'" "$MDM_AT" 2>/dev/null; then
	ok "mdm-at: проба порта пишется с LF (порт находится)"
else
	fail "mdm-at: проба порта пишется без LF - порт не найдётся"
fi

# --- 4) статическая проверка: во всех наших AT-файлах есть \r\n ----------
# Любой printf, пишущий команду модему, обязан заканчивать файл LF.
for f in "$MDM_AT" "$MODEM_CTL" "$BAND" "$LTE_INIT" "$SMS_INIT"; do
	bad="$(grep -n "printf .*\\\\r'" "$f" 2>/dev/null | grep -vF "\\r\\n'" || true)"
	if [ -n "$bad" ]; then
		fail "$f: команда модему записана без завершающего LF: $bad"
	else
		ok "$f: все команды модему записаны с LF"
	fi
done

# --- 5) в наших AT-файлах нет перевода строки в CR ------------------------
# "tr '\n' '\r'" оставляет файл БЕЗ завершающего LF - atinout такой
# файл считает некорректным и ничего не отправляет. Именно так терялись
# команды AT+CGDCONT и AT+ZECMCALL (без них LTE не даёт интернет).
for f in "$LTE_INIT" "$SMS_INIT" "$MDM_AT" "$MODEM_CTL" "$BAND"; do
	if grep -qF "tr '\\n' '\\r'" "$f" 2>/dev/null; then
		fail "$f: команда модему готовится через tr '\\n' '\\r' - файл останется без LF"
	else
		ok "$f: нет перевода строки в CR (файл всегда с LF)"
	fi
done

# --- 6) init-скрипт LTE реально отправляет команды модему ----------------
# Без LF модем не получает AT+CGDCONT и AT+ZECMCALL - LTE не поднимает
# PDP-контекст и не даёт интернет.
if grep -qF "AT+ZECMCALL=1,%s\r\n" "$LTE_INIT" 2>/dev/null; then
	ok "init-скрипт LTE: команда ZECMCALL пишется с LF (data call уйдёт модему)"
else
	fail "init-скрипт LTE: команда ZECMCALL пишется без LF - LTE не поднимет data call"
fi

if grep -qF "AT+CGACT=1,1\r\n" "$LTE_INIT" 2>/dev/null; then
	ok "init-скрипт LTE: команда CGACT пишется с LF"
else
	fail "init-скрипт LTE: команда CGACT пишется без LF"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты AT-обмена пройдены"
