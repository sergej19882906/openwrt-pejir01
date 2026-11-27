#!/bin/sh
# Тест: neofetch в баннере при входе по SSH.
#
# Что проверяем:
#   * в дереве есть пакет pejir-neofetch со скриптом neofetch и
#     подключением /etc/profile.d/neofetch.sh;
#   * neofetch вызывается только при входе по SSH (SSH_CONNECTION) и
#     только когда вывод идёт в терминал;
#   * в образе нужен bash (neofetch - скрипт на bash), и build.sh это
#     учитывает.

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
PKG="$DEFAULT_TREE/package/pejir-neofetch"
MK="$PKG/Makefile"
NEFETCH="$PKG/root/usr/bin/neofetch"
PROFILE="$PKG/root/etc/profile.d/neofetch.sh"

for f in "$BUILD_SH" "$MK" "$NEFETCH" "$PROFILE"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. Пакет --------------------------------------------------------------
grep -q "PKG_NAME:=pejir-neofetch" "$MK" && ok "пакет pejir-neofetch на месте" \
	|| fail "пакет pejir-neofetch не найден"
grep -q "usr/bin/neofetch" "$MK" && ok "neofetch устанавливается в /usr/bin" \
	|| fail "neofetch не устанавливается"
grep -q "profile.d" "$MK" && ok "подключение neofetch устанавливается в /etc/profile.d" \
	|| fail "подключение neofetch не устанавливается"
grep -q "+bash" "$MK" && ok "пакет зависит от bash (neofetch - скрипт на bash)" \
	|| fail "нет зависимости от bash"

head -n1 "$NEFETCH" | grep -q "bash" && ok "neofetch запускается через bash" \
	|| fail "neofetch не имеет шебанга с bash"

# --- 2. Подключение в профиле ---------------------------------------------
grep -q "SSH_CONNECTION" "$PROFILE" && ok "neofetch показывается только при входе по SSH" \
	|| fail "neofetch показывается не только по SSH"
grep -q "/usr/bin/neofetch" "$PROFILE" && ok "профиль вызывает /usr/bin/neofetch" \
	|| fail "профиль не вызывает neofetch"
grep -q "timeout" "$PROFILE" && ok "вызов neofetch ограничен по времени" \
	|| fail "вызов neofetch не ограничен по времени"

# --- 3. build.sh -----------------------------------------------------------
grep -q "^CONFIG_PACKAGE_bash=y" "$BUILD_SH" && ok "в образе есть bash" \
	|| fail "в build.sh нет bash - neofetch не запустится"
grep -q "^CONFIG_PACKAGE_pejir-neofetch=y" "$BUILD_SH" && ok "в build.sh включён pejir-neofetch" \
	|| fail "в build.sh нет pejir-neofetch"
grep -q "usr/bin/neofetch" "$BUILD_SH" && ok "build.sh проверяет наличие neofetch в образе" \
	|| fail "build.sh не проверяет наличие neofetch"
grep -q "bin/bash" "$BUILD_SH" && ok "build.sh проверяет наличие bash в образе (/bin/bash)" \
	|| fail "build.sh не проверяет наличие bash"

# --- 4. Функциональная проверка профиля -----------------------------------
WORK="${PEJIR_NEOFETCH_TEST:-/tmp/pejir-neofetch-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/neofetch" <<'EOF'
#!/bin/sh
echo "NEOFETCH-OUTPUT"
EOF
chmod +x "$WORK/bin/neofetch"

# Подменяем путь к neofetch на мок и проверяем условия показа.
cat > "$WORK/run.sh" <<EOF
#!/bin/sh
export PATH="$WORK/bin:\$PATH"
sed 's#/usr/bin/neofetch#$WORK/bin/neofetch#g' "$PROFILE" > "$WORK/profile.sh"
. "$WORK/profile.sh"
EOF
chmod +x "$WORK/run.sh"

# Вывод идёт через псевдотерминал (script): профиль показывает neofetch
# только когда stdout - терминал.
out="$(SSH_CONNECTION="1.2.3.4 22 5.6.7.8 22" script -q -c "sh $WORK/run.sh" /dev/null 2>/dev/null)"
case "$out" in
	*NEOFETCH-OUTPUT*) ok "при входе по SSH neofetch выводится" ;;
	*) fail "при входе по SSH neofetch не вывелся (вывод: '$out')" ;;
esac

out="$(sh "$WORK/run.sh" 2>/dev/null)"
case "$out" in
	*NEOFETCH-OUTPUT*) fail "без SSH neofetch всё равно выводится" ;;
	*) ok "без SSH neofetch не выводится" ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
	echo "ИТОГ: все проверки пройдены"
	exit 0
fi
echo "ИТОГ: провалено проверок: $FAILED"
exit 1
