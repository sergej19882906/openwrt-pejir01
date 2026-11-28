#!/bin/sh
# Тест отправки сообщений и файлов Telegram-мостом (pejir-tg-send).
#
# Проверяется:
#   1) helper на месте, исполняемый, синтаксис shell корректен;
#   2) текст уходит в sendMessage;
#   3) файл уходит в sendDocument как multipart/form-data, с правильным
#      именем и содержимым;
#   4) файлы вне /tmp и /www и файлы больше 20 МБ не отправляются;
#   5) маршрутизация команд в pejir-tg: /signal выполняется без кода,
#      опасные команды (/wifi, /file) - только с защитным кодом.
#
# Тест обязан падать на старом коде (файла pejir-tg-send ещё нет).

set -u

if [ -n "${OW_TEST:-}" ]; then
	TREE="$OW_TEST"
else
	TREE="${PEJIR_OW_TEST:-/workspace/ow-test}"
	[ -d "$TREE" ] || { echo "FAIL: нет дерева $TREE (задайте OW_TEST)"; exit 1; }
fi

SEND="$TREE/package/pejir-telegram/root/usr/libexec/pejir-tg-send"
TG="$TREE/package/pejir-telegram/root/usr/libexec/pejir-tg"
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$SEND" ] || { echo "FAIL: нет $SEND"; exit 1; }
[ -x "$SEND" ] && ok "helper: исполняемый" || fail "helper: не исполняемый"
sh -n "$SEND" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"

WORK="${PEJIR_TEST_WORK:-/tmp/pejir-test-tgsend}"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/www" "$WORK/state" "$WORK/spool"

cat > "$WORK/bin/wget" <<'WGETEOF'
#!/bin/sh
post=""
url=""
hdr=""
while [ $# -gt 0 ]; do
	case "$1" in
	--post-file=*) post="${1#--post-file=}"; shift ;;
	--post-file) post="$2"; shift 2 ;;
	--header=*) hdr="${1#--header=}"; shift ;;
	--header) hdr="$2"; shift 2 ;;
	-T|--timeout|--max-redirect) shift 2 ;;
	-qO-|-q|--quiet|-O) shift ;;
	--) shift; break ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
printf 'URL %s\n' "$url" >> "$SEND_LOG"
[ -n "$hdr" ] && printf 'HDR %s\n' "$hdr" >> "$SEND_LOG"
if [ -n "$post" ] && [ -f "$post" ]; then
	printf 'BODY %s\n' "$post" >> "$SEND_LOG"
	cat "$post" >> "$SEND_LOG"
fi
case "$url" in
*getUpdates*)
	cat "${TG_FAKE_JSON:-/dev/null}"
	;;
*)
	printf '{"ok":true,"result":{"message_id":1}}\n'
	;;
esac
exit 0
WGETEOF
chmod 0755 "$WORK/bin/wget"

export PEJIR_TG_SEND_WGET="$WORK/bin/wget"
export PEJIR_TG_SEND_TMP="$WORK/tmp"
export PEJIR_TG_SEND_ROOTS="$WORK/tmp $WORK/www"
export PEJIR_TG_SEND_API="https://api.telegram.org"
export PEJIR_TG_SEND_TOKEN="TESTTOKEN"
export PEJIR_TG_SEND_CHAT="12345"
export SEND_LOG="$WORK/wget.log"
export TG_FAKE_JSON="$WORK/updates.json"

# --- 1) текст ---------------------------------------------------------------
printf 'привет из моста\n' > "$WORK/tmp/отчёт.txt"
printf 'данные\n' > "$WORK/www/page.html"

"$SEND" text "тестовое сообщение" >/dev/null 2>&1
grep -q "sendMessage" "$SEND_LOG" 2>/dev/null && ok "text: запрос в sendMessage" \
	|| fail "text: sendMessage не найден"

# --- 2) файл ----------------------------------------------------------------
: > "$SEND_LOG"
"$SEND" file "$WORK/tmp/отчёт.txt" >/dev/null 2>&1
grep -q "sendDocument" "$SEND_LOG" 2>/dev/null && ok "file: запрос в sendDocument" \
	|| fail "file: sendDocument не найден"
grep -q "multipart/form-data" "$SEND_LOG" 2>/dev/null && ok "file: multipart/form-data" \
	|| fail "file: нет multipart/form-data"
grep -q 'filename=' "$SEND_LOG" 2>/dev/null && ok "file: имя файла в multipart" \
	|| fail "file: нет имени файла"
grep -q "привет из моста" "$SEND_LOG" 2>/dev/null && ok "file: содержимое файла в теле" \
	|| fail "file: содержимое файла не передано"

# --- 3) ограничения ---------------------------------------------------------
: > "$SEND_LOG"
"$SEND" file /etc/passwd >/dev/null 2>&1
[ -s "$SEND_LOG" ] && fail "file: отправлен файл вне /tmp и /www" \
	|| ok "file: файл вне /tmp и /www не отправляется"

dd if=/dev/zero of="$WORK/tmp/big.bin" bs=1048576 count=21 2>/dev/null
: > "$SEND_LOG"
"$SEND" file "$WORK/tmp/big.bin" >/dev/null 2>&1
[ -s "$SEND_LOG" ] && fail "file: отправлен файл больше 20 МБ" \
	|| ok "file: файл больше 20 МБ не отправляется"

# --- 4) маршрутизация команд в pejir-tg -------------------------------------
[ -f "$TG" ] || { echo "FAIL: нет $TG"; exit 1; }

cat > "$WORK/telegram.conf" <<'CONFEOF'
enabled=1
token=TESTTOKEN
chat=12345
interval=60
commands=1
protect=secret
CONFEOF

cat > "$WORK/bin/pejir-sys" <<'SYSEOF'
#!/bin/sh
printf 'sys %s\n' "$*" >> "${TG_SYS_CALL_LOG:-/dev/null}"
exit 0
SYSEOF
chmod 0755 "$WORK/bin/pejir-sys"

cat > "$WORK/bin/pejir-tg-send" <<'SENDEOF'
#!/bin/sh
printf 'send %s\n' "$*" >> "${TG_SEND_CALL_LOG:-/dev/null}"
exit 0
SENDEOF
chmod 0755 "$WORK/bin/pejir-tg-send"

export PATH="$WORK/bin:$PATH"
export PEJIR_TG_CONF="$WORK/telegram.conf"
export PEJIR_TG_STATE="$WORK/state"
export PEJIR_TG_SPOOL="$WORK/spool"
export PEJIR_TG_WGET="$WORK/bin/wget"
export PEJIR_TG_API="https://api.telegram.org"
export PEJIR_TG_SYS="$WORK/bin/pejir-sys"
export PEJIR_TG_SEND="$WORK/bin/pejir-tg-send"
export TG_SYS_CALL_LOG="$WORK/sys.log"
export TG_SEND_CALL_LOG="$WORK/send.log"

NOW="$(date +%s)"

cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":700,"message":{"message_id":1,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/signal"}}]}
JSONEOF
: > "$TG_SYS_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "sys signal" "$TG_SYS_CALL_LOG" 2>/dev/null && ok "/signal: команда без кода выполнена" \
	|| fail "/signal: команда не выполнена"

cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":701,"message":{"message_id":2,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/wifi radio0 off"}}]}
JSONEOF
: > "$TG_SYS_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "sys wifi" "$TG_SYS_CALL_LOG" 2>/dev/null && fail "/wifi: выполнена без защитного кода" \
	|| ok "/wifi: без защитного кода не выполняется"

cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":702,"message":{"message_id":3,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/wifi radio0 off secret"}}]}
JSONEOF
: > "$TG_SYS_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "sys wifi radio0 off" "$TG_SYS_CALL_LOG" 2>/dev/null \
	&& ok "/wifi: с защитным кодом выполнена" || fail "/wifi: с кодом не выполнена"

cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":703,"message":{"message_id":4,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/file $WORK/tmp/отчёт.txt secret"}}]}
JSONEOF
: > "$TG_SEND_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "send file" "$TG_SEND_CALL_LOG" 2>/dev/null && ok "/file: файл уходит в pejir-tg-send" \
	|| fail "/file: файл не отправлен"

echo "---"
if [ "$FAILED" -eq 0 ]; then
	echo "PASS: отправка сообщений и файлов"
	exit 0
fi
echo "FAIL: провалено проверок: $FAILED"
exit 1
