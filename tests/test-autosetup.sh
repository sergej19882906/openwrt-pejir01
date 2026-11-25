#!/bin/sh
# Тест pejir-autosetup: init-скрипт первого запуска и поддержка swap
# в pejir-extroot.
#
# Проверяем:
#   * в fstab появляется секция swap для раздела с TYPE="swap";
#   * swap-раздел НЕ выбирается как раздел под overlay;
#   * авторежим (AUTO=1) не форматирует ничего;
#   * init-скрипт автонастройки на месте и синтаксически корректен;
#   * скрипт установки HOMEd на месте.

set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
EXTROOT="$OW/package/pejir-extroot/files/pejir-extroot"
AUTOINIT="$OW/package/pejir-autosetup/files/pejir-autosetup.init"
ZIGBEE="$OW/package/pejir-autosetup/files/zigbee-setup.sh"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$EXTROOT" "$AUTOINIT" "$ZIGBEE"; do
	if [ ! -f "$f" ]; then
		echo "FAIL: нет файла $f"
		exit 1
	fi
	if ! sh -n "$f" 2>/dev/null; then
		fail "$(basename "$f"): не проходит проверку синтаксиса"
	fi
done
ok "все скрипты на месте и синтаксически корректны"

# --- мок block: sda1 = ext4, sda2 = swap --------------------------------
WORK=/tmp/autosetup-test
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/dev"

cat > "$WORK/bin/block" <<'EOF'
#!/bin/sh
case "$1" in
info)
    if [ -n "$2" ]; then
        case "$(basename "$2")" in
        sda1) echo "$2: UUID=\"1111-2222\" LABEL=\"pejir-overlay\" TYPE=\"ext4\"" ;;
        sda2) echo "$2: UUID=\"3333-4444\" LABEL=\"SWAP\" TYPE=\"swap\"" ;;
        esac
    else
        echo '/dev/sda1: UUID="1111-2222" LABEL="pejir-overlay" TYPE="ext4"'
        echo '/dev/sda2: UUID="3333-4444" LABEL="SWAP" TYPE="swap"'
    fi
    ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/block"

cat > "$WORK/bin/mkfs.ext4" <<'EOF'
#!/bin/sh
echo "$@" > /tmp/autosetup-test/mkfs.args
exit 0
EOF
chmod +x "$WORK/bin/mkfs.ext4"

cat > "$WORK/bin/mount" <<'EOF'
#!/bin/sh
case "$1" in
-t)
    mkdir -p "$4"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/mount"

: > "$WORK/dev/sda1"
: > "$WORK/dev/sda2"

export PATH="$WORK/bin:$PATH"
export DEVDIR="$WORK/dev"
export FSTAB="$WORK/fstab"
export OVERLAY_ENV="$WORK/overlay"
export FSTAB_ENV="$WORK/fstab"
mkdir -p "$OVERLAY_ENV/upper/etc/config" "$OVERLAY_ENV/work"
printf "option ssid 'MyWiFi'\n" > "$OVERLAY_ENV/upper/etc/config/wireless"

# --- setup: extroot + swap ------------------------------------------------
out="$(AUTO=1 sh "$EXTROOT" setup 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
	fail "setup в автоматическом режиме завершился с ошибкой"
	echo "$out" | sed 's/^/     /'
else
	ok "setup в автоматическом режиме отработал"
fi

if grep -q "config swap" "$FSTAB"; then
	ok "в fstab появилась секция swap"
else
	fail "в fstab нет секции swap"
	sed 's/^/     /' "$FSTAB" 2>/dev/null
fi

# Путь раздела берётся из DEVDIR (в песочнице это каталог мока).
if grep -q "option device '.*sda2'" "$FSTAB"; then
	ok "swap-раздел sda2 прописан в fstab"
else
	fail "swap-раздел sda2 не прописан"
	sed 's/^/     /' "$FSTAB" 2>/dev/null
fi

if grep -q "option target '/overlay'" "$FSTAB"; then
	ok "раздел под overlay - ext4 (sda1), а не swap"
else
	fail "нет секции mount с target '/overlay'"
fi

if grep -q "sda2" "$FSTAB" && grep -q "option uuid '1111-2222'" "$FSTAB"; then
	ok "UUID overlay-раздела взят у sda1"
else
	fail "UUID overlay-раздела неверный"
fi

if grep -q "option auto_swap '1'" "$FSTAB"; then
	ok "auto_swap включён (иначе fstools не активирует swap)"
else
	fail "auto_swap не включён"
fi

# --- авторежим не форматирует --------------------------------------------
if [ -f "$WORK/mkfs.args" ]; then
	fail "автоматический режим отформатировал раздел - данные были бы стёрты"
else
	ok "автоматический режим ничего не форматирует"
fi

# --- команда swap отдельно ------------------------------------------------
rm -f "$FSTAB"
out="$(sh "$EXTROOT" swap 2>&1)"
if grep -q "config swap" "$FSTAB" 2>/dev/null; then
	ok "команда swap дописывает секцию в fstab"
else
	fail "команда swap не сработала"
	echo "$out" | sed 's/^/     /'
fi

# --- универсальность: UUID из fstab должен соответствовать флешке ---------
# Прошивка универсальна: UUID разделов НЕ зашит в образ, а определяется
# на месте (block info) и записывается в fstab при первой настройке.
# Но если флешку заменили (или перенесли настройки с другого роутера), в
# fstab останется UUID несуществующего раздела. Тогда extroot молча не
# работает: система грузится на внутренней памяти, swap выключен.
# Поэтому автонастройка должна ПРОВЕРЯТЬ, что раздел с UUID из fstab
# действительно есть, и перенастраивать extroot, если флешка заменена.
printf "config global\n\toption auto_swap '1'\n\nconfig mount\n\toption uuid '1111-2222'\n\toption target '/overlay'\n\toption fstype 'ext4'\n\toption enabled '1'\n" > "$FSTAB"
if sh "$EXTROOT" check >/dev/null 2>&1; then
	ok "check: раздел с UUID из fstab найден (флешка на месте)"
else
	fail "check: раздел с UUID из fstab не найден, хотя флешка подключена"
fi

printf "config global\n\toption auto_swap '1'\n\nconfig mount\n\toption uuid '9999-0000'\n\toption target '/overlay'\n\toption fstype 'ext4'\n\toption enabled '1'\n" > "$FSTAB"
if sh "$EXTROOT" check >/dev/null 2>&1; then
	fail "check: раздел с чужим UUID не найден, но check сообщил об успехе"
else
	ok "check: чужой UUID (флешка заменена) обнаружен"
fi

rm -f "$FSTAB"
if sh "$EXTROOT" check >/dev/null 2>&1; then
	fail "check: fstab без секции extroot - а check сообщил об успехе"
else
	ok "check: без секции extroot в fstab - extroot не настроен"
fi

# Секция swap, записанная старой версией (только путь к разделу), должна
# быть переписана с UUID - иначе swap отвалится после перенумерации.
printf "config global\n\toption auto_swap '1'\n\nconfig mount\n\toption uuid '1111-2222'\n\toption target '/overlay'\n\toption fstype 'ext4'\n\toption enabled '1'\n\nconfig swap\n\toption device 'sda2'\n\toption enabled '1'\n" > "$FSTAB"
sh "$EXTROOT" swap >/dev/null 2>&1
if grep -A6 "config swap" "$FSTAB" 2>/dev/null | grep -q "option uuid"; then
	ok "swap: секция со старым путём переписана и получила UUID"
else
	fail "swap: секция со старым путём не получила UUID"
	sed 's/^/     /' "$FSTAB" 2>/dev/null
fi

# --- init-скрипт автонастройки -------------------------------------------
if grep -q "pejir-extroot setup" "$AUTOINIT"; then
	ok "init-скрипт вызывает pejir-extroot setup"
else
	fail "init-скрипт не вызывает pejir-extroot setup"
fi
if grep -q "pejir-extroot check" "$AUTOINIT"; then
	ok "init-скрипт проверяет, что раздел extroot из fstab реально есть"
else
	fail "init-скрипт не проверяет раздел extroot (флешка заменена - extroot молча не заработает)"
fi
if grep -q "homed-zigbee" "$AUTOINIT"; then
	ok "init-скрипт проверяет установку HOMEd"
else
	fail "init-скрипт не проверяет HOMEd"
fi
if grep -q "AUTO=1" "$AUTOINIT"; then
	ok "init-скрипт запускает setup в автоматическом режиме"
else
	fail "init-скрипт не использует AUTO=1"
fi
if grep -q "reboot" "$AUTOINIT"; then
	ok "init-скрипт умеет перезагрузить устройство после настройки extroot"
else
	fail "init-скрипт не перезагружает устройство"
fi

rm -rf "$WORK"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты автонастройки пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
