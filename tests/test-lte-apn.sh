#!/bin/sh
# Тест настройки APN: логин, пароль, тип аутентификации, тип PDP (патч 0089).
#
# ФАКТ (стоковая прошивка Perenio 9.0.4, usr/lib/modem_ubus/gosuncn.sh):
#   Stock отдаёт модему настройки подключения одной командой
#       AT+ZECMCALL=1[,<apn>[,<pdp_num>[,<user>[,<pass>[,<auth_num>]]]]]
#   где pdp_num: 1 - IPv4, 2 - IPv6, 3 - IPv4v6 (get_pdp_type),
#        auth_num: 1 - PAP, 2 - CHAP (get_auth_type).
#   Наш порт отправлял только AT+ZECMCALL=1,<apn> - логина, пароля и
#   типа аутентификации не было, поэтому APN с авторизацией (приватные
#   APN операторов) не поднимались.
#
# ЧТО ДОЛЖЕН ДЕЛАТЬ НОВЫЙ ХЕЛПЕР usr/libexec/pejir-lte-apn:
#   * читать network.lte.apn / .pdptype / .username / .password / .auth;
#   * печатать первую строку AT+CGDCONT=1,"<PDP>","<APN>";
#   * печатать вторую строку AT+ZECMCALL=1,... с логином/паролем/auth
#     ТОЛЬКО если логин и пароль заданы одновременно: иначе позиции
#     параметров сдвинутся и модем примет пароль за логин;
#   * БЕЗ логина и пароля форму команды не менять: текущий
#     AT+ZECMCALL=1,<apn> проверен на живом устройстве.

set -u

BASE="$(cd "$(dirname "$0")/.." && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST)"; exit 1; }

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

HELPER="$OW/package/pejir-lte-base/root/usr/libexec/pejir-lte-apn"
LTE_INIT="$OW/package/pejir-lte-base/root/etc/init.d/47-pejir-lte"

# --- 1) хелпер существует -------------------------------------------------
if [ -f "$HELPER" ]; then
	ok "хелпер настроек APN есть: usr/libexec/pejir-lte-apn"
else
	fail "нет $HELPER - настройки APN (логин/пароль/auth) отправлять нечем"
	echo "FAIL: провалено проверок: $((FAILED + 1))"
	exit 1
fi

if [ -x "$HELPER" ]; then
	ok "хелпер исполняемый"
else
	fail "хелпер не исполняемый (нет бита execute)"
fi

# --- 2) init-скрипт LTE пользуется хелпером -------------------------------
if [ -f "$LTE_INIT" ] && grep -q 'pejir-lte-apn' "$LTE_INIT"; then
	ok "47-pejir-lte использует pejir-lte-apn"
else
	fail "47-pejir-lte не вызывает pejir-lte-apn - настройки не доедут до модема"
fi

# --- стенд: подменяем uci ------------------------------------------------
WORK="${PEJIR_TEST_WORK:-/tmp/pejir-lte-apn-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/uci" <<'UCIEOF'
#!/bin/sh
# Подмена uci для стенда: значения берутся из переменных окружения.
# Поддерживается только "uci -q get network.lte.<key>".
key=""
while [ $# -gt 0 ]; do
	case "$1" in
		-q) shift ;;
		get) shift; key="$1"; shift ;;
		*) shift ;;
	esac
done
case "$key" in
	network.lte.apn)      v="$MOCK_APN" ;;
	network.lte.pdptype)  v="$MOCK_PDP" ;;
	network.lte.username) v="$MOCK_USER" ;;
	network.lte.password) v="$MOCK_PASS" ;;
	network.lte.auth)     v="$MOCK_AUTH" ;;
	*) v="" ;;
esac
[ -n "$v" ] || exit 1
printf '%s\n' "$v"
UCIEOF
chmod +x "$WORK/bin/uci"

run_helper() {
	PATH="$WORK/bin:$PATH" \
	MOCK_APN="$1" MOCK_PDP="$2" MOCK_USER="$3" MOCK_PASS="$4" MOCK_AUTH="$5" \
		sh "$HELPER" 2>/dev/null
}

# --- 3) только APN: форма команды не меняется ----------------------------
OUT="$(run_helper "internet" "" "" "" "")"
LINE1="$(printf '%s\n' "$OUT" | sed -n '1p')"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"

if [ "$LINE1" = 'AT+CGDCONT=1,"IP","internet"' ]; then
	ok "CGDCONT с одним APN: $LINE1"
else
	fail "CGDCONT с одним APN неверный: '$LINE1'"
fi

if [ "$LINE2" = 'AT+ZECMCALL=1,internet' ]; then
	ok "ZECMCALL без логина не изменён: $LINE2"
else
	fail "ZECMCALL без логина изменился: '$LINE2' (должен остаться AT+ZECMCALL=1,internet)"
fi

# --- 4) тип PDP ------------------------------------------------------------
OUT="$(run_helper "internet" "ipv6" "" "" "")"
LINE1="$(printf '%s\n' "$OUT" | sed -n '1p')"
if [ "$LINE1" = 'AT+CGDCONT=1,"IPV6","internet"' ]; then
	ok "тип PDP ipv6 попал в CGDCONT: $LINE1"
else
	fail "тип PDP ipv6 неверный: '$LINE1'"
fi

OUT="$(run_helper "internet" "ipv4v6" "" "" "")"
LINE1="$(printf '%s\n' "$OUT" | sed -n '1p')"
if [ "$LINE1" = 'AT+CGDCONT=1,"IPV4V6","internet"' ]; then
	ok "тип PDP ipv4v6 попал в CGDCONT: $LINE1"
else
	fail "тип PDP ipv4v6 неверный: '$LINE1'"
fi

# --- 5) логин, пароль и тип аутентификации --------------------------------
OUT="$(run_helper "private.apn" "ip" "user1" "pass1" "pap")"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"
if [ "$LINE2" = 'AT+ZECMCALL=1,private.apn,1,user1,pass1,1' ]; then
	ok "логин/пароль/PAP в ZECMCALL: $LINE2"
else
	fail "логин/пароль/PAP неверны: '$LINE2'"
fi

OUT="$(run_helper "private.apn" "ip" "user1" "pass1" "chap")"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"
if [ "$LINE2" = 'AT+ZECMCALL=1,private.apn,1,user1,pass1,2' ]; then
	ok "логин/пароль/CHAP в ZECMCALL: $LINE2"
else
	fail "логин/пароль/CHAP неверны: '$LINE2'"
fi

OUT="$(run_helper "private.apn" "ip" "user1" "pass1" "both")"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"
if [ "$LINE2" = 'AT+ZECMCALL=1,private.apn,1,user1,pass1,3' ]; then
	ok "логин/пароль/CHAP+PAP в ZECMCALL: $LINE2"
else
	fail "логин/пароль/CHAP+PAP неверны: '$LINE2'"
fi

# --- 6) без логина пароль НЕ отправляется ---------------------------------
OUT="$(run_helper "internet" "ip" "" "pass1" "pap")"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"
if [ "$LINE2" = 'AT+ZECMCALL=1,internet' ]; then
	ok "пароль без логина не отправлен - позиции не сдвинуты: $LINE2"
else
	fail "пароль без логина отправлен - модем примет пароль за логин: '$LINE2'"
fi

OUT="$(run_helper "internet" "ip" "user1" "" "pap")"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"
if [ "$LINE2" = 'AT+ZECMCALL=1,internet' ]; then
	ok "логин без пароля не отправлен - позиции не сдвинуты: $LINE2"
else
	fail "логин без пароля отправлен - позиции сдвинуты: '$LINE2'"
fi

# --- 7) без APN ничего не выводится ---------------------------------------
OUT="$(run_helper "" "ip" "user1" "pass1" "pap")"
if [ -z "$OUT" ]; then
	ok "без APN команд не формируется"
else
	fail "без APN сформированы команды: '$OUT'"
fi

# --- 8) тип аутентификации none не добавляет параметр --------------------
OUT="$(run_helper "private.apn" "ip" "user1" "pass1" "none")"
LINE2="$(printf '%s\n' "$OUT" | sed -n '2p')"
if [ "$LINE2" = 'AT+ZECMCALL=1,private.apn,1,user1,pass1' ]; then
	ok "тип аутентификации none не добавляет лишний параметр: $LINE2"
else
	fail "тип аутентификации none неверный: '$LINE2'"
fi

# --- 9) LuCI-страница, меню, ACL и перевод -------------------------------
LUCI_PKG="$OW/package/luci-app-perenio"
PAGE="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/lte.js"
MENU="$LUCI_PKG/root/usr/share/luci/menu.d/luci-app-perenio.json"
ACL="$LUCI_PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
PO="$LUCI_PKG/po/ru/luci-app-perenio.po"

for f in "$PAGE" "$MENU" "$ACL" "$PO"; do
	if [ -f "$f" ]; then
		ok "файл есть: ${f#$OW/}"
	else
		fail "нет $f - страница настроек LTE не попадёт в образ"
	fi
done

if [ -f "$PAGE" ]; then
	for key in network.lte apn pdptype username password auth; do
		if grep -q "$key" "$PAGE"; then
			ok "страница LTE упоминает $key"
		else
			fail "страница LTE не упоминает $key"
		fi
	done
	if grep -q "pejir-lte-apn" "$PAGE"; then
		ok "страница LTE показывает команды хелпера"
	else
		fail "страница LTE не вызывает pejir-lte-apn"
	fi
fi

if [ -f "$MENU" ]; then
	if grep -q '"perenio/lte"' "$MENU"; then
		ok "в меню есть пункт страницы LTE"
	else
		fail "в меню нет пункта страницы LTE"
	fi
fi

if [ -f "$ACL" ]; then
	if grep -q '"/usr/libexec/pejir-lte-apn"' "$ACL"; then
		ok "ACL разрешает запуск pejir-lte-apn"
	else
		fail "ACL не разрешает запуск pejir-lte-apn - кнопка в странице не сработает"
	fi
	if grep -q '"/etc/init.d/47-pejir-lte restart"' "$ACL"; then
		ok "ACL разрешает перезапуск 47-pejir-lte"
	else
		fail "ACL не разрешает перезапуск 47-pejir-lte - кнопка применения не сработает"
	fi
fi

if [ -f "$PO" ]; then
	for mid in "LTE settings (PEJIR01)" "Authentication type" "Show commands"; do
		if grep -qF "msgid \"$mid\"" "$PO"; then
			ok "перевод есть: $mid"
		else
			fail "нет перевода для msgid: $mid"
		fi
	done
fi

# --- 10) Makefile обязан ставить хелпер в образ ----------------------------
# У нас уже был случай: файл лежит в дереве пакета, но его нет в
# install-рецепте - в образ он не попадает, и всё молча не работает.
MK="$OW/package/pejir-lte-base/Makefile"
if [ -f "$MK" ]; then
	if grep -q 'pejir-lte-apn' "$MK"; then
		ok "Makefile pejir-lte-base ставит pejir-lte-apn в образ"
	else
		fail "Makefile pejir-lte-base НЕ ставит pejir-lte-apn - в образе хелпера не будет"
	fi
else
	fail "нет $MK"
fi

rm -rf "$WORK"

if [ "$FAILED" -eq 0 ]; then
	echo "PASS: настройки APN (логин/пароль/auth/PDP) формируются верно"
	exit 0
fi

echo "FAIL: провалено проверок: $FAILED"
exit 1
