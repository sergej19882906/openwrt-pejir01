#!/bin/sh
# Тест: модуль AmneziaWG грузится (в нужном порядке) и локальное имя
# openwrt.lan резолвится.
#
# Дефект, который закрывает тест: модуль amneziawg был в образе, но не
# грузился - insmod падал с "Unknown symbol" (chacha20poly1305_*,
# xchacha20poly1305_*, curve25519_*), потому что крипто-модули ядра не
# были подгружены и порядок загрузки не соблюдался. Netifd оставлял
# AWG-интерфейс в pending ("Please install either kernel module
# (kmod-amneziawg package) or user-space implementation in
# /usr/bin/amneziawg-go"), туннель не поднимался вообще.
#
# Второй дефект: openwrt.lan не резолвился (NXDOMAIN). У dnsmasq был
# domain=lan, но самого роутера не было в /etc/hosts, поэтому имя
# работало только при поднятом WAN.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева OpenWrt $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева OpenWrt $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

AWG_INIT="$DEFAULT_TREE/package/pejir-awg/root/etc/init.d/pejir-awg"
LAN_INIT="$DEFAULT_TREE/package/pejir-lanhost/root/etc/init.d/pejir-lanhost"
KMOD_MK="$DEFAULT_TREE/package/kmod-amneziawg/Makefile"

for f in "$AWG_INIT" "$LAN_INIT" "$KMOD_MK"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. порядок загрузки модулей ------------------------------------------
MODS="$(sed -n 's/^AWG_MODULES="\(.*\)"$/\1/p' "$AWG_INIT")"
[ -n "$MODS" ] || { fail "в $AWG_INIT нет списка AWG_MODULES"; MODS=""; }

if [ -n "$MODS" ]; then
	ok "список модулей есть: $MODS"

	pos() { echo "$MODS" | tr ' ' '\n' | grep -n "^$1\$" | head -1 | cut -d: -f1; }

	p_cha=""; p_poly=""; p_lc20=""; p_c25519=""; p_awg=""
	p_cha=$(pos chacha-mips)
	p_poly=$(pos poly1305-mips)
	p_lc20=$(pos libchacha20poly1305)
	p_c25519=$(pos libcurve25519)
	p_awg=$(pos amneziawg)

	[ -n "$p_awg" ] && ok "amneziawg в списке" || fail "amneziawg нет в списке модулей"
	[ -n "$p_c25519" ] && ok "libcurve25519 в списке" || fail "libcurve25519 нет в списке модулей"
	[ -n "$p_lc20" ] && ok "libchacha20poly1305 в списке" || fail "libchacha20poly1305 нет в списке модулей"

	if [ -n "$p_awg" ] && [ -n "$p_c25519" ] && [ "$p_awg" -lt "$p_c25519" ]; then
		fail "amneziawg грузится раньше libcurve25519"
	else
		ok "amneziawg грузится после libcurve25519"
	fi

	if [ -n "$p_awg" ] && [ -n "$p_lc20" ] && [ "$p_awg" -lt "$p_lc20" ]; then
		fail "amneziawg грузится раньше libchacha20poly1305"
	else
		ok "amneziawg грузится после libchacha20poly1305"
	fi

	if [ -n "$p_lc20" ] && [ -n "$p_cha" ] && [ "$p_lc20" -lt "$p_cha" ]; then
		fail "libchacha20poly1305 грузится раньше chacha-mips"
	else
		ok "libchacha20poly1305 грузится после chacha-mips"
	fi

	if [ -n "$p_lc20" ] && [ -n "$p_poly" ] && [ "$p_lc20" -lt "$p_poly" ]; then
		fail "libchacha20poly1305 грузится раньше poly1305-mips"
	else
		ok "libchacha20poly1305 грузится после poly1305-mips"
	fi
fi

# init-скрипт должен уметь поднять интерфейсы после загрузки модуля
grep -q 'insmod' "$AWG_INIT" && ok "init-скрипт грузит модули через insmod" \
	|| fail "init-скрипт не грузит модули"
grep -q 'amneziawg|wireguard' "$AWG_INIT" && ok "init-скрипт находит AWG-интерфейсы" \
	|| fail "init-скрипт не ищет интерфейсы amneziawg/wireguard"
grep -q 'ifup' "$AWG_INIT" && ok "init-скрипт перезапускает AWG-интерфейсы" \
	|| fail "init-скрипт не делает ifup"

# --- 2. зависимости kmod-amneziawg ---------------------------------------
for dep in kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519 \
	   kmod-crypto-lib-chacha20 kmod-crypto-lib-poly1305; do
	grep -q "$dep" "$KMOD_MK" && ok "kmod-amneziawg зависит от $dep" \
		|| fail "kmod-amneziawg не зависит от $dep"
done

# --- 3. локальное имя openwrt.lan ----------------------------------------
grep -q 'openwrt\.lan' "$LAN_INIT" && ok "скрипт добавляет openwrt.lan" \
	|| fail "скрипт не добавляет openwrt.lan"
grep -q 'network\.lan\.ipaddr' "$LAN_INIT" && ok "IP берётся из network.lan.ipaddr" \
	|| fail "IP не берётся из network.lan.ipaddr"
# Перечитываем hosts поддержимым способом: reload dnsmasq (голый
# SIGHUP на некоторых сборках приводит к падению процесса, а вместе с
# ним - к пропаже DHCP). Плюс проверка живости dnsmasq.
if grep -q "init.d/dnsmasq reload" "$LAN_INIT"; then
	ok "dnsmasq перечитывает /etc/hosts через reload"
else
	fail "нет перечитывания /etc/hosts для dnsmasq"
fi
grep -q "pidof dnsmasq" "$LAN_INIT" && ok "проверяется, что dnsmasq жив" \
	|| fail "нет проверки живости dnsmasq - при падении пропадёт и DHCP"

# --- 4. новые пакеты включены в образ ------------------------------------
BUILD_SH="$REPO_DIR/build.sh"
[ -f "$BUILD_SH" ] && {
	for p in pejir-awg pejir-lanhost; do
		grep -q "^CONFIG_PACKAGE_${p}=y" "$BUILD_SH" \
			&& ok "в образ включён $p" \
			|| fail "в образ не включён $p"
	done
}

if [ "$FAILED" -eq 0 ]; then
	echo "PASS: модули AWG и локальное имя openwrt.lan"
	exit 0
fi
echo "FAILED: провалов $FAILED"
exit 1
