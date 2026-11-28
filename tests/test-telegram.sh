#!/bin/sh
# Тест моста Telegram (/usr/libexec/pejir-tg).
#
# Проверяется:
#   1) helper, init-скрипт и конфиг на месте; Makefile ставит их в пакет,
#      конфиг объявлен conffiles (переживает sysupgrade);
#   2) init: START=98 и USE_PROCD=1 (свой start_service, как у остальных
#      наших сервисов);
#   3) ACL: грант на запись uci-секции pejir_telegram.main и на exec
#      /usr/libexec/pejir-tg;
#   4) страница LuCI: поля Telegram и сохранение через uci; новые msgid
#      есть в .po;
#   5) ПОВЕДЕНИЕ (главное): подставной wget отвечает как Telegram API -
#      проверяется, что входящий SMS уходит в чат, что повторно он не
#      уходит, что команда /sms из нужного чата исполняется, а команда из
#      чужого чата и команда старше 10 минут - не исполняются.

set -u

if [ -n "${OW_TEST:-}" ]; then
	TREE="$OW_TEST"
else
	TREE="${PEJIR_OW_TEST:-/workspace/ow-test}"
	[ -d "$TREE" ] || { echo "FAIL: нет дерева $TREE (задайте OW_TEST)"; exit 1; }
fi

PKG="$TREE/package/pejir-telegram"
LUCI="$TREE/package/luci-app-perenio"
HELPER="$PKG/root/usr/libexec/pejir-tg"
INIT="$PKG/root/etc/init.d/49-pejir-tg"
CONF="$PKG/root/etc/config/pejir_telegram"
MAKEFILE="$PKG/Makefile"
ACL="$LUCI/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
PAGE="$LUCI/htdocs/luci-static/resources/view/perenio/sms.js"
PO="$LUCI/po/ru/luci-app-perenio.po"

PEJIR_TEST_WORK="${PEJIR_TEST_WORK:-/tmp/pejir-test-telegram}"
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$HELPER" "$INIT" "$CONF" "$MAKEFILE" "$ACL" "$PAGE" "$PO"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

rm -rf "$PEJIR_TEST_WORK"
mkdir -p "$PEJIR_TEST_WORK/bin" "$PEJIR_TEST_WORK/spool" "$PEJIR_TEST_WORK/state"
WORK="$PEJIR_TEST_WORK"

# --- 1) наличие, синтаксис, установка ---------------------------------------
sh -n "$HELPER" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"
sh -n "$INIT" 2>/dev/null && ok "init: синтаксис shell корректен" \
	|| fail "init: ошибка синтаксиса shell"
[ -x "$HELPER" ] && ok "helper: исполняемый" || fail "helper: не исполняемый"

grep -q "pejir-tg" "$MAKEFILE" && ok "Makefile: helper устанавливается" \
	|| fail "Makefile: helper не установлен"
grep -q "49-pejir-tg" "$MAKEFILE" && ok "Makefile: init-скрипт устанавливается" \
	|| fail "Makefile: init-скрипт не установлен"
grep -q "pejir_telegram" "$MAKEFILE" && ok "Makefile: uci-конфиг устанавливается" \
	|| fail "Makefile: uci-конфиг не установлен"
grep -q "conffiles" "$MAKEFILE" && ok "Makefile: конфиг в conffiles (переживает sysupgrade)" \
	|| fail "Makefile: конфиг не в conffiles"
grep -q "wget-ssl" "$MAKEFILE" && ok "Makefile: зависимость wget-ssl (TLS) объявлена" \
	|| fail "Makefile: нет зависимости wget-ssl"

# --- 2) init-скрипт ---------------------------------------------------------
grep -qE "^[[:space:]]*START=98" "$INIT" \
	&& ok "init: START=98 (после модема, LTE и автонастройки)" \
	|| fail "init: неверный START"
grep -qE "^[[:space:]]*USE_PROCD=1" "$INIT" \
	&& ok "init: USE_PROCD=1" || fail "init: нет USE_PROCD=1"
grep -q "pejir-tg watch" "$INIT" && ok "init: запускает helper в режиме watch" \
	|| fail "init: не запускает helper в режиме watch"

# --- 3) ACL -----------------------------------------------------------------
# ВАЖНО: rpcd сверяет в scope "uci" ИМЯ КОНФИГА (fnmatch по имени), а не
# "конфиг.секция": запись "pejir_telegram.main" не даёт никаких прав, и
# uci/set отвечает "Permission denied". Поэтому в ACL должно быть
# именно "pejir_telegram".
grep -q '"pejir_telegram"' "$ACL" \
	&& ok "ACL: есть грант на запись конфига pejir_telegram" \
	|| fail "ACL: нет гранта на запись конфига pejir_telegram"
grep -q '"/usr/libexec/pejir-tg"' "$ACL" \
	&& ok "ACL: есть грант на exec /usr/libexec/pejir-tg" \
	|| fail "ACL: нет гранта на exec /usr/libexec/pejir-tg"

# --- 4) страница LuCI и переводы -------------------------------------------
for id in tg-enabled tg-token tg-chat tg-interval tg-commands tg-protect; do
	grep -q "'$id'" "$PAGE" && ok "страница: есть поле $id" || fail "страница: нет поля $id"
done
grep -q "uci.set('pejir_telegram'" "$PAGE" && ok "страница: настройки пишутся через uci" \
	|| fail "страница: нет записи через uci"
grep -q "'require uci'" "$PAGE" && ok "страница: подключён require uci" \
	|| fail "страница: нет require uci"

for m in "Telegram bridge" "Bot token" "Chat ID" "Polling interval, s" \
	 "Allow commands from the chat" "Protection code for /reboot"; do
	grep -q "^msgid \"$m\"$" "$PO" && ok "перевод: есть msgid \"$m\"" \
		|| fail "перевод: нет msgid \"$m\""
done

# --- 5) поведение -----------------------------------------------------------
# Подставной wget: отвечает как Telegram API и пишет запросы в лог.
cat > "$WORK/bin/wget" <<'WGETEOF'
#!/bin/sh
# Подставной wget для теста моста Telegram.
LOG="${TG_FAKE_LOG:-/dev/null}"
post=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
	--post-data) post="$2"; shift 2 ;;
	-T|--timeout) shift 2 ;;
	-qO-|-q|--quiet|-O) shift ;;
	--) shift; break ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
printf 'URL %s\n' "$url" >> "$LOG"
if [ -n "$post" ]; then
	printf 'POST %s\n' "$post" >> "$LOG"
fi
case "$url" in
*getUpdates*)
	cat "${TG_FAKE_JSON:-/dev/null}"
	;;
*)
	printf '{"ok":true,"result":{"message_id":1,"date":1,"text":"ok"}}\n'
	;;
esac
exit 0
WGETEOF
chmod 0755 "$WORK/bin/wget"

# Подставной помощник отправки SMS и подставной reboot.
cat > "$WORK/bin/pejir-send-sms" <<'SENDEOF'
#!/bin/sh
printf '%s\n%s\n' "$1" "$2" >> "${TG_FAKE_SMS:-/dev/null}"
exit 0
SENDEOF
chmod 0755 "$WORK/bin/pejir-send-sms"

cat > "$WORK/bin/reboot" <<'REBOOTEOF'
#!/bin/sh
printf 'reboot\n' >> "${TG_FAKE_REBOOT:-/dev/null}"
exit 0
REBOOTEOF
chmod 0755 "$WORK/bin/reboot"

export PATH="$WORK/bin:$PATH"
export TG_FAKE_LOG="$WORK/wget.log"
export TG_FAKE_SMS="$WORK/sms.log"
export TG_FAKE_REBOOT="$WORK/reboot.log"
export TG_FAKE_JSON="$WORK/updates.json"

# Конфиг моста (в тесте - обычный файл, а не uci).
cat > "$WORK/telegram.conf" <<'CONFEOF'
enabled=1
token=TESTTOKEN
chat=12345
interval=60
commands=1
protect=secret
CONFEOF

export PEJIR_TG_CONF="$WORK/telegram.conf"
export PEJIR_TG_STATE="$WORK/state"
export PEJIR_TG_SPOOL="$WORK/spool"
export PEJIR_TG_SENDSMS="$WORK/bin/pejir-send-sms"
export PEJIR_TG_API="https://api.telegram.org"
export PEJIR_TG_WGET="$WORK/bin/wget"

# Входящий SMS в спуле: строка 1 - номер, 2 - дата, дальше текст.
cat > "$WORK/spool/message1" <<'MSGEOF'
+79161234567
2026-11-25 10:00
Привет, это проверка
MSGEOF

# 5a) пересылка входящего SMS
"$HELPER" forward >/dev/null 2>&1
if grep -q "URL.*sendMessage" "$TG_FAKE_LOG" 2>/dev/null; then
	ok "пересылка: SMS отправлена в Telegram"
else
	fail "пересылка: POST в sendMessage не найден"
fi
if grep -q "79161234567" "$TG_FAKE_LOG" 2>/dev/null; then
	ok "пересылка: в сообщении есть номер отправителя"
else
	fail "пересылка: нет номера отправителя"
fi
if grep -q "%0A" "$TG_FAKE_LOG" 2>/dev/null; then
	ok "пересылка: перевод строки закодирован как %0A"
else
	fail "пересылка: нет %0A в теле запроса"
fi
if grep -q "chat_id=12345" "$TG_FAKE_LOG" 2>/dev/null; then
	ok "пересылка: указан chat_id из настроек"
else
	fail "пересылка: нет chat_id"
fi

# 5b) повторно то же SMS не отправляется
_before="$(grep -c "POST" "$TG_FAKE_LOG" 2>/dev/null || echo 0)"
"$HELPER" forward >/dev/null 2>&1
_after="$(grep -c "POST" "$TG_FAKE_LOG" 2>/dev/null || echo 0)"
[ "$_before" = "$_after" ] && ok "пересылка: повторно не отправляется (список отправленных)" \
	|| fail "пересылка: SMS отправлено повторно ($_before -> $_after)"

# 5c) команды из чата
NOW="$(date +%s)"
OLD=$((NOW - 3600))
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":500,"message":{"message_id":1,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/status"}},
{"update_id":501,"message":{"message_id":2,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/sms 79161234567 привет из чата secret"}},
{"update_id":502,"message":{"message_id":3,"chat":{"id":99999,"type":"private"},"date":$NOW,"text":"/sms 7000000000 из чужого чата"}},
{"update_id":503,"message":{"message_id":4,"chat":{"id":12345,"type":"private"},"date":$OLD,"text":"/sms 7000000000 старая команда"}}]}
JSONEOF

: > "$TG_FAKE_SMS"
"$HELPER" commands >/dev/null 2>&1
if grep -q "79161234567" "$TG_FAKE_SMS" 2>/dev/null; then
	ok "команды: /sms из своего чата исполнена"
else
	fail "команды: /sms из своего чата не исполнена"
fi
if grep -q "привет из чата" "$TG_FAKE_SMS" 2>/dev/null; then
	ok "команды: текст SMS передан целиком"
else
	fail "команды: текст SMS не передан"
fi
if grep -q "7000000000" "$TG_FAKE_SMS" 2>/dev/null; then
	fail "команды: команда из чужого чата или старше 10 минут исполнена"
else
	ok "команды: чужие и старые команды не исполнены"
fi
if grep -q "offset=" "$TG_FAKE_LOG" 2>/dev/null; then
	ok "команды: смещение update передаётся в API"
else
	# смещение появляется со второго опроса: первый стартует с нуля
	"$HELPER" commands >/dev/null 2>&1
	if grep -q "offset=" "$TG_FAKE_LOG" 2>/dev/null; then
		ok "команды: смещение update передаётся в API"
	else
		fail "команды: смещение update не передаётся"
	fi
fi

# 5c-bis) /sms без защитного кода - не выполняется
: > "$TG_FAKE_SMS"
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":610,"message":{"message_id":9,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/sms 79161234567 без кода"}}]}
JSONEOF
"$HELPER" commands >/dev/null 2>&1
[ -s "$TG_FAKE_SMS" ] && fail "команды: /sms выполнен без защитного кода" \
	|| ok "команды: /sms без защитного кода не выполняется"

# 5d) /reboot без защитного кода - не выполняется
: > "$TG_FAKE_REBOOT"
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":600,"message":{"message_id":6,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/reboot"}}]}
JSONEOF
"$HELPER" commands >/dev/null 2>&1
[ -s "$TG_FAKE_REBOOT" ] && fail "команды: /reboot выполнен без защитного кода" \
	|| ok "команды: /reboot без защитного кода не выполняется"

# с правильным кодом - выполняется
: > "$TG_FAKE_REBOOT"
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":601,"message":{"message_id":7,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/reboot secret"}}]}
JSONEOF
"$HELPER" commands >/dev/null 2>&1
grep -q "reboot" "$TG_FAKE_REBOOT" 2>/dev/null \
	&& ok "команды: /reboot с защитным кодом выполняется" \
	|| fail "команды: /reboot с защитным кодом не выполнился"

# 5e) выключенный мост ничего не делает
: > "$TG_FAKE_LOG"
sed -i 's/^enabled=1/enabled=0/' "$WORK/telegram.conf"
"$HELPER" forward >/dev/null 2>&1
[ -s "$TG_FAKE_LOG" ] && fail "выключено: мост всё равно обращается к API" \
	|| ok "выключено: мост молчит"
sed -i 's/^enabled=0/enabled=1/' "$WORK/telegram.conf"

# 5f) статус показывает настройки
"$HELPER" status 2>/dev/null | grep -q "12345" \
	&& ok "status: показывает chat ID" || fail "status: не показывает chat ID"
"$HELPER" chatid 2>/dev/null | grep -q "12345" \
	&& ok "chatid: показывает chat ID" || fail "chatid: не показывает chat ID"

echo "---"
if [ "$FAILED" -eq 0 ]; then
	echo "PASS: тест моста Telegram пройден"
	exit 0
fi

echo "FAIL: провалено проверок: $FAILED"
exit 1
