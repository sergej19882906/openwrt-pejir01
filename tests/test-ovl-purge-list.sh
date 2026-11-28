#!/bin/sh
# Тест: в списке пакетов для чистки верхнего слоя есть ВСЕ наши пакеты.
#
# Дефект, который закрывает тест: pejir-ovl-purge чистил верхний слой
# только от части наших пакетов. Протухшая копия (например старый
# pejir-lanhost без перечитывания hosts через reload dnsmasq) оставалась
# в верхнем слое и перекрывала свежий файл из образа.

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

PURGE="$DEFAULT_TREE/package/pejir-ota/files/pejir-ovl-purge"

[ -f "$PURGE" ] || { echo "FAIL: нет файла $PURGE"; exit 1; }

# Все пакеты, которые мы собираем в образ.
EXPECTED="pejir-sms luci-app-perenio luci-app-atinout pejir-lte-base pejir-ota \
pejir-sync luci-app-modeminfo luci-theme-argon pejir-neofetch pejir-lanhost \
pejir-awg pejir-mwan pejir-extroot pejir-autosetup pejir-idata pejir-telegram \
pejir-zigbee-ncp pejir-homed-feed modeminfo modeminfo-serial-gosun \
luci-proto-amneziawg amneziawg-tools atinout"

# Достаём список по умолчанию из скрипта.
DEFAULT="$(sed -n 's/^PKGS="\${PEJIR_PURGE_PKGS:-\(.*\)}"$/\1/p' "$PURGE")"

[ -n "$DEFAULT" ] || { echo "FAIL: не удалось прочитать список пакетов из $PURGE"; exit 1; }

MISSING=""
for p in $EXPECTED; do
	case " $DEFAULT " in
	*" $p "*) : ;;
	*) MISSING="$MISSING $p" ;;
	esac
done

if [ -z "$MISSING" ]; then
	ok "в списке чистки все наши пакеты"
else
	fail "в списке чистки нет пакетов:$MISSING - их протухшие копии перекроют образ"
fi

# Пакеты, которых в образе нет, попадать в список не должны.
for p in lxc luci-app-lxc luci-theme-bootstrap luci-theme-cyberpunk; do
	case " $DEFAULT " in
	*" $p "*) fail "в списке чистки есть чужой пакет $p" ;;
	*) : ;;
	esac
done
ok "в списке чистки нет чужих пакетов"

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
