#!/bin/sh
# Тест разбора файлов сообщений smstools3 на странице SMS.
#
# Дефект, который закрывает этот тест. Файл сообщения smstools3 устроен
# так:
#
#     From: +79990000000
#     Date: 2026-11-26 06:10:00
#     Alphabet: UTF-8
#     NOTICE: Cannot convert 1. character (D0B8) to GSM.
#
#     +79990000000
#     2026-11-26 06:10:00
#     Привет
#
# Раньше страница брала номер из ПЕРВОЙ строки, дату - из ВТОРОЙ, а
# текстом считала всё остальное. Значит в поле номера попадало
# "From: +79990000000", а в текст сообщения - заголовки и служебные
# строки NOTICE. Пользователь видел в переписке мусор.
#
# Проверяется поведение разбора (в node, не grep по исходнику):
#   1) номер и дата берутся из заголовков, текст - из тела;
#   2) строки NOTICE не попадают в текст сообщения;
#   3) старый формат без заголовков (номер, дата, текст) тоже понимается;
#   4) в файле без заголовков пустая строка внутри текста не ломает разбор.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"

JS="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/sms.js"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$JS" ] || { echo "FAIL: нет файла $JS"; exit 1; }

if command -v node >/dev/null 2>&1; then
	ok "node доступен"
else
	fail "node не найден - поведение разбора проверить нечем"
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/check.js" <<'JS'
'use strict';
const fs = require('fs');

const src = fs.readFileSync(process.argv[2], 'utf-8');

// Достаём функцию разбора из исходника страницы.
const m = src.match(/function parseMessage\(txt\) \{[\s\S]*?\n\}/);
if (!m) {
	console.log('FAIL: в sms.js нет функции parseMessage');
	process.exit(1);
}
const parseMessage = eval('(' + m[0].replace(/^function parseMessage/, 'function') + ')');

let fails = 0;
function check(name, cond, detail) {
	if (cond) {
		console.log('OK: ' + name);
	}
	else {
		console.log('FAIL: ' + name + (detail ? ' (' + detail + ')' : ''));
		fails++;
	}
}

// 1) Современный файл: заголовки + пустая строка + тело.
const modern = [
	'From: +79990000000',
	'Date: 2026-11-26 06:10:00',
	'Alphabet: UTF-8',
	'NOTICE: Cannot convert 1. character (D0B8) to GSM.',
	'NOTICE: 5 characters outside the GSM alphabet, converting to UCS2',
	'',
	'+79990000000',
	'2026-11-26 06:10:00',
	'Привет, это проверка'
].join('\n');

const r1 = parseMessage(modern);
check('номер взят из заголовка From', r1.from === '+79990000000', r1.from);
check('дата взята из заголовка Date', r1.date === '2026-11-26 06:10:00', r1.date);
check('текст - только тело сообщения', r1.text === 'Привет, это проверка', JSON.stringify(r1.text));
check('в тексте нет строк NOTICE', r1.text.indexOf('NOTICE') === -1, r1.text);
check('в тексте нет заголовков', r1.text.indexOf('Alphabet') === -1, r1.text);

// 2) Старый формат: без заголовков (номер, дата, текст).
const old = [
	'+79990000000',
	'2026-11-26 06:10:00',
	'Привет, это старый формат'
].join('\n');

const r2 = parseMessage(old);
check('старый формат: номер разобран', r2.from === '+79990000000', r2.from);
check('старый формат: дата разобрана', r2.date === '2026-11-26 06:10:00', r2.date);
check('старый формат: текст разобран', r2.text === 'Привет, это старый формат', JSON.stringify(r2.text));

// 3) Файл без заголовков, где в тексте есть пустая строка:
//    номер и дата не должны потеряться.
const withBlank = [
	'+79990000000',
	'2026-11-26 06:10:00',
	'Первая строка',
	'',
	'Вторая строка'
].join('\n');

const r3 = parseMessage(withBlank);
check('пустая строка в теле не ломает разбор (номер)', r3.from === '+79990000000', r3.from);
check('пустая строка в теле не ломает разбор (текст)', r3.text.indexOf('Вторая строка') !== -1, JSON.stringify(r3.text));

// 4) Пустой файл - не падаем.
const r4 = parseMessage('');
check('пустой файл не ломает разбор', r4.from === '' && r4.text === '', JSON.stringify(r4));

// 5) Реальный файл с устройства (GM510, 26-11-26): заголовки со
//    служебными полями, пустая строка, тело. Дата лежит в "Sent:".
const real = [
	'From: 375293146555',
	'From_TOA: 91 international, ISDN/telephone',
	'From_SMSC: 375296009014',
	'Sent: 26-11-26 01:24:27',
	'Received: 26-11-26 01:24:35',
	'Subject: GM510',
	'Modem: GM510',
	'IMSI: 257010017540604',
	'IMEI: 862784042920880',
	'Report: no',
	'Alphabet: UTF-8',
	'Length: 13',
	'',
	'Текст сообщения'
].join('\n');

const r5 = parseMessage(real);
check('реальный формат: номер взят из From', r5.from === '375293146555', r5.from);
check('реальный формат: дата взта из Sent', r5.date === '26-11-26 01:24:27', r5.date);
check('реальный формат: текст - только тело', r5.text === 'Текст сообщения', JSON.stringify(r5.text));
check('реальный формат: служебные заголовки не в тексте',
	r5.text.indexOf('IMSI') === -1 && r5.text.indexOf('Alphabet') === -1, r5.text);

// 6) Служебный файл smstools3 "<модем>-concatenated" - это сборка
//    многочастевых PDU, а не сообщение: номера и даты у него нет.
const concatenated = [
	'06 08 04 21 A9 03 03 07917325690009416006D0C118083408621152114483213906080421CA030300630063007000610079002D006D0079006100310020002804400430043704340435043B0020042104470435044204300029'
].join('\n');
const r6 = parseMessage(concatenated);
check('concatenated-файл: номер пустой', r6.from === '', r6.from);
check('concatenated-файл: дата пустая', r6.date === '', r6.date);

process.exit(fails ? 1 : 0);
JS

if node "$WORK/check.js" "$JS"; then
	ok "разбор файлов сообщений smstools3 - верный"
else
	fail "разбор файлов сообщений smstools3 - неверный"
fi

# Страница не должна брать номер и дату из первых строк файла:
# там заголовки ("From:", "Date:").
if grep -q "from: lines\[0\]" "$JS" || grep -q "date: lines\[1\]" "$JS"; then
	fail "в странице номер и дата по-прежнему берутся из первых строк файла"
else
	ok "страница не берёт номер и дату из первых строк файла"
fi

# Служебный файл smstools3 "<модем>-concatenated" (сборка многочастевых
# PDU) не должен попадать в переписку: на устройстве он выглядел как
# мусорный элемент без номера и даты. С 0173 переписку отдаёт helper
# одним блоком, поэтому отсекать служебные файлы должен именно он.
SMSCTL="${OW_TEST:-/workspace/ow-test}/package/pejir-sms/root/usr/libexec/pejir-sms-ctl"
if [ -f "$SMSCTL" ] && grep -q "concatenated" "$SMSCTL"; then
	ok "helper отсекает служебный файл *-concatenated"
else
	fail "helper не отсекает служебный файл *-concatenated (в переписке будет мусор)"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты разбора SMS прошли"
