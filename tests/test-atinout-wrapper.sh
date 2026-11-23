#!/bin/sh
# Тест wrapper'а LuCI-приложения atinout (вкладка AT Command).
#
# ACL при этом НЕ проверяется и не меняется: на живом устройстве (.46)
# вкладка AT Command работает и с текущими грантами exec в read.file -
# ранее заявленный «Доступ запрещён» на практике не воспроизводится.
#
# Wrapper проверяем на два момента:
#   1) stty: без raw-режима без эха модем на AT не отвечает (на живом
#      устройстве проверено, см. комментарии в scripts/modeminfo).
#   2) кавычки: аргументы echo/atinout должны быть в кавычках, иначе
#      команда или путь с пробелами/кавычками разрываются.
#
# Плюс регресс: ACL не потерял гранты чтения/записи /etc/atcommands.user
# и остался валидным JSON.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/luci-app-atinout"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-atinout"
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
WRAPPER="$PKG/root/usr/bin/luci-app-atinout"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-atinout.json"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$WRAPPER" "$ACL"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

if [ -x "$WRAPPER" ]; then
	ok "wrapper: исполняемый бит на месте"
else
	fail "wrapper: нет права на выполнение на $WRAPPER"
fi

# --- 1) stty raw перед передачей порта ----------------------------------------
if grep -q 'stty -F "$2"' "$WRAPPER" && grep -q 'raw -echo' "$WRAPPER"; then
	ok "wrapper: порт переводится в raw-режим (stty raw -echo)"
else
	fail "wrapper: нет stty raw -echo - на не-raw порту модем молчит"
fi

# --- 2) кавычки вокруг аргументов ---------------------------------------------
if grep -q 'echo "$1" | atinout - "$2" -' "$WRAPPER"; then
	ok "wrapper: аргументы echo/atinout в кавычках"
else
	fail "wrapper: аргументы без кавычек строка с пробелами/кавычками ломается"
fi

# --- 3) wrapper без лишних телодвижений: ACL не изменён ------------------------
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ACL" 2>/dev/null; then
	ok "ACL: валидный JSON"
else
	fail "ACL: невалидный JSON в $ACL"
fi

if python3 - "$ACL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = d.get('luci-app-atinout', {})
readf = g.get('read', {}).get('file', {})
writef = g.get('write', {}).get('file', {})
r = 'read' in readf.get('/etc/atcommands.user', [])
w = 'write' in writef.get('/etc/atcommands.user', [])
sys.exit(0 if r and w else 1)
PY
then
	ok "ACL: гранты чтения/записи /etc/atcommands.user на месте"
else
	fail "ACL: потеряны гранты /etc/atcommands.user - вкладка «Настройка команд» сломается"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "== ИТОГ: $FAILED проверок провалено"
	exit 1
fi
echo "== ИТОГ: все проверки пройдены"
