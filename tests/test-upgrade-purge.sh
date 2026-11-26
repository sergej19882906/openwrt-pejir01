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

# START=11 - ДО uartmuxd (14) и до стокового mcud (15): иначе стоковый
# демон успевает занять /dev/umxtty* (Zigbee/STM32) и AT-порт.
if grep -q "^START=11" "$INITD"; then
	ok "init-скрипт: START=11 (до uartmuxd=14 и стокового mcud=15)"
else
	fail "init-скрипт: нет START=11"
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

if grep -q "удалены чужие init-скрипты" <<EOF
$out
EOF
then
	ok "helper: сообщает об удалённых чужих init-скриптах"
else
	fail "helper: не сообщает об удалённых чужих скриптах"
fi

# --- приведение конфигурации: сторож AT-порта и swap по UUID --------------
mkdir -p "$WORK/stub"
cat > "$WORK/stub/uci" <<STUB
#!/bin/sh
case "\$1" in
show)
	echo "fstab.@swap[0]=swap"
	echo "fstab.@swap[0].device='/dev/sda2'"
	;;
-q)
	case "\$3" in
	*.uuid) exit 1 ;;
	*.device) echo "/dev/sda2" ;;
	esac
	;;
set)
	echo "SET \$2" >> "$WORK/uci.calls"
	;;
commit)
	echo "COMMIT \$2" >> "$WORK/uci.calls"
	;;
esac
exit 0
STUB
cat > "$WORK/stub/block" <<'STUB'
#!/bin/sh
echo '/dev/sda2: UUID="1234-ABCD" TYPE="swap"'
exit 0
STUB
cat > "$WORK/watch-init" <<STUB
#!/bin/sh
echo "watch \$1" >> "$WORK/watch.calls"
exit 0
STUB
chmod 755 "$WORK/stub/uci" "$WORK/stub/block" "$WORK/watch-init"
rm -f "$WORK/uci.calls" "$WORK/watch.calls"
# Метка чистки удаляется - helper решит, что образ новый, и выполнит
# приведение конфигурации (иначе он выйдет раньше).
rm -f "$WORK/upper/pejir/purge-version"

# Остатки mwan3 в верхнем слое (в образе .63 пакета уже нет, но файлы
# могли остаться: ставили из LuCI или пережили прошивку).
mkdir -p "$WORK/upper/etc/init.d" "$WORK/upper/etc/rc.d" "$WORK/upper/etc/config" \
	 "$WORK/upper/usr/sbin" "$WORK/upper/lib/mwan3" "$WORK/upper/usr/share/luci/menu.d" \
	 "$WORK/upper/www/luci-static/resources/view/mwan3" "$WORK/upper/lib/apk/packages"
for f in etc/init.d/mwan3 etc/rc.d/S19mwan3 etc/config/mwan3 usr/sbin/mwan3 \
	 lib/mwan3/mwan3.sh usr/share/luci/menu.d/luci-app-mwan3.json \
	 www/luci-static/resources/view/mwan3/status.js lib/apk/packages/mwan3.list; do
	printf '#!/bin/sh\n' > "$WORK/upper/$f"
done

out_mig="$(PATH="$WORK/stub:$PATH" \
	PEJIR_PURGE_VERSION_FILE="$WORK/version" \
	PEJIR_PURGE_MARKER="$WORK/upper/pejir/purge-version" \
	PEJIR_PURGE_CMD="$WORK/purge" \
	PEJIR_PURGE_UPPER_DIR="$WORK/upper" \
	PEJIR_AT_WATCH_INIT="$WORK/watch-init" \
		sh "$HELPER" 2>&1)"

if grep -q "watch enable" "$WORK/watch.calls" 2>/dev/null; then
	ok "helper: сторож AT-порта включается в автозапуск после обновления"
else
	fail "helper: сторож AT-порта не включён"
fi

if grep -q "SET fstab.@swap\[0\].uuid=1234-ABCD" "$WORK/uci.calls" 2>/dev/null; then
	ok "helper: секция swap переводится на UUID"
else
	fail "helper: секция swap не переведена на UUID"
	find="$WORK/uci.calls"
	[ -f "$find" ] && sed 's/^/     /' "$find"
fi

if grep -q "COMMIT fstab" "$WORK/uci.calls" 2>/dev/null; then
	ok "helper: изменение fstab зафиксировано (uci commit)"
else
	fail "helper: uci commit fstab не выполнен"
fi

# Проверка Zigbee: helper сообщает о состоянии модуля /dev/umxtty1
# В песочнице /dev/umxtty1 нет, поэтому проверяем сам факт проверки:
# helper обязан упомянуть состояние Zigbee-модуля.
if grep -q "Zigbee: " <<EOF
$out
EOF
then
	ok "helper: проверяет наличие Zigbee-модуля (/dev/umxtty1)"
else
	fail "helper: нет проверки Zigbee-модуля"
fi

# Свежая версия чистки берётся из /rom (в верхнем слое может лежать
# протухшая копия pejir-ovl-purge).
if grep -q "/rom/usr/bin/pejir-ovl-purge" "$HELPER"; then
	ok "helper: чистку запускает из /rom (свежая версия)"
else
	fail "helper: чистка запускается не из /rom"
fi

# Остатки mwan3 должны быть убраны из верхнего слоя: в образе пакета
# уже нет, поэтому его init-скрипт больше не должен запускаться, а меню
# LuCI - показывать страницу mwan3.
MWAN_LEFT=""
for f in etc/init.d/mwan3 etc/rc.d/S19mwan3 etc/config/mwan3 usr/sbin/mwan3 \
	 lib/mwan3/mwan3.sh usr/share/luci/menu.d/luci-app-mwan3.json \
	 www/luci-static/resources/view/mwan3/status.js lib/apk/packages/mwan3.list; do
	[ -e "$WORK/upper/$f" ] && MWAN_LEFT="$MWAN_LEFT $f"
done
if [ -z "$MWAN_LEFT" ]; then
	ok "helper: остатки mwan3 убраны из верхнего слоя"
else
	fail "helper: остатки mwan3 остались:$MWAN_LEFT"
fi

# --- запуск протухшей копии: свежий код берётся из /rom --------------------
# Именно из-за этого остался mwan3 в .63: в верхнем слое лежала копия
# скрипта из прежней версии, и запускалась именно она.
cat > "$WORK/rom-purge" <<'EOF'
#!/bin/sh
echo "СВЕЖАЯ КОПИЯ ИЗ /ROM"
exit 0
EOF
chmod 755 "$WORK/rom-purge"
out_rom="$(PEJIR_ROM_PURGE="$WORK/rom-purge" \
	PEJIR_PURGE_VERSION_FILE="$WORK/version" \
	PEJIR_PURGE_MARKER="$WORK/upper/pejir/purge-version" \
	PEJIR_PURGE_CMD="$WORK/purge" \
	PEJIR_PURGE_UPPER_DIR="$WORK/upper" \
		sh "$HELPER" 2>&1)"
if grep -q "СВЕЖАЯ КОПИЯ" <<EOF
$out_rom
EOF
then
	ok "helper: протухшая копия перезапускает свежий код из /rom"
else
	fail "helper: протухшая копия не перезапускает свежий код из /rom"
	echo "$out_rom" | sed 's/^/     /'
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
