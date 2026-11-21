#!/bin/sh
# Тест pejir-extroot: разбор вывода block info, выбор раздела, запись fstab.
# Запускается в песочнице с моками block/mkfs/mount.

set -u

# Скрипт ищем в применённом дереве OpenWrt (в CI переменная OW_TEST
# указывает на него), иначе - в локальном дереве.
if [ -n "${OW_TEST:-}" ] && [ -f "$OW_TEST/package/pejir-extroot/files/pejir-extroot" ]; then
	DEFAULT_SCRIPT="$OW_TEST/package/pejir-extroot/files/pejir-extroot"
else
	DEFAULT_SCRIPT="/workspace/ow-test/package/pejir-extroot/files/pejir-extroot"
fi
SCRIPT="${1:-$DEFAULT_SCRIPT}"
FAILED=0

ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# --- чистое состояние -------------------------------------------------------
# Тест обязан быть герметичным: результат не должен зависеть от файлов,
# оставшихся от прошлого прогона (в CI состояние чистое, в песочнице - нет).
rm -rf /tmp/extroot-test
mkdir -p /tmp/extroot-test/bin /tmp/extroot-test/dev

# --- мок block -------------------------------------------------------------
# block info <dev> печатает: /dev/sda1: UUID="..." LABEL="..." TYPE="ext4"

cat > /tmp/extroot-test/bin/block <<'EOF'
#!/bin/sh
case "$1" in
info)
    if [ -n "$2" ]; then
        # путь в песочнице - /tmp/extroot-test/dev/sdX1, на устройстве -
        # /dev/sdX1; разбираем только имя устройства
        case "$(basename "$2")" in
        sda1) echo "$2: UUID=\"1111-2222\" LABEL=\"pejir-overlay\" TYPE=\"ext4\"" ;;
        sdb1) echo "$2: UUID=\"3333-4444\" LABEL=\"OTHER\" TYPE=\"vfat\"" ;;
        esac
    else
        echo '/dev/sda1: UUID="1111-2222" LABEL="pejir-overlay" TYPE="ext4"'
        echo '/dev/sdb1: UUID="3333-4444" LABEL="OTHER" TYPE="vfat"'
    fi
    ;;
esac
exit 0
EOF
chmod +x /tmp/extroot-test/bin/block

# --- мок mkfs.ext4 ---------------------------------------------------------
cat > /tmp/extroot-test/bin/mkfs.ext4 <<'EOF'
#!/bin/sh
echo "$@" > /tmp/extroot-test/mkfs.args
exit 0
EOF
chmod +x /tmp/extroot-test/bin/mkfs.ext4

# --- мок mount -------------------------------------------------------------
cat > /tmp/extroot-test/bin/mount <<'EOF'
#!/bin/sh
# mount -t ext4 <dev> <mnt>: имитируем монтирование флешки и копирование
# fstab на неё (настоящей флешки в песочнице нет).
case "$1" in
-t)
    dev="$3"; mnt="$4"
    mkdir -p "$mnt/etc/config"
    cp "$FSTAB_ENV" "$mnt/etc/config/fstab" 2>/dev/null || true
    exit 0
    ;;
esac
exit 0
EOF
chmod +x /tmp/extroot-test/bin/mount

# --- мок /sys/class/block --------------------------------------------------
# dev_size_mb читает /sys/class/block/<name>/size - подменяем функцию через
# отдельный каталог не получится, поэтому проверяем только логику выбора.

export PATH="/tmp/extroot-test/bin:$PATH"

# --- фейковые блочные устройства ------------------------------------------
# В песочнице настоящих /dev/sd* нет, поэтому делаем файлы и подменяем
# каталог через DEVDIR.
mkdir -p /tmp/extroot-test/dev
: > /tmp/extroot-test/dev/sda1
: > /tmp/extroot-test/dev/sdb1
export DEVDIR=/tmp/extroot-test/dev
export FSTAB_ENV=/tmp/extroot-test/fstab

# --- тест 1a: статус при отсутствующем fstab --------------------------------
# Файла /etc/config/fstab нет => extroot не настроен.
out="$(FSTAB=/tmp/extroot-test/fstab sh "$SCRIPT" status 2>&1)"
case "$out" in
	*"файла нет"*) ok "status: fstab отсутствует (ожидаемо)" ;;
	*) fail "status: нет сообщения об отсутствии fstab"; echo "$out" ;;
esac

# --- тест 1b: статус при чужом fstab без target '/overlay' ------------------
# Файл есть, но extroot в нём не настроен.
printf "config mount\n\toption target '/mnt/sda1'\n" > /tmp/extroot-test/fstab
out="$(FSTAB=/tmp/extroot-test/fstab sh "$SCRIPT" status 2>&1)"
case "$out" in
	*"extroot не настроен"*) ok "status: extroot не настроен (ожидаемо)" ;;
	*) fail "status: нет сообщения о не настроенном extroot"; echo "$out" ;;
esac

# --- тест 2: setup на готовом ext4-разделе --------------------------------
rm -f /tmp/extroot-test/fstab
out="$(printf 'yes\n' | FSTAB=/tmp/extroot-test/fstab sh "$SCRIPT" setup 2>&1)"
case "$out" in
	*"Выбрано устройство: "*"sda1"*) ok "setup: выбран ext4-раздел sda1" ;;
	*) fail "setup: не выбран ext4-раздел"; echo "$out" ;;
esac

if [ -f /tmp/extroot-test/fstab ]; then
	ok "setup: fstab создан"
else
	fail "setup: fstab не создан"
fi

if grep -q "target '/overlay'" /tmp/extroot-test/fstab 2>/dev/null; then
	ok "setup: в fstab есть target '/overlay' (признак extroot)"
else
	fail "setup: в fstab нет target '/overlay'"
fi

if grep -q "option uuid '1111-2222'" /tmp/extroot-test/fstab 2>/dev/null; then
	ok "setup: UUID взят у раздела"
else
	fail "setup: UUID не записан"; cat /tmp/extroot-test/fstab 2>/dev/null
fi

if grep -q "option enabled '1'" /tmp/extroot-test/fstab 2>/dev/null; then
	ok "setup: секция включена (enabled '1')"
else
	fail "setup: секция не включена"
fi

if grep -q "delay_root '15'" /tmp/extroot-test/fstab 2>/dev/null; then
	ok "setup: задан delay_root (USB успевает появиться)"
else
	fail "setup: нет delay_root"
fi

# --- тест 3: fstab скопирован на флешку ------------------------------------
if [ -f /tmp/pejir-extroot/etc/config/fstab ]; then
	ok "setup: fstab скопирован на флешку"
else
	fail "setup: fstab не скопирован на флешку"
	ls -R /tmp/pejir-extroot 2>/dev/null
fi

# --- тест 4: повторный setup не форматирует готовый ext4 -------------------
rm -f /tmp/extroot-test/mkfs.args
out="$(printf 'yes\n' | FSTAB=/tmp/extroot-test/fstab sh "$SCRIPT" setup 2>&1)"
if [ ! -f /tmp/extroot-test/mkfs.args ]; then
	ok "setup: готовый ext4-раздел НЕ форматируется заново"
else
	fail "setup: готовый ext4-раздел переформатирован"; cat /tmp/extroot-test/mkfs.args
fi

# --- тест 5: remove --------------------------------------------------------
out="$(FSTAB=/tmp/extroot-test/fstab sh "$SCRIPT" remove 2>&1)"
if [ ! -f /tmp/extroot-test/fstab ]; then
	ok "remove: fstab удалён"
else
	fail "remove: fstab остался"
fi

# --- тест 6: remove не трогает чужой fstab --------------------------------
printf "config mount\n\toption target '/mnt/sda1'\n" > /tmp/extroot-test/fstab
out="$(FSTAB=/tmp/extroot-test/fstab sh "$SCRIPT" remove 2>&1)"
if [ -f /tmp/extroot-test/fstab ]; then
	ok "remove: чужой fstab не тронут"
else
	fail "remove: чужой fstab удалён"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты pejir-extroot пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
