#!/bin/sh
# Тест очистки верхнего слоя overlay от файлов наших пакетов.
#
# Дефект, который закрывает тест: верхний слой overlay (rootfs_data)
# при sysupgrade НЕ пересоздаётся (патч 0037), поэтому всё, что хоть
# раз попало в /overlay/upper, переживает прошивку. Ранние горячие
# фиксы (apply_fixes.sh, led_hotfix.sh, battery_hotfix.sh) копировали
# туда файлы наших пакетов. Дальше эти протухшие копии перекрывают
# свежие файлы нового образа:
#
#   * /usr/share/rpcd/acl.d/luci-app-perenio.json - без гранта exec на
#     /rom/usr/libexec/perenio-diag => диагностика в LuCI не работает;
#   * /usr/libexec/pejir-ussd - без декодера UCS2 => USSD отдаёт мусор;
#   * /etc/init.d/pejir-led - вызывает "pejir-led off" => авто-режим
#     индикации стирается при каждой перезагрузке.
#
# Почему это повторялось: бэкап sysupgrade -c собирает ВСЕ файлы из
# /overlay/upper/etc (список packagesfiles строится только для режима
# -o, а для -c он пуст), поэтому протухшая копия /etc/init.d/40-pejir-sms
# попадала в sysupgrade.tgz и восстанавливалась поверх нового образа
# снова и снова.
#
# ЛЕЧЕНИЕ: перед прошивкой (pejir-ota) удаляем из верхнего слоя все
# файлы наших пакетов. После этого merged показывает свежие файлы
# образа, и протухшая копия больше не может перекрыть новую версию.
#
# Тест проверяет ПОВЕДЕНИЕ: собирает фейковый верхний слой, запускает
# очистку и смотрит, что именно удалено, а что осталось.

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
PURGE="$TREE/package/pejir-ota/files/pejir-ovl-purge"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$PURGE" ] || { echo "FAIL: нет файла $PURGE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

UPPER="$WORK/upper"
PKG="$WORK/apk"

mkdir -p "$UPPER/etc/init.d" \
         "$UPPER/usr/share/rpcd/acl.d" \
         "$UPPER/usr/libexec" \
         "$UPPER/etc/config" \
         "$UPPER/etc/uci-defaults" \
         "$UPPER/usr/bin" \
         "$PKG"

# --- протухшие копии наших пакетов в верхнем слое ------------------------
printf '#!/bin/sh /etc/rc.common\n# СТАРЫЙ 40-pejir-sms\n' > "$UPPER/etc/init.d/40-pejir-sms"
printf '{ "file": { } }\n' > "$UPPER/usr/share/rpcd/acl.d/luci-app-perenio.json"
printf '#!/bin/sh\n# СТАРЫЙ helper\n' > "$UPPER/usr/libexec/pejir-ussd"
printf '#!/bin/sh /etc/rc.common\n# СТАРЫЙ led\n' > "$UPPER/etc/init.d/pejir-led"
printf '#!/bin/sh\n# СТАРЫЙ ota\n' > "$UPPER/usr/bin/pejir-ota"

# --- то, что трогать НЕЛЬЗЯ ---------------------------------------------
# Пользовательский конфиг в /etc/config.
printf 'config system "system"\n\toption hostname "Perenio"\n' > "$UPPER/etc/config/system"
# uci-defaults: одноразовые скрипты установки.
printf '#!/bin/sh\nexit 0\n' > "$UPPER/etc/uci-defaults/80-pejir-sync"
# Файл чужого пакета (не нашего) - не трогаем.
printf 'hello\n' > "$UPPER/usr/bin/other-pkg-helper"
# Файл, которого нет в списках пакетов вообще.
printf 'stray\n' > "$UPPER/etc/init.d/50-stray"

# --- списки файлов пакетов (как их видит apk на устройстве) --------------
cat > "$PKG/pejir-sms.list" <<'LISTEOF'
/etc/init.d/40-pejir-sms
LISTEOF

cat > "$PKG/luci-app-perenio.list" <<'LISTEOF'
/usr/share/rpcd/acl.d/luci-app-perenio.json
/usr/libexec/pejir-ussd
/etc/init.d/pejir-led
LISTEOF

cat > "$PKG/pejir-ota.list" <<'LISTEOF'
/usr/bin/pejir-ota
LISTEOF

# --- запуск очистки в песочнице ------------------------------------------
PEJIR_PURGE_UPPER_DIR="$UPPER" \
PEJIR_PURGE_PKG_DIR="$PKG" \
PEJIR_PURGE_PKGS="pejir-sms luci-app-perenio pejir-ota" \
	sh "$PURGE" > "$WORK/out.txt" 2>&1
RC=$?

if [ "$RC" -eq 0 ]; then
	ok "очистка отработала без ошибки"
else
	fail "очистка завершилась с кодом $RC: $(tail -3 "$WORK/out.txt" | tr '\n' ' ')"
fi

# --- 1) протухшие копии наших пакетов удалены ----------------------------
for rel in \
	/etc/init.d/40-pejir-sms \
	/usr/share/rpcd/acl.d/luci-app-perenio.json \
	/usr/libexec/pejir-ussd \
	/etc/init.d/pejir-led \
	/usr/bin/pejir-ota
do
	if [ ! -e "$UPPER$rel" ]; then
		ok "протухшая копия $rel удалена из верхнего слоя"
	else
		fail "протухшая копия $rel осталась в верхнем слое и перекроет новый образ"
	fi
done

# --- 2) пользовательский конфиг не тронут -------------------------------
if [ -f "$UPPER/etc/config/system" ]; then
	ok "пользовательский конфиг в /etc/config не тронут"
else
	fail "пользовательский конфиг в /etc/config удалён - настройки потеряны"
fi

# --- 3) uci-defaults не тронуты ------------------------------------------
if [ -f "$UPPER/etc/uci-defaults/80-pejir-sync" ]; then
	ok "одноразовые скрипты в /etc/uci-defaults не тронуты"
else
	fail "одноразовые скрипты в /etc/uci-defaults удалены"
fi

# --- 4) чужие пакеты не тронуты ------------------------------------------
if [ -f "$UPPER/usr/bin/other-pkg-helper" ]; then
	ok "файл чужого пакета не тронут"
else
	fail "файл чужого пакета удалён"
fi

# --- 5) посторонний файл не тронут --------------------------------------
if [ -f "$UPPER/etc/init.d/50-stray" ]; then
	ok "файл, не принадлежащий нашим пакетам, не тронут"
else
	fail "файл, не принадлежащий нашим пакетам, удалён"
fi

# --- 6) идемпотентность: второй прогон ничего не меняет ------------------
PEJIR_PURGE_UPPER_DIR="$UPPER" \
PEJIR_PURGE_PKG_DIR="$PKG" \
PEJIR_PURGE_PKGS="pejir-sms luci-app-perenio pejir-ota" \
	sh "$PURGE" > "$WORK/out2.txt" 2>&1

if [ "$RC" -eq 0 ] && [ -f "$UPPER/etc/config/system" ] && [ ! -e "$UPPER/usr/libexec/pejir-ussd" ]; then
	ok "повторный прогон идемпотентен"
else
	fail "повторный прогон испортил состояние"
fi

# --- 7) очистка не ломается без верхнего слоя ---------------------------
PEJIR_PURGE_UPPER_DIR="$WORK/нет-такого" \
PEJIR_PURGE_PKG_DIR="$PKG" \
PEJIR_PURGE_PKGS="pejir-sms luci-app-perenio pejir-ota" \
	sh "$PURGE" > "$WORK/out3.txt" 2>&1
RC3=$?

if [ "$RC3" -eq 0 ]; then
	ok "очистка не падает, если верхнего слоя нет"
else
	fail "очистка упала с кодом $RC3, когда верхнего слоя нет"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты очистки overlay пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
