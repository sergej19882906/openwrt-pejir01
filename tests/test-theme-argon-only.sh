#!/bin/sh
# Тест: в образе остаётся только тема LuCI Argon.
#
# Дефект, который закрывает тест: в образе были три темы - Bootstrap
# (приходит с мета-пакетом luci/luci-light), Cyberpunk (наш вендоренный
# пакет) и Argon. Пользователь просил оставить только Argon.
#
# Проверяем и дерево OpenWrt (пакет cyberpunk удалён, uci-defaults
# правильные), и build.sh (мета-пакет luci заменён явным списком без
# bootstrap, в образе не должно быть лишних тем).

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

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SH="$REPO/build.sh"
ARGON_DEFAULTS="$DEFAULT_TREE/package/luci-theme-argon/root/etc/uci-defaults/35-pejir-theme-argon"
ARGON_ONLY="$DEFAULT_TREE/package/luci-theme-argon/root/etc/uci-defaults/36-pejir-theme-argon-only"
CYBERPUNK="$DEFAULT_TREE/package/luci-theme-cyberpunk"

[ -f "$BUILD_SH" ] || { echo "FAIL: нет $BUILD_SH"; exit 1; }
[ -f "$ARGON_DEFAULTS" ] || { echo "FAIL: нет $ARGON_DEFAULTS"; exit 1; }
[ -f "$ARGON_ONLY" ] || { echo "FAIL: нет $ARGON_ONLY"; exit 1; }

# --- 1. В дереве нет пакета Cyberpunk -------------------------------------
[ -d "$CYBERPUNK" ] && fail "пакет luci-theme-cyberpunk всё ещё в дереве" \
	|| ok "пакет luci-theme-cyberpunk удалён из дерева"

# --- 2. uci-defaults темы Argon ------------------------------------------
grep -q "luci.themes.Cyberpunk" "$ARGON_DEFAULTS" && fail "35-pejir-theme-argon всё ещё регистрирует Cyberpunk" \
	|| ok "35-pejir-theme-argon не регистрирует Cyberpunk"
grep -q "luci.main.mediaurlbase=/luci-static/argon" "$ARGON_DEFAULTS" && ok "35-pejir-theme-argon ставит тему Argon" \
	|| fail "35-pejir-theme-argon не ставит тему Argon"
grep -q "PKG_UPGRADE" "$ARGON_DEFAULTS" && fail "35-pejir-theme-argon выходит при обновлении - тема не переключится" \
	|| ok "35-pejir-theme-argon работает и при обновлении прошивки"

# --- 3. Уборка старых тем в настройках ------------------------------------
grep -q "Bootstrap" "$ARGON_ONLY" && ok "36-pejir-theme-argon-only вычищает Bootstrap" \
	|| fail "36-pejir-theme-argon-only не вычищает Bootstrap"
grep -q "Cyberpunk" "$ARGON_ONLY" && ok "36-pejir-theme-argon-only вычищает Cyberpunk" \
	|| fail "36-pejir-theme-argon-only не вычищает Cyberpunk"
grep -q "luci.themes.Argon" "$ARGON_ONLY" && ok "36-pejir-theme-argon-only регистрирует Argon" \
	|| fail "36-pejir-theme-argon-only не регистрирует Argon"

# --- 4. build.sh ----------------------------------------------------------
if grep -q "^CONFIG_PACKAGE_luci=y" "$BUILD_SH"; then
	fail "build.sh тянет мета-пакет luci - вместе с ним придёт тема Bootstrap"
else
	ok "build.sh не тянет мета-пакет luci"
fi
for p in luci-base luci-mod-admin-full luci-app-firewall luci-app-package-manager \
	luci-proto-ipv6 luci-proto-ppp rpcd-mod-rrdns uhttpd uhttpd-mod-ubus; do
	grep -q "^CONFIG_PACKAGE_$p=y" "$BUILD_SH" && ok "в build.sh есть $p" \
		|| fail "в build.sh нет $p - LuCI будет неполным"
done
grep -q "^CONFIG_PACKAGE_luci-theme-argon=y" "$BUILD_SH" && ok "в build.sh осталась тема Argon" \
	|| fail "в build.sh нет темы Argon"
grep -q "^CONFIG_PACKAGE_luci-theme-cyberpunk=y" "$BUILD_SH" && fail "в build.sh осталась тема Cyberpunk" \
	|| ok "в build.sh темы Cyberpunk нет"
grep -q "www/luci-static/bootstrap/css/cascade.css" "$BUILD_SH" && ok "build.sh проверяет отсутствие Bootstrap в образе" \
	|| fail "build.sh не проверяет отсутствие Bootstrap"
grep -q "www/luci-static/cyberpunk/css/cascade.css" "$BUILD_SH" && ok "build.sh проверяет отсутствие Cyberpunk в образе" \
	|| fail "build.sh не проверяет отсутствие Cyberpunk"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "ИТОГ: все проверки пройдены"
	exit 0
fi
echo "ИТОГ: провалено проверок: $FAILED"
exit 1
