#!/bin/sh
# Тест require-строк наших страниц LuCI.
#
# Модули в LuCI 25.12 объявляются строками вида 'require имя' (в кавычках).
# Загрузчик читает такие строки и грузит <resources>/<имя>.js как
# фабрику класса. Если указать несуществующий модуль, загрузчик попытается
# загрузить <resources>/<имя>.js и упадёт с:
#   TypeError: "<имя>" factory yields invalid constructor
#
# Именно так проявился дефект: в view/perenio/ota.js было 'require luci',
# а модуля "luci" не существует (базовый класс - глобальный L, модуль
# базы называется "baseclass"). Страница OTA не открывалась вообще.
#
# Тест проверяет:
#   1) в наших страницах нет 'require luci';
#   2) каждый require разрешается либо во встроенный класс LuCI, либо в
#      модуль пакета luci-base, либо в файл нашего дерева, либо (если
#      образ доступен) точно в файл собранного образа.

set -u

OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# Классы, встроенные в сам luci.js: classes={baseclass,dom,poll,request,session,view}
BUILTIN="baseclass dom poll request session view"
# Верхнеуровневые модули пакета luci-base, которые могут требовать наши
# страницы (путь в образе: /www/luci-static/resources/<имя>.js)
LUCIBASE="fs ui uci rpc form network firewall validation uqr cbi compat"

OUR_JS="$(find "$OW/package/pejir-ota/htdocs" "$OW/package/luci-app-perenio/htdocs" \
	-name '*.js' 2>/dev/null | sort)"

if [ -z "$OUR_JS" ]; then
	echo "FAIL: не нашёл наши JS-файлы в дереве $OW"
	exit 1
fi

# Собранный образ, если он есть: тогда проверяем require точно
ROOTFS=""
for c in \
	"$OW/bin/targets/ramips/mt7621/"*"-rootfs.squashfs" \
	"$OW/../bin/targets/ramips/mt7621/"*"-rootfs.squashfs"; do
	[ -f "$c" ] && { ROOTFS="$c"; break; }
done
RES=""
if [ -n "$ROOTFS" ] && command -v unsquashfs >/dev/null 2>&1; then
	rm -rf /tmp/require-test-res
	mkdir -p /tmp/require-test-res
	unsquashfs -no-progress -d /tmp/require-test-res "$ROOTFS" >/dev/null 2>&1
	RES="/tmp/require-test-res/www/luci-static/resources"
	ok "образ доступен - require проверяется по реальным файлам"
else
	echo "...   образ недоступен - проверяем по спискам модулей"
fi

# 1) require "luci" - ошибка (комментарии не считаем)
if grep -vE "^\s*//" $OUR_JS 2>/dev/null | grep -q "'require luci'"; then
	fail "в наших страницах есть 'require luci' - модуля luci не существует"
	grep -n "'require luci'" $OUR_JS 2>/dev/null | grep -vE ":\s*//" | sed 's/^/     /'
else
	ok "'require luci' нет ни в одной нашей странице"
fi

# 2) каждый require должен разрешаться
BAD=0
for f in $OUR_JS; do
	for dep in $(grep -vE "^\s*//" "$f" | grep -oE "'require [a-zA-Z0-9_.-]+" | sed "s/'require //"); do
		case " $BUILTIN " in
			*" $dep "*) continue ;;
		esac
		case " $LUCIBASE " in
			*" $dep "*) continue ;;
		esac
		# tools.* - семейство модулей luci-base
		case "$dep" in
			tools.*) continue ;;
		esac
		if [ -n "$RES" ]; then
			if [ -f "$RES/$dep.js" ] || [ -f "$RES/$dep/index.js" ]; then
				continue
			fi
			fail "$(basename "$f"): require '$dep' - нет файла $dep.js в образе"
			BAD=1
			continue
		fi
		if find "$OW" -path "$OW/.git" -prune -o -name "$(basename "$dep").js" -print 2>/dev/null | grep -q .; then
			continue
		fi
		fail "$(basename "$f"): require '$dep' не найден"
		BAD=1
	done
done
[ "$BAD" -eq 0 ] && ok "все require-строки наших страниц разрешаются"

rm -rf /tmp/require-test-res

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты require пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
