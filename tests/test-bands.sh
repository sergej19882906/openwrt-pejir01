#!/bin/sh
# Тест настройки диапазонов 3G/4G (как в стоковой прошивке).
#
# Сток Perenio (GOSUNCN, /usr/lib/modem_ubus/gosuncn.sh) задаёт
# диапазоны модема GM510 командой
#   AT+ZBAND=<UMTS>,0,0,<LTE>
# где UMTS и LTE - битовые маски. Список диапазонов хранится в UCI:
#   network.lte.perenio_band
#
# Здесь проверяется, что:
#   1) маски диапазонов совпадают со стоковыми (эталон - значения из
#      gosuncn.sh стоковой прошивки);
#   2) helper /usr/libexec/pejir-band умеет применить настройку;
#   3) init-скрипт LTE применяет диапазоны при старте;
#   4) в ACL есть грант exec на helper, а в меню - пункт страницы;
#   5) страница не содержит кириллицы внутри _() (msgid - английские).

set -u

if [ -n "${OW_TEST:-}" ]; then
	# В CI OW_TEST всегда задан: если нужного пакета в дереве нет - это
	# ошибка, а не повод молча искать пакет в /workspace/ow-test.
	DEFAULT_PKG="$OW_TEST/package/pejir-lte-base"
	DEFAULT_LUCI_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
	[ -d "$DEFAULT_LUCI_PKG" ] || { echo "FAIL: нет $DEFAULT_LUCI_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/pejir-lte-base"
	DEFAULT_LUCI_PKG="/workspace/ow-test/package/luci-app-perenio"
fi
LTE_PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_LUCI_PKG}"

BANDS_SH="$LTE_PKG/root/usr/share/pejir/bands.sh"
HELPER="$LTE_PKG/root/usr/libexec/pejir-band"
INITD="$LTE_PKG/root/etc/init.d/47-pejir-lte"
ACL="$LUCI_PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
MENU="$LUCI_PKG/root/usr/share/luci/menu.d/luci-app-perenio.json"
PAGE="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/bands.js"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$BANDS_SH" "$HELPER" "$INITD" "$ACL" "$MENU" "$PAGE"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) маски совпадают со стоком -----------------------------------------
# эталон из стоковой прошивки (gosuncn.sh)
cat > /tmp/pejir-band-exp.$$ <<'EOF'
umts01=0x400000
umts08=0x2000000000000
lte01=0x1
lte03=0x4
lte07=0x40
lte08=0x80
lte20=0x80000
lte38=0x2000000000
EOF

if . "$BANDS_SH" && . /tmp/pejir-band-exp.$$; then
	mismatch=""
	for b in umts01 umts08 lte01 lte03 lte07 lte08 lte20 lte38; do
		ours=$(pejir_bands_mask "$b")
		eval "exp=\$$b"
		# сравниваем числа (наш эталон - без префикса 0x)
		[ "$((0x$ours))" = "$((exp))" ] || mismatch="$mismatch $b($ours!=$exp)"
	done
	if [ -z "$mismatch" ]; then
		ok "маски диапазонов совпадают со стоковой прошивкой"
	else
		fail "маски не совпадают со стоком:$mismatch"
	fi

	# расчёт масок для комбинаций
	if [ "$(pejir_bands_calc allBands)" = "all all" ]; then
		ok "allBands -> маски all/all (команда AT+ZBAND=all,0,0,all)"
	else
		fail "allBands -> $(pejir_bands_calc allBands), ожидалось all all"
	fi

	if [ "$(pejir_bands_calc lte01 lte03)" = "0 5" ]; then
		ok "lte01+lte03 -> маска 5"
	else
		fail "lte01+lte03 -> $(pejir_bands_calc lte01 lte03), ожидалось 0 5"
	fi
else
	fail "не удалось подключить bands.sh"
fi
rm -f /tmp/pejir-band-exp.$$

# --- 2) helper -------------------------------------------------------------
if grep -q "AT+ZBAND=" "$HELPER"; then
	ok "helper: отправляет AT+ZBAND="
else
	fail "helper: нет команды AT+ZBAND="
fi

if grep -q "network.lte.perenio_band" "$HELPER"; then
	ok "helper: читает network.lte.perenio_band"
else
	fail "helper: не читает network.lte.perenio_band"
fi

if grep -q "stty .*|| true" "$HELPER"; then
	ok "helper: ошибка stty не фатальна (на устройстве stty всегда падает)"
else
	fail "helper: stty может прервать обмен"
fi

sh -n "$HELPER" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"

# --- 3) init-скрипт LTE ----------------------------------------------------
if grep -q "sync_bands" "$INITD"; then
	ok "47-pejir-lte: применяет диапазоны (sync_bands)"
else
	fail "47-pejir-lte: не применяет диапазоны"
fi

# --- 4) ACL и меню ---------------------------------------------------------
if python3 - "$ACL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = d.get('luci-app-perenio', {})
paths = g.get('write', {}).get('file', {})
sys.exit(0 if 'exec' in paths.get('/usr/libexec/pejir-band', []) else 1)
PY
then
	ok "ACL: есть грант exec на /usr/libexec/pejir-band"
else
	fail "ACL: нет гранта exec на /usr/libexec/pejir-band"
fi

if python3 -c "
import json,sys
d=json.load(open('$ACL'))['luci-app-perenio']
sys.exit(0 if 'network' in d.get('read',{}).get('uci',[]) else 1)"; then
	ok "ACL: есть доступ на чтение uci network"
else
	fail "ACL: нет доступа на чтение uci network"
fi

if python3 -c "
import json,sys
d=json.load(open('$MENU'))
sys.exit(0 if 'admin/status/perenio-bands' in d else 1)"; then
	ok "меню: есть пункт 'Диапазоны 3G/4G'"
else
	fail "меню: нет пункта 'Диапазоны 3G/4G'"
fi

# --- 5) страница -----------------------------------------------------------
if python3 - "$PAGE" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
bad = [m for m in re.findall(r"_\(\s*'((?:[^'\\]|\\.)*)'", s) if re.search(r'[А-Яа-я]', m)]
for m in bad:
    print("  кириллица в msgid: %r" % m)
sys.exit(1 if bad else 0)
PY
then
	ok "страница: msgid английские"
else
	fail "страница: кириллица внутри _()"
fi

for pat in "pejir-band" "perenio_band" "AT+ZBAND"; do
	if grep -qF "$pat" "$PAGE"; then
		ok "страница: есть '$pat'"
	else
		fail "страница: нет '$pat'"
	fi
done

# --- 6) сборка: файлы ставятся в образ ------------------------------------
if grep -q "bands.sh" "$LTE_PKG/Makefile"; then
	ok "Makefile pejir-lte-base: bands.sh ставится в образ"
else
	fail "Makefile pejir-lte-base: bands.sh не ставится в образ"
fi

if grep -q "pejir-band" "$LTE_PKG/Makefile"; then
	ok "Makefile pejir-lte-base: helper pejir-band ставится в образ"
else
	fail "Makefile pejir-lte-base: helper pejir-band не ставится в образ"
fi

if grep -q "pejir-lte-base" "$LUCI_PKG/Makefile"; then
	ok "Makefile luci-app-perenio: зависит от pejir-lte-base (helper доступен)"
else
	fail "Makefile luci-app-perenio: нет зависимости от pejir-lte-base"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты диапазонов пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
