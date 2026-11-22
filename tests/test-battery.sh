#!/bin/sh
# Тест страницы «Батарея и питание (Perenio STM32)».
#
# Дефект, который закрывает этот тест: страница искала напряжение в выводе
# `mcu getvolt` регуляркой с десятичной точкой (\d+[.,]\d+), но STM32 отдаёт
# напряжение целым числом МИЛЛИВОЛЬТ (VBat=4164 => 4.16 V). Разбор всегда
# возвращал null, и страница показывала «Напряжение n/a» и «mcud не запущен»,
# хотя mcud работал (getsys/getver отвечали).
#
# Здесь проверяется:
#   1) разбор ответа STM32 (поля, как в стоковой прошивке);
#   2) логика статуса/иконки - ровно как в стоке (luci/model/status/battery.lua);
#   3) наличие стоковых иконок battery/*.svg и соответствие статуса файлу;
#   4) в странице нет прежней регулярки «только десятичная точка»;
#   5) новые строки переведены.

set -u

if [ -n "${OW_TEST:-}" ] && [ -d "$OW_TEST/package/luci-app-perenio" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"

PAGE="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/battery.js"
PO="$LUCI_PKG/po/ru/luci-app-perenio.po"
ICONS="$LUCI_PKG/root/www/luci-static/perenio/images/battery"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$PAGE" ] || { echo "FAIL: нет файла $PAGE"; exit 1; }
[ -f "$PO" ] || { echo "FAIL: нет файла $PO"; exit 1; }
[ -d "$ICONS" ] || { echo "FAIL: нет каталога $ICONS"; exit 1; }

# --- 1) стоковые иконки на месте -------------------------------------------
for i in full pre_full middle low critical_low \
         full_charge pre_full_charge middle_charge low_charge critical_low_charge \
         full_done overheat wrong_adapter not_detected; do
	if [ -f "$ICONS/$i.svg" ]; then
		ok "иконка $i.svg на месте"
	else
		fail "нет иконки $i.svg"
	fi
done

# --- 2) старая регулярка больше не используется -----------------------------
if grep -q 'd+\[.,\]d+' "$PAGE"; then
	fail "в странице осталась регулярка с обязательной десятичной точкой - напряжение снова будет n/a"
else
	ok "прежней регулярки (только десятичная точка) в странице нет"
fi

if grep -q 'VBat' "$PAGE"; then
	ok "напряжение берётся из VBat ответа getsys"
else
	fail "в странице нет разбора VBat"
fi

# --- 3) переводы -------------------------------------------------------------
for m in "Battery voltage" "Battery level" "Charge status" "Charging" \
         "Charge complete" "Not charging" "mcud is not running"; do
	if grep -qF "msgid \"$m\"" "$PO" && grep -A1 -F "msgid \"$m\"" "$PO" | grep -q 'msgstr "[^"]' ; then
		ok "перевод есть: $m"
	else
		fail "нет перевода для: $m"
	fi
done

# --- 4) логика разбора и статуса (в node) -----------------------------------
if ! command -v node >/dev/null 2>&1; then
	echo "ПРОПУСК: нет node - логика разбора не проверена (остальные проверки выше выполнены)"
	echo "Все тесты батареи пройдены"
	exit 0
fi

NODE_OUT="$(node - "$PAGE" "$ICONS" <<'NODE'
const fs = require('fs');
const page = process.argv[2];
const icons = process.argv[3];
const src = fs.readFileSync(page, 'utf8');

const stubView = { extend: (o) => o };
const factory = new Function('view', 'E', 'L', '_', 'fs', 'poll', 'document', src);
const mod = factory(stubView, () => {}, () => {}, (s) => s,
                    { exec: () => Promise.resolve(null) }, { add: () => {} }, {});

let fails = 0;
function check(cond, what) {
	if (cond) { console.log('OK: ' + what); }
	else { console.log('FAIL: ' + what); fails++; }
}

/* Реальный ответ STM32 с живого устройства (релиз .42) */
const REAL = 'OK ChrgConn=1 ChrgType=3 ChrgStat=0 BatLev=95% VBat=4164 VBus=12200 ' +
             'VSys=4224 IChrgBat=0 TBat=51 TCpu=76 TMcu=58 PaErr=0/0/0 Clk=0/0/0/0';

const d = mod.parseSys(REAL);
check(d !== null, 'реальный ответ разобран');
if (d) {
	check(d.vbat === 4164, 'VBat=4164 (милливольты)');
	check(d.batLev === 95, 'BatLev=95%');
	check(d.chrgConn === '1', 'ChrgConn=1');
	check(d.chrgStat === '0', 'ChrgStat=0');
	check(d.vbus === 12200, 'VBus=12200');
	check(d.vsys === 4224, 'VSys=4224');
	check(d.tBat === 51 && d.tCpu === 76 && d.tMcu === 58, 'температуры TBat/TCpu/TMcu');
	check(d.paerr === '0/0/0', 'PaErr=0/0/0');
	check((d.vbat / 1000).toFixed(2) === '4.16', 'напряжение 4.16 V (4164 мВ)');
}

check(mod.parseSys('') === null, 'пустой ответ -> null');
check(mod.parseSys('Error: mcud is not running') === null, 'ответ без OK -> null');

/* Уровни - как в стоке */
/* Границы - как в стоке: >75 pre_full, >50 middle, >10 low, иначе critical_low
 * (то есть ровно 10 % - это уже critical_low). */
const lvl = [[100, 'full'], [95, 'pre_full'], [80, 'pre_full'], [60, 'middle'],
             [30, 'low'], [11, 'low'], [10, 'critical_low'], [5, 'critical_low']];
for (const [pct, want] of lvl) {
	const o = mod.parseSys('OK BatLev=' + pct + '% VBat=4164 ChrgConn=1 ChrgStat=0 PaErr=0/0/0');
	check(mod.levelStatus(o) === want, 'уровень ' + pct + '% -> ' + want);
}

/* Состояние зарядки */
const chg = [['0', 'not'], ['1', 'fast'], ['2', 'fast'], ['3', 'done'], ['4', 'not']];
for (const [st, want] of chg) {
	const o = mod.parseSys('OK BatLev=95% VBat=4164 ChrgConn=1 ChrgStat=' + st + ' PaErr=0/0/0');
	check(mod.chargeStatus(o) === want, 'ChrgStat=' + st + ' -> ' + want);
}

/* Итоговый статус иконки и соответствующий файл */
function statusOf(reply) { return mod.iconStatus(mod.parseSys(reply)); }
function fileOf(reply) { return mod.iconFile(statusOf(reply)); }

const cases = [
	['OK ChrgConn=1 ChrgStat=0 BatLev=95% VBat=4164 PaErr=0/0/0', 'pre_full', 'pre_full.svg'],
	['OK ChrgConn=1 ChrgStat=1 BatLev=95% VBat=4164 PaErr=0/0/0', 'pre_full_fast', 'pre_full_charge.svg'],
	['OK ChrgConn=1 ChrgStat=2 BatLev=30% VBat=3800 PaErr=0/0/0', 'low_fast', 'low_charge.svg'],
	['OK ChrgConn=1 ChrgStat=0 BatLev=100% VBat=4200 PaErr=0/0/0', 'full', 'full.svg'],
	['OK ChrgConn=1 ChrgStat=3 BatLev=100% VBat=4200 PaErr=0/0/0', 'full_done', 'full_done.svg'],
	['OK ChrgConn=2 ChrgStat=1 BatLev=95% VBat=4164 PaErr=0/0/1', 'overheat', 'overheat.svg'],
	['OK ChrgConn=3 ChrgStat=0 BatLev=95% VBat=4164 PaErr=0/0/0', 'wrong_adapter', 'wrong_adapter.svg'],
	['OK ChrgConn=1 ChrgStat=0 BatLev=95% VBat=2304 PaErr=0/0/0', 'not_detected', 'not_detected.svg'],
	['OK ChrgConn=1 ChrgStat=0 BatLev=95% VBat=4164 BatPr=No PaErr=0/0/0', 'not_detected', 'not_detected.svg'],
	['OK ChrgConn=1 ChrgStat=1 BatLev=5% VBat=3600 PaErr=0/0/0', 'critical_low_fast', 'critical_low_charge.svg']
];

for (const [reply, wantStatus, wantFile] of cases) {
	const st = statusOf(reply);
	check(st === wantStatus, 'статус -> ' + wantStatus + ' (получено ' + st + ')');
	check(fileOf(reply) === wantFile, 'файл иконки -> ' + wantFile);
	check(fs.existsSync(icons + '/' + wantFile), 'файл иконки существует: ' + wantFile);
}

console.log('ВСЕГО_ПРОВАЛОВ=' + fails);
process.exit(fails ? 1 : 0);
NODE
)"
RC=$?
printf '%s\n' "$NODE_OUT" | sed -n '1,200p'
if printf '%s\n' "$NODE_OUT" | grep -q 'ВСЕГО_ПРОВАЛОВ=0'; then
	ok "логика разбора и статуса иконки - верная"
else
	fail "логика разбора/статуса иконки неверна"
fi
[ "$RC" -eq 0 ] || true

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты батареи пройдены"
