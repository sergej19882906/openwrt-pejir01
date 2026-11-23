#!/bin/sh
# Тест самовосстановления файлов пакетов из /rom.
#
# Дефект, который закрывает тест: после sysupgrade верхний слой overlay
# НЕ пересоздаётся (патч 0037), поэтому все файлы, которые когда-либо
# клались в /overlay/upper, переживают прошивку. Ранние горячие фиксы
# (apply_fixes.sh, led_hotfix.sh, battery_hotfix.sh) копировали туда
# целые каталоги с файлами пакетов - версии .45.
#
# Итог: на устройстве после обновления до .46/.48 merged-файлы пакетов
# были старыми:
#   * /etc/init.d/40-pejir-sms - старая версия (лежала в /etc, значит
#     попадала в бэкап sysupgrade и восстанавливалась оттуда) =>
#     отработал старый write_conf() без update_charset_options(), и в
#     /etc/smsd.conf не появились опции "alphabet = utf" - русский текст
#     в исходящих SMS снова ломался;
#   * /usr/share/rpcd/acl.d/luci-app-perenio.json - лежит вне /etc, в
#     бэкап не попадал, но остался в upper от старого led_hotfix.sh =>
#     merged-ACL без гранта exec на /rom/usr/libexec/perenio-diag.
#
# ЛЕЧЕНИЕ: init-сервис 41-pejir-sync при загрузке сверяет файлы наших
# пакетов с /rom (squashfs ТЕКУЩЕГО образа) и, если в merged лежит
# протухшая копия, возвращает свежую версию из образа.
#
# Тест проверяет ПОВЕДЕНИЕ: собирает песочницу с фейковым /rom, фейковым
# верхним слоем и фейковым merged-корнем, запускает сервис и смотрит,
# что именно изменилось, а что осталось нетронутым.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие дерева - ошибка.
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"
INIT="$TREE/package/pejir-sync/root/etc/init.d/41-pejir-sync"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$INIT" ] || { echo "FAIL: нет файла $INIT"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

ROM="$WORK/rom"
UPPER="$WORK/upper"
ROOT="$WORK/root"
PKG="$WORK/apk"

mkdir -p "$ROM/etc/init.d" "$ROM/usr/share/rpcd/acl.d" "$ROM/usr/libexec" \
         "$ROM/etc/config" "$ROM/usr/lib/lua/luci/i18n" \
         "$UPPER/etc/init.d" "$UPPER/usr/share/rpcd/acl.d" "$UPPER/usr/libexec" \
         "$UPPER/etc/config" "$UPPER/usr/lib/lua/luci/i18n" \
         "$ROOT/etc/init.d" "$ROOT/usr/share/rpcd/acl.d" "$ROOT/usr/libexec" \
         "$ROOT/etc/config" "$ROOT/usr/lib/lua/luci/i18n" \
         "$PKG"

# --- содержимое образа (свежее) -----------------------------------------
cat > "$ROM/etc/init.d/40-pejir-sms" <<'ROMEOF'
#!/bin/sh /etc/rc.common
# СВЕЖАЯ версия из образа: в ней есть update_charset_options()
CHARSET_OPTIONS="alphabet = utf"
update_charset_options() { :; }
ROMEOF

cat > "$ROM/usr/share/rpcd/acl.d/luci-app-perenio.json" <<'ROMEOF'
{ "file": { "/rom/usr/libexec/perenio-diag": { "exec": [ "read" ] } } }
ROMEOF

cat > "$ROM/usr/libexec/perenio-diag" <<'ROMEOF'
#!/bin/sh
# СВЕЖИЙ helper из образа
ROMEOF
chmod 755 "$ROM/usr/libexec/perenio-diag"

# Файл пакета в /etc/config - его НЕ трогаем: там пользовательские настройки.
cat > "$ROM/etc/config/cron" <<'ROMEOF'
config cron 'cron'
	option enabled '0'
ROMEOF

# --- протухшие копии в верхнем слое и в merged --------------------------
printf '#!/bin/sh /etc/rc.common\n# СТАРАЯ версия .45\n' > "$UPPER/etc/init.d/40-pejir-sms"
printf '#!/bin/sh /etc/rc.common\n# СТАРАЯ версия .45\n' > "$ROOT/etc/init.d/40-pejir-sms"

printf '{ "file": { } }\n' > "$UPPER/usr/share/rpcd/acl.d/luci-app-perenio.json"
printf '{ "file": { } }\n' > "$ROOT/usr/share/rpcd/acl.d/luci-app-perenio.json"

printf '#!/bin/sh\n# СТАРЫЙ helper\n' > "$UPPER/usr/libexec/perenio-diag"
printf '#!/bin/sh\n# СТАРЫЙ helper\n' > "$ROOT/usr/libexec/perenio-diag"

# Файл, которого в новом образе уже нет: из upper надо вычистить.
printf 'СТАРЫЙ lmo\n' > "$UPPER/usr/lib/lua/luci/i18n/luci-app-perenio.ru.lmo"
printf 'СТАРЫЙ lmo\n' > "$ROOT/usr/lib/lua/luci/i18n/luci-app-perenio.ru.lmo"

# Файл, совпадающий с образом, лежит только в merged (нижний слой) -
# копировать его в верхний слой нельзя.
printf '#!/bin/sh\n# СВЕЖИЙ helper\n' > "$ROM/usr/libexec/pejir-band"
printf '#!/bin/sh\n# СВЕЖИЙ helper\n' > "$ROOT/usr/libexec/pejir-band"
touch -t 202001010000 "$ROOT/usr/libexec/pejir-band"
BAND_MTIME_BEFORE="$(stat -c %Y "$ROOT/usr/libexec/pejir-band")"

# Протухшая копия в верхнем слое, но merged уже совпадает с образом -
# перезаписывать её нельзя (merged отдаёт верхний слой).
printf '#!/bin/sh\n# ПРОТУХШАЯ копия в upper, но merged свежий\n' > "$UPPER/usr/libexec/pejir-ussd"
printf '#!/bin/sh\n# СВЕЖИЙ helper\n' > "$ROM/usr/libexec/pejir-ussd"
printf '#!/bin/sh\n# СВЕЖИЙ helper\n' > "$ROOT/usr/libexec/pejir-ussd"
USSD_MTIME_BEFORE="$(stat -c %Y "$ROOT/usr/libexec/pejir-ussd")"

# Конфиг в /etc/config - пользовательский, не синхронизируем.
printf 'config cron "cron"\n\toption enabled "1"\n' > "$UPPER/etc/config/cron"
printf 'config cron "cron"\n\toption enabled "1"\n' > "$ROOT/etc/config/cron"

# --- списки файлов пакетов (как их видит apk на устройстве) --------------
cat > "$PKG/pejir-sms.list" <<'LISTEOF'
/etc/init.d/40-pejir-sms
LISTEOF

cat > "$PKG/luci-app-perenio.list" <<'LISTEOF'
/usr/share/rpcd/acl.d/luci-app-perenio.json
/usr/libexec/perenio-diag
/usr/libexec/pejir-band
/usr/libexec/pejir-ussd
/usr/lib/lua/luci/i18n/luci-app-perenio.ru.lmo
/etc/config/cron
LISTEOF

# --- запуск сервиса в песочнице ------------------------------------------
PEJIR_SYNC_ROM_DIR="$ROM" \
PEJIR_SYNC_UPPER_DIR="$UPPER" \
PEJIR_SYNC_ROOT_DIR="$ROOT" \
PEJIR_SYNC_PKG_DIR="$PKG" \
PEJIR_SYNC_PKGS="pejir-sms luci-app-perenio" \
	bash -c '. "$1"; start_service' _ "$INIT" > "$WORK/out.txt" 2>&1
RC=$?

if [ "$RC" -eq 0 ]; then
	ok "сервис отработал без ошибки"
else
	fail "сервис завершился с кодом $RC: $(tail -3 "$WORK/out.txt" | tr '\n' ' ')"
fi

# --- 1) протухший init-скрипт восстановлен -----------------------------
if cmp -s "$ROM/etc/init.d/40-pejir-sms" "$ROOT/etc/init.d/40-pejir-sms"; then
	ok "init-скрипт в merged заменён свежей версией из /rom"
else
	fail "init-скрипт в merged остался протухшим"
fi

if cmp -s "$ROM/etc/init.d/40-pejir-sms" "$UPPER/etc/init.d/40-pejir-sms"; then
	ok "init-скрипт в верхнем слое заменён свежей версией"
else
	fail "init-скрипт в верхнем слое остался протухшим"
fi

if grep -q "update_charset_options" "$ROOT/etc/init.d/40-pejir-sms"; then
	ok "в восстановленном init-скрипте есть update_charset_options()"
else
	fail "в восстановленном init-скрипте нет update_charset_options()"
fi

# --- 2) ACL восстановлен --------------------------------------------------
if grep -q "/rom/usr/libexec/perenio-diag" "$ROOT/usr/share/rpcd/acl.d/luci-app-perenio.json"; then
	ok "ACL в merged получил грант exec на /rom/usr/libexec/perenio-diag"
else
	fail "ACL в merged остался старым (нет гранта на /rom/usr/libexec/perenio-diag)"
fi

if cmp -s "$ROM/usr/share/rpcd/acl.d/luci-app-perenio.json" "$UPPER/usr/share/rpcd/acl.d/luci-app-perenio.json"; then
	ok "ACL в верхнем слое заменён свежей версией"
else
	fail "ACL в верхнем слое остался старым"
fi

# --- 3) helper восстановлен и исполняем ---------------------------------
if cmp -s "$ROM/usr/libexec/perenio-diag" "$ROOT/usr/libexec/perenio-diag"; then
	ok "helper в merged заменён свежей версией из /rom"
else
	fail "helper в merged остался протухшим"
fi

if [ -x "$ROOT/usr/libexec/perenio-diag" ]; then
	ok "восстановленный helper исполняем"
else
	fail "восстановленный helper не исполняем (нет бита +x)"
fi

# --- 4) файл, которого нет в образе, вычищен из upper -------------------
if [ ! -e "$UPPER/usr/lib/lua/luci/i18n/luci-app-perenio.ru.lmo" ]; then
	ok "файл, удалённый из образа, вычищен из верхнего слоя"
else
	fail "файл, удалённый из образа, остался в верхнем слое и перекрывает образ"
fi

# --- 5) совпадающий с образом файл не тронут ------------------------------
BAND_MTIME_AFTER="$(stat -c %Y "$ROOT/usr/libexec/pejir-band")"
if [ "$BAND_MTIME_BEFORE" = "$BAND_MTIME_AFTER" ]; then
	ok "файл, совпадающий с образом, не перезаписан"
else
	fail "файл, совпадающий с образом, перезаписан без нужды (mtime изменился)"
fi

# --- 5b) совпадающий с образом файл НЕ копируется в верхний слой ---------
# Иначе такая копия пережила бы следующий sysupgrade и снова перекрыла бы
# файл нового образа - ровно тот дефект, который чиним.
if [ ! -e "$UPPER/usr/libexec/pejir-band" ]; then
	ok "совпадающий с образом файл не создан в верхнем слое"
else
	fail "совпадающий с образом файл скопирован в верхний слой - он переживёт следующий OTA и перекроет новый образ"
fi

if [ "$(stat -c %Y "$ROOT/usr/libexec/pejir-ussd")" = "$USSD_MTIME_BEFORE" ]; then
	ok "протухшая копия в upper не перезаписана, если merged уже свежий"
else
	fail "файл перезаписан, хотя merged совпадал с образом"
fi

# --- 6) пользовательский конфиг в /etc/config не тронут ------------------
if grep -q "enabled \"1\"" "$ROOT/etc/config/cron" 2>/dev/null || grep -q "enabled '1'" "$ROOT/etc/config/cron" 2>/dev/null; then
	ok "пользовательский конфиг в /etc/config не тронут"
else
	fail "пользовательский конфиг в /etc/config перезаписан - правки потеряны"
fi

# --- 7) идемпотентность: второй прогон ничего не меняет -------------------
PEJIR_SYNC_ROM_DIR="$ROM" \
PEJIR_SYNC_UPPER_DIR="$UPPER" \
PEJIR_SYNC_ROOT_DIR="$ROOT" \
PEJIR_SYNC_PKG_DIR="$PKG" \
PEJIR_SYNC_PKGS="pejir-sms luci-app-perenio" \
	bash -c '. "$1"; start_service' _ "$INIT" > "$WORK/out2.txt" 2>&1

if cmp -s "$ROM/etc/init.d/40-pejir-sms" "$ROOT/etc/init.d/40-pejir-sms" && \
   grep -q "/rom/usr/libexec/perenio-diag" "$ROOT/usr/share/rpcd/acl.d/luci-app-perenio.json"; then
	ok "повторный запуск идемпотентен"
else
	fail "повторный запуск испортил состояние"
fi

# --- 8) сам init-скрипт сервиса в дереве ---------------------------------
if grep -q "START=90" "$INIT"; then
	ok "сервис стартует раньше 40-pejir-sms (START=90 < 92)"
else
	fail "в сервисе нет START=90 - он отработает после 40-pejir-sms"
fi

if grep -q "pejir-sms" "$INIT" && grep -q "luci-app-perenio" "$INIT"; then
	ok "сервис знает про пакеты pejir-sms и luci-app-perenio"
else
	fail "сервис не перечисляет наши пакеты"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты синхронизации overlay пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
