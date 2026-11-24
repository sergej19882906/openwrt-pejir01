#!/bin/sh
# Тест постоянной очереди SMS (патч 0086).
#
# ФАКТ (проверен на живом устройстве, релиз .53):
#   В OpenWrt /var - симлинок на /tmp, а /tmp смонтирован как tmpfs
#   (оперативная память). Очередь smsd (/var/spool/sms/*) поэтому живёт
#   в RAM, и принятые SMS после перезагрузки пропадают.
#
# ЧТО ДОЛЖНО ДЕЛАТЬ НОВЫЙ init-скрипт:
#   * положить очередь на постоянное хранилище (флешка extroot) и
#     СДЕЛАТЬ BIND-MOUNT этого каталога поверх /var/spool/sms;
#   * НЕ менять пути в smsd.conf: веб-интерфейс (sms.js), ACL LuCI и
#     pejir-sms-clean жёстко используют /var/spool/sms/... А симлинк
#     не годится: rpcd проверяет права по ЦЕЛЕВОМУ пути, и ACL на
#     /var/spool/sms/incoming перестал бы работать;
#   * отказ bind-mount'а НЕ должен ломать загрузку (SMS продолжают
#     работать в tmpfs, просто без постоянства);
#   * сам скрипт обязан иметь shebang `#!/bin/sh /etc/rc.common` -
#     только тогда include/rootfs.mk включит его при сборке образа
#     (rc.common enable -> симлинк S<START> в /etc/rc.d);
#   * и рабочий способ запуска: свой start()/stop(), зовущие
#     start_service()/stop_service() (иначе скрипт молча не
#     выполнится - тот же класс дефекта, что закрыл патч 0085).

set -u

BASE="$(cd "$(dirname "$0")/.." && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST)"; exit 1; }

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

SCRIPT="$OW/package/pejir-sms/root/etc/init.d/pejir-sms-spool"

# --- 1) скрипт существует -------------------------------------------------
if [ -f "$SCRIPT" ]; then
	ok "init-скрипт постоянной очереди есть: pejir-sms-spool"
else
	fail "нет $SCRIPT - очередь SMS остаётся в tmpfs"
	echo "FAIL: провалено проверок: $((FAILED + 1))"
	exit 1
fi

# --- 2) shebang: без него скрипт не включится в /etc/rc.d ----------------
if head -1 "$SCRIPT" | grep -q '^#!/bin/sh /etc/rc.common$'; then
	ok "shebang корректен - скрипт будет включён при сборке образа"
else
	fail "shebang не '!/bin/sh /etc/rc.common' - скрипт не включится автоматически"
fi

# --- 3) порядок запуска: раньше 40-pejir-sms (92) и smstools3 (94) -------
START="$(grep -m1 '^START=' "$SCRIPT" | cut -d= -f2)"
case "$START" in
	''|*[!0-9]*) fail "нет числового START=" ;;
	*)
		if [ "$START" -lt 92 ]; then
			ok "START=$START - раньше 40-pejir-sms (92), mount готов к старту smsd"
		else
			fail "START=$START - позже 40-pejir-sms (92), smsd стартует без постоянной очереди"
		fi
		;;
esac

# --- 4) рабочий способ запуска (как в патче 0085) ------------------------
if grep -qE '^[[:space:]]*start[[:space:]]*\(\)' "$SCRIPT" &&
   grep -A6 -E '^[[:space:]]*start[[:space:]]*\(\)' "$SCRIPT" | grep -q 'start_service'; then
	ok "есть start(), зовущий start_service() - скрипт не будет молчать"
else
	fail "нет start(), зовущего start_service() - скрипт молчал бы при загрузке"
fi

# --- 5) bind-mount, а не симлинк и не смена путей ------------------------
if grep -q 'mount .*--bind' "$SCRIPT"; then
	ok "используется bind-mount постоянного каталога"
else
	fail "нет bind-mount - очередь останется в tmpfs"
fi

# Симлинк не подходит: rpcd проверяет права по целевому пути.
if grep -qE 'ln[[:space:]]+-s[^|]*spool' "$SCRIPT"; then
	fail "используется симлинк - ACL LuCI на /var/spool/sms/* перестанет работать"
else
	ok "симлинк не используется - путь /var/spool/sms остаётся прежним"
fi

# Пути в smsd.conf менять нельзя: от них зависят веб-интерфейс, ACL и
# pejir-sms-clean. Ищем именно ЗАПИСЬ (перенаправление или sed -i), а не
# упоминание в комментарии.
if grep -nE '(>|sed[[:space:]]+-i|cp|mv)[[:space:]].*smsd\.conf' "$SCRIPT" | grep -qv '^[[:space:]]*#'; then
	fail "скрипт пишет в smsd.conf - пути очереди должны остаться /var/spool/sms"
else
	ok "smsd.conf не правится - пути очереди не меняются"
fi

# --- 6) отказ bind-mount не ломает загрузку -------------------------------
# Запускаем скрипт с подменой mount (фиктивный mount пишет аргументы в
# лог и возвращает код из $PEJIR_TEST_MOUNT_RC) и подменой путей через
# переменные окружения.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/etc/init.d" "$ROOT/lib/functions" "$ROOT/bin" "$WORK/pool" "$WORK/persist"

# Настоящий rc.common из дерева: именно он подключает init-скрипт и
# вызывает его start(). Запуск через `sh script` НЕ работает - rc.common
# не подключится, и результат будет ложным.
cp "$OW/package/base-files/files/etc/rc.common" "$ROOT/etc/rc.common"
cp "$OW/package/base-files/files/lib/functions.sh" "$ROOT/lib/functions.sh"
cp "$OW/package/base-files/files/lib/functions/service.sh" "$ROOT/lib/functions/service.sh"
cp "$SCRIPT" "$ROOT/etc/init.d/pejir-sms-spool"

cat > "$ROOT/bin/mount" <<'EOF'
#!/bin/sh
echo "$*" >> "$PEJIR_TEST_MOUNT_LOG"
exit "${PEJIR_TEST_MOUNT_RC:-0}"
EOF
chmod +x "$ROOT/bin/mount"

cat > "$ROOT/bin/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >> "$PEJIR_TEST_LOG"
EOF
chmod +x "$ROOT/bin/logger"

run_script() {
	PATH="$ROOT/bin:$PATH" \
	PEJIR_TEST_MOUNT_LOG="$WORK/mount.log" \
	PEJIR_TEST_LOG="$WORK/log.txt" \
	PEJIR_SPOOL_POOL="$WORK/pool" \
	PEJIR_SPOOL_PERSIST="$WORK/persist" \
	PEJIR_TEST_MOUNT_RC="$1" \
	IPKG_INSTROOT="$ROOT" \
	sh "$ROOT/etc/rc.common" "$ROOT/etc/init.d/pejir-sms-spool" start >"$WORK/out.txt" 2>&1
	echo $?
}

rc="$(run_script 0)"
if [ "$rc" = "0" ]; then
	ok "при успешном bind-mount скрипт завершается с кодом 0"
else
	fail "код возврата $rc при успешном bind-mount (ожидался 0)"
	fail "вывод: $(cat "$WORK/out.txt")"
fi

if [ -f "$WORK/mount.log" ] && grep -q -- "--bind" "$WORK/mount.log"; then
	ok "вызван mount --bind: $(cat "$WORK/mount.log")"
else
	fail "mount --bind не вызван"
fi

# Аргументы: сначала источник (постоянный каталог), потом точка монтирования.
if [ -f "$WORK/mount.log" ]; then
	args="$(cat "$WORK/mount.log")"
	case "$args" in
		*"$WORK/persist"*"$WORK/pool"*) ok "bind-mount: источник=постоянный каталог, цель=/var/spool/sms" ;;
		*) fail "неверные аргументы mount: $args" ;;
	esac
fi

rc="$(run_script 1)"
if [ "$rc" = "0" ]; then
	ok "при отказе bind-mount скрипт всё равно завершается с кодом 0 (загрузка не ломается)"
else
	fail "код возврата $rc при отказе bind-mount (ожидался 0 - SMS должны работать и в tmpfs)"
	fail "вывод: $(cat "$WORK/out.txt")"
fi

if [ -f "$WORK/log.txt" ] && grep -qiE "pejir-spool" "$WORK/log.txt"; then
	ok "при отказе записан лог с тегом pejir-spool"
else
	fail "при отказе нет записи в журнал"
fi

# --- 7) каталоги очереди создаются ---------------------------------------
for d in incoming outgoing sent failed checked; do
	if [ -d "$WORK/persist/$d" ]; then
		ok "создан каталог очереди $d"
	else
		fail "нет каталога очереди $d в постоянном хранилище"
	fi
done

echo
if [ "$FAILED" -eq 0 ]; then
	echo "PASS: постоянная очередь SMS настроена корректно"
	exit 0
fi
echo "FAIL: провалено проверок: $FAILED"
exit 1
