#!/bin/sh
# Тест автономной очистки верхнего слоя после sysupgrade.
#
# Зачем. sysupgrade не пересоздаёт верхний слой, поэтому остатки старой
# прошивки (а при переходе со стока - файлы стоковых пакетов) переживают
# обновление. Раньше чистка шла только перед OTA-обновлением через нашу
# страницу, и прошивка, поставленная через системное меню LuCI, оставляла
# мусор (init-скрипты стокового modem и pmwan забирают AT-порт и LTE).
#
# Теперь чистка выполняется сама при первой загрузке после любого
# sysupgrade: версия образа (/usr/lib/pejir/version) сверяется с меткой
# последней чистки (/overlay/pejir/purge-version).
#
# Проверяем:
#   1) helper чистит верхний слой, когда версия образа изменилась;
#   2) повторный запуск при той же версии ничего не делает;
#   3) helper и init-скрипт ставятся в образ, init-скрипт имеет
#      START=91 и собственный start() (в OpenWrt start_service() без
#      USE_PROCD не вызывается - патч 0085).

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"

HELPER="$TREE/package/pejir-ota/files/pejir-upgrade-purge"
INITD="$TREE/package/pejir-ota/root/etc/init.d/42-pejir-upgrade-purge"
MAKEFILE="$TREE/package/pejir-ota/Makefile"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$HELPER" "$INITD"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
	sh -n "$f" 2>/dev/null || fail "$(basename "$f"): ошибка синтаксиса"
done
ok "файлы на месте, синтаксис корректен"

if grep -q "pejir-upgrade-purge" "$MAKEFILE" && grep -q "42-pejir-upgrade-purge" "$MAKEFILE"; then
	ok "Makefile: helper и init-скрипт ставятся в образ"
else
	fail "Makefile: helper или init-скрипт не ставятся в образ"
fi

if grep -q "^START=91" "$INITD"; then
	ok "init-скрипт: START=91 (после pejir-sync, до модема и LTE)"
else
	fail "init-скрипт: нет START=91"
fi

if grep -q "^start()" "$INITD"; then
	ok "init-скрипт: свой start() (start_service() без USE_PROCD не вызывается)"
else
	fail "init-скрипт: нет собственного start()"
fi

# --- поведение helper'а ----------------------------------------------------
WORK=/tmp/upgrade-purge-test
rm -rf "$WORK"
mkdir -p "$WORK/upper/etc/init.d" "$WORK/etc"

# мок pejir-ovl-purge: отмечает вызов и убирает "чужие" файлы
cat > "$WORK/purge" <<'EOF'
#!/bin/sh
echo "вызван" >> /tmp/upgrade-purge-test/purge.calls
rm -f /tmp/upgrade-purge-test/upper/etc/init.d/modem
rm -f /tmp/upgrade-purge-test/upper/etc/init.d/pmwan
echo "pejir-ovl-purge: удалено 2"
exit 0
EOF
chmod +x "$WORK/purge"

printf '#!/bin/sh\n' > "$WORK/upper/etc/init.d/modem"
printf '#!/bin/sh\n' > "$WORK/upper/etc/init.d/pmwan"
printf '25.12.6-pejir01.58\n' > "$WORK/version"

run_helper() {
	PEJIR_PURGE_VERSION_FILE="$WORK/version" \
	PEJIR_PURGE_MARKER="$WORK/upper/pejir/purge-version" \
	PEJIR_PURGE_CMD="$WORK/purge" \
	PEJIR_PURGE_UPPER_DIR="$WORK/upper" \
		sh "$HELPER" 2>&1
}

out="$(run_helper)"
if grep -q "чищу верхний слой" <<EOF
$out
EOF
then
	ok "helper: при новой версии чистка выполняется"
else
	fail "helper: чистка не запустилась при новой версии"
	echo "$out" | sed 's/^/     /'
fi

if [ -f "$WORK/purge.calls" ]; then
	ok "helper: pejir-ovl-purge вызван"
else
	fail "helper: pejir-ovl-purge не вызван"
fi

if [ -f "$WORK/upper/pejir/purge-version" ] && grep -q "pejir01.58" "$WORK/upper/pejir/purge-version"; then
	ok "helper: метка версии записана в верхний слой"
else
	fail "helper: метка версии не записана"
fi

if [ ! -e "$WORK/upper/etc/init.d/modem" ]; then
	ok "helper: остатки стоковых скриптов удалены"
else
	fail "helper: остатки стоковых скриптов не удалены"
fi

if grep -q "нужна перезагрузка" <<EOF
$out
EOF
then
	ok "helper: сообщает о необходимости перезагрузки (чужие скрипты уже стартовали)"
else
	fail "helper: не сообщает о перезагрузке"
fi

# --- повторный запуск при той же версии - ничего не делает -----------------
rm -f "$WORK/purge.calls"
out2="$(run_helper)"
if [ ! -f "$WORK/purge.calls" ]; then
	ok "helper: повторный запуск при той же версии ничего не чистит"
else
	fail "helper: повторный запуск всё равно вызвал чистку"
fi

# --- смена версии = новая чистка -------------------------------------------
printf '25.12.6-pejir01.59\n' > "$WORK/version"
rm -f "$WORK/purge.calls"
out3="$(run_helper)"
if [ -f "$WORK/purge.calls" ]; then
	ok "helper: после смены версии образа чистка выполняется снова"
else
	fail "helper: после смены версии чистка не выполнилась"
fi

rm -rf "$WORK"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты автоочистки пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
