#!/bin/sh
# Тест: верхний слой overlay ищется у КОРНЕВОГО mount'а.
#
# Дефект, который закрывает тест.
#
# find_upper_dir() брал первую строку /proc/mounts с fstype overlay.
# На устройстве с extroot mount'ов с fstype overlay несколько (extroot-том
# монтируется как overlay, и корневой overlay - тоже overlay). Первый
# подходящий мог указывать не на rootfs_data, и тогда служба pejir-sync
# чистила не тот слой: протухшие копии файлов пакетов оставались и
# перекрывали свежие файлы образа, а диагностика в LuCI и USSD не
# работали.
#
# Вторая, более тонкая ошибка того же места: в /proc/mounts опции
# mount'а - ОДНО поле с запятыми ("rw,lowerdir=...,upperdir=...").
# Разбор по отдельным полям (awk for i = 4..NF) никогда не находил
# upperdir=, и верхний слой не определялся вовсе.
#
# Тест проверяет ПОВЕДЕНИЕ разбора: даём скриптам поддельный
# /proc/mounts и смотрим, какой каталог они выбрали.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"
SYNC="$TREE/package/pejir-sync/root/etc/init.d/41-pejir-sync"
PURGE="$TREE/package/pejir-ota/files/pejir-ovl-purge"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$SYNC" ] || { echo "FAIL: нет файла $SYNC"; exit 1; }
[ -f "$PURGE" ] || { echo "FAIL: нет файла $PURGE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# Каталоги-кандидаты: корневой верхний слой и "чужой" extroot-слой.
ROOT_UPPER="$WORK/root-upper"
EXT_UPPER="$WORK/extroot-upper"
mkdir -p "$ROOT_UPPER" "$EXT_UPPER"

# Поддельный /proc/mounts: extroot-слой идёт ПЕРВЫМ, корневой - вторым.
# Такой порядок и ломал разбор: бралась первая подходящая строка.
cat > "$WORK/mounts" <<MEOF
overlayfs:/overlay $EXT_UPPER overlay rw,noatime,lowerdir=/rom/upper,upperdir=$EXT_UPPER,workdir=$EXT_UPPER/work 0 0
overlayfs:/overlay / overlay rw,noatime,lowerdir=/rom/upper,upperdir=$ROOT_UPPER,workdir=$ROOT_UPPER/work 0 0
MEOF

# --- 1) 41-pejir-sync выбирает корневой mount -----------------------------
OUT="$(PEJIR_SYNC_MOUNTS_FILE="$WORK/mounts" PEJIR_SYNC_UPPER_DIR="" \
	bash -c '. "$1"; find_upper_dir' _ "$SYNC" 2>/dev/null)"

if [ "$OUT" = "$ROOT_UPPER" ]; then
	ok "41-pejir-sync выбрал верхний слой корневого mount'а: $OUT"
else
	fail "41-pejir-sync выбрал '$OUT' вместо '$ROOT_UPPER' - будет чиститься не тот слой"
fi

# --- 2) pejir-ovl-purge выбирает корневой mount --------------------------
OUT2="$(PEJIR_PURGE_MOUNTS_FILE="$WORK/mounts" \
	sh "$PURGE" --print-upper 2>/dev/null)"

if [ "$OUT2" = "$ROOT_UPPER" ]; then
	ok "pejir-ovl-purge выбрал верхний слой корневого mount'а: $OUT2"
else
	fail "pejir-ovl-purge выбрал '$OUT2' вместо '$ROOT_UPPER' - будут удалены не те файлы"
fi

# --- 3) разбор не зависит от формата опций ------------------------------
# Опции в /proc/mounts - одно поле с запятыми. Если разбор идёт по
# отдельным полям, upperdir= не находится никогда.
cat > "$WORK/mounts2" <<MEOF
overlayfs:/overlay / overlay rw,noatime,lowerdir=/rom/upper,upperdir=$ROOT_UPPER,workdir=$ROOT_UPPER/work 0 0
MEOF

OUT3="$(PEJIR_SYNC_MOUNTS_FILE="$WORK/mounts2" PEJIR_SYNC_UPPER_DIR="" \
	bash -c '. "$1"; find_upper_dir' _ "$SYNC" 2>/dev/null)"

if [ "$OUT3" = "$ROOT_UPPER" ]; then
	ok "upperdir= найден в общем поле опций (запятые): $OUT3"
else
	fail "upperdir= не найден ('$OUT3') - опции в /proc/mounts идут одним полем с запятыми"
fi

# --- 4) без корневого overlay берётся запасной вариант -------------------
cat > "$WORK/mounts3" <<MEOF
overlayfs:/overlay $EXT_UPPER overlay rw,noatime,lowerdir=/rom/upper,upperdir=$EXT_UPPER,workdir=$EXT_UPPER/work 0 0
MEOF

OUT4="$(PEJIR_SYNC_MOUNTS_FILE="$WORK/mounts3" PEJIR_SYNC_UPPER_DIR="" \
	bash -c '. "$1"; find_upper_dir' _ "$SYNC" 2>/dev/null)"

if [ "$OUT4" = "$EXT_UPPER" ]; then
	ok "без корневого overlay взят запасной mount: $OUT4"
else
	fail "без корневого overlay получено '$OUT4' вместо '$EXT_UPPER'"
fi

# --- 5) pejir-ovl-purge в режиме --print-upper ----------------------------
OUT5="$(PEJIR_PURGE_MOUNTS_FILE="$WORK/mounts3" \
	sh "$PURGE" --print-upper 2>/dev/null)"

if [ "$OUT5" = "$EXT_UPPER" ]; then
	ok "pejir-ovl-purge без корневого overlay взял запасной mount: $OUT5"
else
	fail "pejir-ovl-purge без корневого overlay получил '$OUT5' вместо '$EXT_UPPER'"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты разбора верхнего слоя пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
