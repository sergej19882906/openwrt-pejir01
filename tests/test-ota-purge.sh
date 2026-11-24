#!/bin/sh
# Тест: OTA-помощник чистит верхний слой overlay ДО sysupgrade.
#
# Дефект, который закрывает тест.
#
# При sysupgrade верхний слой overlay (rootfs_data) НЕ пересоздаётся
# (патч 0037), а бэкап -c собирает ВСЕ файлы из /overlay/upper/etc
# (список packagesfiles строится только для режима -o, для -c он пуст).
# Значит протухшая копия файла нашего пакета - например старый
# /etc/init.d/40-pejir-sms или ACL luci-app-perenio без гранта exec на
# /rom/usr/libexec/perenio-diag - попадает в sysupgrade.tgz и после
# прошивки восстанавливается поверх нового образа СНОВА. Свежие файлы
# из squashfs так и не видны: диагностика в LuCI не работает, USSD
# отдаёт мусор, авто-режим индикации стирается при загрузке.
#
# Очистка должна идти ДО sysupgrade: после sysupgrade верхний слой уже
# не пересоздаётся, и удалять из него поздно.
#
# Тест проверяет ПОВЕДЕНИЕ: запускает cmd_flash() в песочнице с
# подменёнными sysupgrade/wget и смотрит, что очистка была выполнена и
# что она произошла ДО вызова sysupgrade, который создаёт бэкап.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"
OTA="$TREE/package/pejir-ota/files/pejir-ota"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$OTA" ] || { echo "FAIL: нет файла $OTA"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/bin"

# Подменяем sysupgrade: он записывает в журнал порядок вызовов.
# Проверка образа (--test) и реальная прошивка помечены по-разному:
# бэкап создаёт только реальная прошивка.
cat > "$WORK/bin/sysupgrade" <<'STUBEOF'
#!/bin/sh
case "$1" in
--test) echo "sysupgrade-test" >> "$PEJIR_TEST_ORDER" ;;
*)      echo "sysupgrade-flash" >> "$PEJIR_TEST_ORDER" ;;
esac
exit 0
STUBEOF
chmod 755 "$WORK/bin/sysupgrade"

# Подменяем wget: "скачиваем" непустой файл образа и sha256sums.
cat > "$WORK/bin/wget" <<'STUBEOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
	case "$1" in
	-O) out="$2"; shift 2 ;;
	*) shift ;;
	esac
done
[ -n "$out" ] && printf 'stub\n' > "$out"
exit 0
STUBEOF
chmod 755 "$WORK/bin/wget"

# Подменяем helper очистки: он отмечает вызов в журнале порядка.
cat > "$WORK/bin/pejir-ovl-purge" <<'STUBEOF'
#!/bin/sh
echo "ovl-purge" >> "$PEJIR_TEST_ORDER"
exit 0
STUBEOF
chmod 755 "$WORK/bin/pejir-ovl-purge"

ORDER="$WORK/order.txt"
: > "$ORDER"

# Готовим копию OTA-помощника для песочницы:
#   * пути конфига/журнала/состояния/рабочего каталога -> в $WORK;
#   * отбрасываем строку ". /lib/functions.sh" - её нет в песочнице;
#   * отбрасываем нижний блок разбора команды (case в конце) - он
#     завершил бы скрипт при sourced.
sed -e "s#^CFG=.*#CFG=\"pejir_ota\"#" \
    -e "s#^WORK=.*#WORK=\"$WORK/ota-work\"#" \
    -e "s#^LOG=.*#LOG=\"$WORK/ota.log\"#" \
    -e "s#^STATE=.*#STATE=\"$WORK/ota.state\"#" \
    -e 's#^\. /lib/functions\.sh$#:#' \
    "$OTA" | sed '/^case "\${1:-}" in/,$d' > "$WORK/ota.sh"

mkdir -p "$WORK/ota-work"

PEJIR_TEST_ORDER="$ORDER" \
PATH="$WORK/bin:$PATH" \
	bash -c '
		. "$1"
		# Заглушки: uci в песочнице нет, тег релиза фиксирован.
		cfgval() { :; }
		latest_tag() { echo "v25.12.6-pejir01.50"; }
		# Проверка контрольной суммы не должна мешать тесту.
		sha256sum() { cat >/dev/null; echo "ok  -"; }
		cmd_flash
	' _ "$WORK/ota.sh" > "$WORK/out.txt" 2>&1
RC=$?

if [ "$RC" -eq 0 ]; then
	ok "cmd_flash() отработал без ошибки"
else
	fail "cmd_flash() завершился с кодом $RC: $(tail -3 "$WORK/out.txt" | tr '\n' ' ')"
fi

# --- 1) очистка была выполнена -------------------------------------------
if grep -q "^ovl-purge" "$ORDER"; then
	ok "helper очистки верхнего слоя вызван"
else
	fail "helper очистки верхнего слоя НЕ вызван - протухшие копии переживут прошивку"
fi

# --- 2) очистка произошла ДО прошивки (до создания бэкапа) ---------------
PURGE_LINE="$(grep -n "^ovl-purge" "$ORDER" | head -1 | cut -d: -f1)"
FLASH_LINE="$(grep -n "^sysupgrade-flash" "$ORDER" | head -1 | cut -d: -f1)"

if [ -z "$FLASH_LINE" ]; then
	fail "sysupgrade (прошивка) не вызван - тест ничего не проверил"
elif [ -z "$PURGE_LINE" ]; then
	fail "очистка не найдена в журнале порядка"
elif [ "$PURGE_LINE" -lt "$FLASH_LINE" ]; then
	ok "очистка выполнена ДО прошивки (строка $PURGE_LINE < $FLASH_LINE)"
else
	fail "очистка выполнена ПОСЛЕ прошивки (строка $PURGE_LINE > $FLASH_LINE) - в бэкап попадут протухшие копии"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты очистки overlay перед прошивкой пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
