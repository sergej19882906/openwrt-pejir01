#!/bin/sh
# Тест: скачивание резервной копии на странице «Обновление прошивки (PEJIR01)».
#
# Дефект, который закрывает тест: после создания бэкапа страница показывала
# ссылку на файл в /www, но при клике LuCI 25.12 перехватывал ссылку и
# выдавал ошибку («Файлы отсутствуют») вместо скачивания. Теперь файл
# читается через rpcd и отдаётся браузеру как blob (так же, как это
# делает файловый менеджер LuCI), с запасным вариантом - прямая ссылка.
#
# Заодно проверяется, что страница после прошивки ждёт роутер по адресу
# 192.168.2.1 (адрес LAN в нашей прошивке), а не 192.168.1.1.

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

OTA_JS="$DEFAULT_TREE/package/pejir-ota/htdocs/luci-static/resources/view/perenio/ota.js"
OTA_ACL="$DEFAULT_TREE/package/pejir-ota/root/usr/share/rpcd/acl.d/luci-app-pejir-ota.json"

[ -f "$OTA_JS" ] || { echo "FAIL: нет файла $OTA_JS"; exit 1; }
[ -f "$OTA_ACL" ] || { echo "FAIL: нет файла $OTA_ACL"; exit 1; }

# --- 1. Скачивание через rpcd (blob), а не только ссылка ------------------
grep -q "read_direct(path, 'blob')" "$OTA_JS" \
	&& ok "файл бэкапа читается через rpcd (fs.read_direct)" \
	|| fail "бэкап не читается через rpcd - ссылка на /www не сработает"
grep -q "createObjectURL" "$OTA_JS" \
	&& ok "файл отдаётся браузеру как blob" \
	|| fail "нет blob-механизма скачивания"
grep -q "window.open(path, '_blank')" "$OTA_JS" \
	&& ok "есть запасной вариант - открыть ссылку напрямую" \
	|| fail "нет запасного варианта скачивания"

# --- 2. После прошивки ждём правильный адрес роутера ---------------------
grep -q "awaitReconnect(window.location.host, '192.168.2.1')" "$OTA_JS" \
	&& ok "после прошивки страница ждёт роутер по адресу 192.168.2.1" \
	|| fail "после прошивки страница ждёт неверный адрес роутера"
grep -q "192.168.1.1" "$OTA_JS" \
	&& fail "в странице остался адрес 192.168.1.1 - это адрес стокового OpenWrt" \
	|| ok "адрес 192.168.1.1 больше не используется"

# --- 3. ACL разрешает читать файл бэкапа ----------------------------------
python3 - "$OTA_ACL" <<'EOF'
import json, sys
acl = json.load(open(sys.argv[1]))
sec = acl["luci-app-pejir-ota"]
read = sec.get("read", {})
files = read.get("file", {})
if "/www/pejir-backup-*.tar.gz" in files and "read" in files["/www/pejir-backup-*.tar.gz"]:
    sys.exit(0)
sys.exit(1)
EOF
[ $? -eq 0 ] && ok "ACL разрешает читать файл бэкапа через rpcd" \
	|| fail "ACL не разрешает читать /www/pejir-backup-*.tar.gz"

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
