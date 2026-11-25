#!/bin/sh
# Тест определения семейства LTE-модема и профилей AT-команд.
#
# Зачем. Порт заточен под ZTE/Gosuncn-набор (AT+ZECMCALL, AT+ZBAND,
# AT+ZRST). Модемы других семейств требуют других команд:
#   * Fibocom L8 (L850/L860) - данные по USB-NCM, PDP-контекст
#     поднимается AT+CGACT=1,1, полосы - AT+XACT, сброс - AT+CFUN=1,1;
#   * Quectel (EC25/EP06) - данные по USB (NCM/RNDIS), PDP-контекст
#     AT+CGACT=1,1, полосы - AT+QCFG="band", режим сети -
#     AT+QCFG="nwscanseq", сброс - AT+CFUN=1,1.
#
# Проверяем:
#   1) helper определяет семейство по AT+GMM / AT+CGMI / AT+CGMM;
#   2) результат кэшируется в /etc/pejir/modem-family;
#   3) 47-pejir-lte шлёт AT+CGACT для fibocom/quectel и AT+ZECMCALL для zte;
#   4) pejir-modem-ctl шлёт AT+CFUN=1,1 для fibocom/quectel и AT+ZRST для zte;
#   5) pejir-modem-ctl шлёт AT+QCFG="nwscanseq" для quectel.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"

FAMILY="$TREE/package/pejir-lte-base/root/usr/libexec/pejir-modem-family"
LTE_INIT="$TREE/package/pejir-lte-base/root/etc/init.d/47-pejir-lte"
MODEMCTL="$TREE/package/pejir-lte-base/root/usr/libexec/pejir-modem-ctl"
MAKEFILE="$TREE/package/pejir-lte-base/Makefile"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$FAMILY" "$LTE_INIT" "$MODEMCTL"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
	sh -n "$f" 2>/dev/null || fail "$(basename "$f"): ошибка синтаксиса"
done
ok "файлы на месте, синтаксис корректен"

# helper ставится в образ
if grep -q "pejir-modem-family" "$MAKEFILE"; then
	ok "Makefile: helper pejir-modem-family ставится в образ"
else
	fail "Makefile: helper pejir-modem-family не ставится в образ"
fi

WORK=/tmp/modem-family-test
rm -rf "$WORK"
mkdir -p "$WORK"

# --- 1) определение семейства по ответу модема ----------------------------
# Мок модема: $1 - ответ на AT+GMM, $2 - на AT+CGMI, $3 - на AT+CGMM.
probe() {
	cat > "$WORK/probe" <<EOF
#!/bin/sh
case "\$1" in
'AT+CGMI') echo "$2" ;;
'AT+GMM')  echo "$1" ;;
'AT+CGMM') echo "$3" ;;
esac
exit 0
EOF
	chmod +x "$WORK/probe"
}

check_family() {
	# $1 - ожидаемое семейство, $2 - ответ AT+GMM, $3 - AT+CGMI, $4 - AT+CGMM
	probe "$2" "$3" "$4"
	out="$(PEJIR_FAMILY_PROBE="$WORK/probe" PEJIR_FAMILY_CACHE="$WORK/cache" \
		sh "$FAMILY" 2>/dev/null)"
	if [ "$out" = "$1" ]; then
		ok "семейство '$1' определено по ответу модема ($2 / $3)"
	else
		fail "ожидалось семейство '$1', получено '$out' ($2 / $3)"
	fi
	rm -f "$WORK/cache"
}

check_family quectel "EC25" "Quectel" "EC25"
check_family quectel "EP06" "Quectel" "EP06"
check_family quectel "EC20" "Quectel" "EC20"
check_family fibocom "L860" "Fibocom" "L860"
check_family fibocom "L850" "Fibocom" "L850"
check_family zte "GM510" "GOSUNCN" "GM510"
check_family zte "GN510" "GOSUNCN" "GN510"
check_family zte "MF667" "ZTE" "MF667"
check_family unknown "SOMETHING" "unknown-vendor" "SOMETHING"

# --- 2) кэширование --------------------------------------------------------
probe "EC25" "Quectel" "EC25"
PEJIR_FAMILY_PROBE="$WORK/probe" PEJIR_FAMILY_CACHE="$WORK/cache" sh "$FAMILY" >/dev/null 2>&1
if [ -f "$WORK/cache" ] && grep -q quectel "$WORK/cache"; then
	ok "результат кэшируется в /etc/pejir/modem-family"
else
	fail "результат не кэшируется"
fi

# --- 3) LTE: команда data call по семейству -------------------------------
if grep -q 'AT+CGACT=1,1' "$LTE_INIT"; then
	ok "47-pejir-lte: для fibocom/quectel - PDP-контекст через AT+CGACT=1,1"
else
	fail "47-pejir-lte: нет ветки AT+CGACT=1,1"
fi
if grep -q 'AT+ZECMCALL=1' "$LTE_INIT"; then
	ok "47-pejir-lte: для zte сохранён AT+ZECMCALL=1"
else
	fail "47-pejir-lte: пропала команда AT+ZECMCALL"
fi
if grep -q 'AT+QCFG="band"' "$LTE_INIT"; then
	ok "47-pejir-lte: для quectel полосы через AT+QCFG=band"
else
	fail "47-pejir-lte: нет ветки AT+QCFG=band"
fi
if grep -q 'AT+XACT=2' "$LTE_INIT"; then
	ok "47-pejir-lte: для fibocom полосы через AT+XACT"
else
	fail "47-pejir-lte: нет ветки AT+XACT"
fi

# --- 4) modem-ctl: сброс по семейству -------------------------------------
if grep -q 'AT+CFUN=1,1' "$MODEMCTL"; then
	ok "pejir-modem-ctl: сброс для fibocom/quectel через AT+CFUN=1,1"
else
	fail "pejir-modem-ctl: нет AT+CFUN=1,1"
fi
if grep -q 'AT+ZRST' "$MODEMCTL"; then
	ok "pejir-modem-ctl: для zte сохранён AT+ZRST"
else
	fail "pejir-modem-ctl: пропала команда AT+ZRST"
fi

# --- 5) modem-ctl: режим канала для quectel -------------------------------
if grep -q 'nwscanseq' "$MODEMCTL"; then
	ok "pejir-modem-ctl: режим канала для quectel через AT+QCFG=nwscanseq"
else
	fail "pejir-modem-ctl: нет режима nwscanseq"
fi

rm -rf "$WORK"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты семейств модема пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
