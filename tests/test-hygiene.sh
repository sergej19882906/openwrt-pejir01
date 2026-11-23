#!/bin/sh
# Тест гигиены релиза .48 (F15-F26 без F17):
#   - SMS-отправка через обёртку /usr/libexec/pejir-send-sms (грант без wildcard),
#     ACL write.uci сужён до network.lte;
#   - удаление сообщений из спула через /usr/libexec/pejir-sms-clean;
#   - верифицированный AT-порт (/etc/pejir/at-port): uci-defaults modeminfo
#     и сканер портов atinout (включая ACL-грант на чтение файла);
#   - в 65-luci-app-atinout нет rm -rf /tmp/luci-*;
#   - uartmuxd не сносит /dev/umxtty* в stop_service;
#   - build.yml: точный ключ кеша, без restore-keys, запуск через ./build.sh;
#   - build.sh: CONFIG_CCACHE=y и бит исполнения;
#   - README: блоки «Актуальный релиз» дедуплицированы.
#
# Тест смотрит на сам репозиторий (repo-side), поэтому OW_TEST не требует:
# package/* берутся из рядом лежащего дерева патчей.

set -u
# package/* берутся из дерева OpenWrt с применёнными патчами (в CI это $OW_TEST),
# build.sh/build.yml/README - из самого репозитория.
BASE="$(cd "$(dirname "$0")/.." && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST с деревом OpenWrt)"; exit 1; }

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

LUCI_PKG="$OW/package/luci-app-perenio"
ATINOUT_PKG="$OW/package/luci-app-atinout"
MODEMINFO_PKG="$OW/package/modeminfo"
UARTMUXD_PKG="$OW/package/uartmuxd"

ACL="$LUCI_PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
SMS_JS="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/sms.js"
MKFILE="$LUCI_PKG/Makefile"
WRAP="$LUCI_PKG/root/usr/libexec/pejir-send-sms"
CLEAN="$LUCI_PKG/root/usr/libexec/pejir-sms-clean"
AT_ACL="$ATINOUT_PKG/root/usr/share/rpcd/acl.d/luci-app-atinout.json"
AT_JS="$ATINOUT_PKG/htdocs/luci-static/resources/view/modem/atcommands.js"
UD65="$ATINOUT_PKG/root/etc/uci-defaults/65-luci-app-atinout"
UMI="$MODEMINFO_PKG/root/etc/uci-defaults/60-perenio-modeminfo"
UINIT="$UARTMUXD_PKG/files/uartmuxd.init"

for f in "$ACL" "$SMS_JS" "$MKFILE" "$WRAP" "$CLEAN" "$AT_ACL" "$AT_JS" "$UD65" "$UMI" "$UINIT"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

if python3 -m json.tool "$ACL" >/dev/null 2>&1 && \
   python3 -m json.tool "$AT_ACL" >/dev/null 2>&1; then
	ok "ACL JSON валидны"
else
	fail "ACL JSON не парсятся"
fi

# --- F15: sendsms через обёртку -------------------------------------------
if grep -q '/usr/bin/sendsms' "$SMS_JS"; then
	fail "sms.js вызывает /usr/bin/sendsms напрямую"
else
	ok "sms.js не зовёт /usr/bin/sendsms напрямую"
fi
if grep -q '/usr/libexec/pejir-send-sms' "$SMS_JS"; then
	ok "sms.js использует обёртку pejir-send-sms"
else
	fail "sms.js: нет вызова /usr/libexec/pejir-send-sms"
fi
if grep -q '"/usr/libexec/pejir-send-sms": \[' "$ACL" && \
   grep -q '"/usr/libexec/pejir-sms-clean": \[' "$ACL"; then
	ok "ACL: точные гранты на pejir-send-sms и pejir-sms-clean"
else
	fail "ACL: нет грантов pejir-send-sms/pejir-sms-clean"
fi
if grep -q '"sendsms \*"' "$ACL"; then
	fail "ACL: остался wildcard-грант /usr/bin/sendsms *"
else
	ok "ACL: wildcard-грант sendsms * удалён"
fi
[ -x "$WRAP" ] && ok "pejir-send-sms исполняемый" || fail "pejir-send-sms без бита исполнения"
[ -x "$CLEAN" ] && ok "pejir-sms-clean исполняемый" || fail "pejir-sms-clean без бита исполнения"
if grep -q 'case "$1" in' "$CLEAN" && grep -q '\.\.' "$CLEAN"; then
	ok "pejir-sms-clean отсекает путевые компоненты"
else
	fail "pejir-sms-clean: нет защиты от traversal"
fi
grep -q 'pejir-send-sms' "$MKFILE" && grep -q 'pejir-sms-clean' "$MKFILE" \
	&& ok "Makefile: обёртки установлены" \
	|| fail "Makefile: нет установки обёрток"

# --- F26c: spool-очистка в sms.js -----------------------------------------
if grep -q 'fs\.exec' "$SMS_JS" && grep -q 'sms-clean' "$SMS_JS"; then
	ok "sms.js: кнопка удаления из спула есть"
else
	fail "sms.js: нет кнопки удаления из спула"
fi
if grep -qE "fs\.exec\('(/[^']*rm|/bin/rm)" "$SMS_JS"; then
	fail "sms.js: удаление через fs.exec rm"
else
	ok "sms.js: удаление только через обёртку"
fi

# --- F16: write.uci сужён -------------------------------------------------
if python3 - "$ACL" <<'PYEOF'
import json,sys
a=json.load(open(sys.argv[1]))
w=a['luci-app-perenio']['write']['uci']
r=a['luci-app-perenio']['read']['uci']
sys.exit(0 if w==['network.lte'] and r==['network'] else 1)
PYEOF
then
	ok "ACL: write.uci = network.lte, read.uci = network"
else
	fail "ACL: write.uci не сужён до network.lte (или сломан read.uci)"
fi

# --- F24: modeminfo device из /etc/pejir/at-port --------------------------
if grep -q 'head -n 1 /etc/pejir/at-port' "$UMI"; then
	ok "60-perenio-modeminfo: device берётся из /etc/pejir/at-port"
else
	fail "60-perenio-modeminfo: нет чтения /etc/pejir/at-port"
fi

# --- F25: сканер портов atinout -------------------------------------------
if grep -Fq '"/etc/pejir/at-port": [ "read" ]' "$AT_ACL"; then
	ok "ACL atinout: грант на чтение /etc/pejir/at-port"
else
	fail "ACL atinout: нет гранта на /etc/pejir/at-port"
fi
if grep -q 'pejir/at-port' "$AT_JS"; then
	ok "atcommands.js использует /etc/pejir/at-port"
else
	fail "atcommands.js: не читает /etc/pejir/at-port"
fi

# --- F26a: без rm -rf /tmp/luci-* -----------------------------------------
if grep -q 'rm -rf /tmp/luci-' "$UD65"; then
	fail "65-luci-app-atinout: остался rm -rf /tmp/luci-*"
else
	ok "65-luci-app-atinout: rm -rf /tmp/luci-* убран"
fi

# --- F26b: uartmuxd stop без сноса umxtty* --------------------------------
if grep -q 'umxtty' "$UINIT"; then
	fail "uartmuxd.init: stop_service сносит /dev/umxtty*"
else
	ok "uartmuxd.init: umxtty* не сносятся"
fi

# --- F20/F21/F23: build.sh и build.yml ------------------------------------
BUILD_SH="$BASE/build.sh"
BUILD_YML="$BASE/.github/workflows/build.yml"
README="$BASE/README.md"

[ -f "$BUILD_SH" ] || { echo "FAIL: нет $BUILD_SH"; exit 1; }
[ -f "$BUILD_YML" ] || { echo "FAIL: нет $BUILD_YML"; exit 1; }
[ -f "$README" ] || { echo "FAIL: нет $README"; exit 1; }

[ -x "$BUILD_SH" ] && ok "build.sh исполняемый" || fail "build.sh без бита исполнения"
grep -q '^CONFIG_CCACHE=y' "$BUILD_SH" \
	&& ok "build.sh: CONFIG_CCACHE=y" \
	|| fail "build.sh: нет CONFIG_CCACHE=y"
if grep -q 'chmod +x build.sh' "$BUILD_YML"; then
	fail "build.yml: остался обходчик chmod +x build.sh"
else
	ok "build.yml: запуск через ./build.sh"
fi
if grep -q 'restore-keys:' "$BUILD_YML"; then
	fail "build.yml: остался широкий restore-keys"
else
	ok "build.yml: точный ключ кеша без restore-keys"
fi
if grep -q '\.ccache' "$BUILD_YML"; then
	ok "build.yml: .ccache в путях кеша"
else
	fail "build.yml: .ccache не кешируется"
fi

# --- F19: README без дублей «Актуальный релиз» ----------------------------
n=$(grep -c 'Актуальный релиз' "$README")
if [ "$n" -le 1 ]; then
	ok "README: блоки «Актуальный релиз» дедуплицированы ($n)"
else
	fail "README: «Актуальный релиз» встречается $n раз"
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "ALL PASS"
	exit 0
fi
echo "FAILED: $FAILED"
exit 1
