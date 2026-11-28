#!/bin/sh
# Тест: страница SMS читает переписку одним запросом, а не сотней.
#
# Дефект, который закрывает тест: страница делала fs.list каталога плюс
# fs.read каждого файла очереди - до 120 запросов к rpcd за один цикл
# опроса (20 секунд). На телефоне страница заметно "тупила". Теперь всю
# переписку отдаёт helper одним вызовом (pejir-sms-ctl dump), и список
# AT-портов берётся у helper'а, а не через fs.list('/dev') (там тысячи
# записей).

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

PAGE="$DEFAULT_TREE/package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/sms.js"
CTL="$DEFAULT_TREE/package/pejir-sms/root/usr/libexec/pejir-sms-ctl"

[ -f "$PAGE" ] || { echo "FAIL: нет файла $PAGE"; exit 1; }
[ -f "$CTL" ] || { echo "FAIL: нет файла $CTL"; exit 1; }

# --- страница -------------------------------------------------------------
grep -q "readSpoolAll" "$PAGE" \
	&& ok "есть единая функция чтения очереди" \
	|| fail "нет единой функции чтения очереди"

grep -qE "fs\.exec\(SMSCTL, *\[ *'dump' *\]" "$PAGE" \
	&& ok "переписка читается одной командой helper'а (dump)" \
	|| fail "переписка не читается одной командой helper'а"

if grep -qE "fs\.read\((DIR|DIR_OUT|DIR_SENT|DIR_FAILED)" "$PAGE"; then
	fail "страница читает файлы очереди по одному - это десятки запросов к rpcd"
else
	ok "страница не читает файлы очереди по одному"
fi

if grep -q "fs.list('/dev')" "$PAGE"; then
	fail "страница запрашивает весь /dev через fs.list - это тысячи записей"
else
	ok "список /dev больше не запрашивается"
fi

grep -q "fs.exec(SMSCTL, \[ 'ports' \])" "$PAGE" \
	&& ok "AT-порты берутся у helper'а (ports)" \
	|| fail "AT-порты не берутся у helper'а"

# --- helper ---------------------------------------------------------------
grep -q "cmd_dump()" "$CTL" \
	&& ok "у helper'а есть команда dump" \
	|| fail "у helper'а нет команды dump"

grep -q "cmd_ports()" "$CTL" \
	&& ok "у helper'а есть команда ports" \
	|| fail "у helper'а нет команды ports"

grep -q "dump)         cmd_dump" "$CTL" \
	&& ok "команда dump подключена в разбор команд" \
	|| fail "команда dump не подключена"

grep -q "ports)        cmd_ports" "$CTL" \
	&& ok "команда ports подключена в разбор команд" \
	|| fail "команда ports не подключена"

# Служебные файлы сборки многочастевых PDU в выгрузку не попадают.
grep -q '\*-concatenated) continue' "$CTL" \
	&& ok "helper пропускает файлы *-concatenated" \
	|| fail "helper не пропускает файлы *-concatenated"

# --- функциональная проверка helper'а ------------------------------------
WORK="${PEJIR_SMS_DUMP_TEST:-/tmp/pejir-sms-dump-test}"
rm -rf "$WORK"
mkdir -p "$WORK/pool/incoming" "$WORK/pool/sent"

printf '+79991234567\n2026-11-28 10:00:00\nПривет\n' > "$WORK/pool/incoming/GM510.aaa"
printf '+79997654321\n2026-11-27 09:00:00\nПока\n' > "$WORK/pool/incoming/GM510.bbb"
printf 'мусор\n' > "$WORK/pool/incoming/GM510-concatenated"
printf 'отправлено\n' > "$WORK/pool/sent/GM510.ccc"

out="$(PEJIR_SPOOL_POOL="$WORK/pool" sh "$CTL" dump 2>/dev/null)"

printf '%s' "$out" | grep -q "@@MSG	incoming	GM510.aaa" \
	&& ok "в выгрузке есть входящее сообщение" \
	|| fail "в выгрузке нет входящего сообщения"

printf '%s' "$out" | grep -q "Привет" \
	&& ok "текст сообщения попал в выгрузку" \
	|| fail "текст сообщения не попал в выгрузку"

printf '%s' "$out" | grep -q "GM510-concatenated" \
	&& fail "служебный файл сборки попал в выгрузку" \
	|| ok "служебный файл сборки в выгрузку не попал"

printf '%s' "$out" | grep -q "@@MSG	sent	GM510.ccc" \
	&& ok "в выгрузке есть отправленное сообщение" \
	|| fail "в выгрузке нет отправленного сообщения"

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
