#!/bin/sh
# Проверка того, что build.sh (проверка собранного образа) корректно
# определяет, умеет ли init-скрипт стартовать при загрузке.
#
# ФОН:
#   /etc/rc.common вызывает start_service() ТОЛЬКО если скрипт объявил
#   USE_PROCD=1. Без этого флага вызывается собственная заглушка
#   start() { return 0; } и скрипт молча ничего не делает (патч 0085).
#
# ДЕФЕКТ (найден при проверке патча 0085):
#   Проверка в build.sh искала USE_PROCD=1 простым grep без якоря к
#   началу строки. А наши init-скрипты содержат ОБЪЯСНЕНИЕ в комментарии:
#       "# Объявляем USE_PROCD=1 нельзя: эти скрипты не регистрируют
#        инстанс через procd_open_instance"
#   Такой grep совпадает с КОММЕНТАРИЕМ и объявляет исправный скрипт
#   годным, даже если рабочего start() в нём нет. Проверка становится
#   пустой - дефект не ловится.
#
# ЧТО ПРОВЕРЯЕМ:
#   Корректный детектор обязан:
#     * принять скрипт с РЕАЛЬНЫМ USE_PROCD=1;
#     * принять скрипт со start(), зовущим start_service;
#     * ОТВЕРГНУТЬ скрипт, где USE_PROCD=1 есть только в комментарии
#       и нет рабочего start() (дефектный);
#     * отвергнуть скрипт, где start() есть, но не зовёт start_service.
#
# Детектор вынесен в scripts/init-start-check.sh, чтобы build.sh и
# этот тест проверяли ОДНУ и ту же логику (иначе тест ничего не
# гарантирует).

# ВНИМАНИЕ: OW_TEST в CI указывает на дерево OpenWrt (с патчами) -
# его НЕЛЬЗЯ удалять. Рабочий каталог теста - отдельная переменная.
OW_TEST="${OW_TEST:-}"
WORK="${PEJIR_TEST_WORK:-/tmp/ow-test-init-check}"
FAIL=0
ok()   { echo "  OK   $1"; }
fail() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

GUARD="$(dirname "$0")/../scripts/init-start-check.sh"
if [ ! -f "$GUARD" ]; then
	echo "FAIL: нет детектора $GUARD"
	exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"

# --- эталонные скрипты ---------------------------------------------------

# 1) Хороший: реальный USE_PROCD=1
cat > "$WORK/good-procd" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
start_service() {
	procd_open_instance
}
EOF

# 2) Хороший: свой start(), зовущий start_service
cat > "$WORK/good-start" <<'EOF'
#!/bin/sh /etc/rc.common
start_service() {
	echo "делаем работу"
}
start() {
	start_service "$@"
}
EOF

# 3) ПЛОХОЙ: USE_PROCD=1 только в комментарии, рабочего start() нет.
#    Именно этот случай ловил старый grep в build.sh.
cat > "$WORK/bad-comment" <<'EOF'
#!/bin/sh /etc/rc.common
# Объявляем USE_PROCD=1 нельзя: эти скрипты не регистрируют инстанс
# через procd_open_instance.
start_service() {
	echo "делаем работу"
}
EOF

# 4) ПЛОХОЙ: start() есть, но start_service не зовёт
cat > "$WORK/bad-start" <<'EOF'
#!/bin/sh /etc/rc.common
start_service() {
	echo "делаем работу"
}
start() {
	echo "ничего полезного"
}
EOF

# 5) Плохой: скрипт вообще не про start_service (должен быть принят
#    детектором - проверка не нужна)
cat > "$WORK/no-service" <<'EOF'
#!/bin/sh /etc/rc.common
echo "одноразовый скрипт"
EOF

# --- проверки -------------------------------------------------------------

check_ok() {
	if sh "$GUARD" "$1" >/dev/null 2>&1; then
		ok "$2"
	else
		fail "$2"
	fi
}

check_bad() {
	if sh "$GUARD" "$1" >/dev/null 2>&1; then
		fail "$2 - детектор принял негодный скрипт"
	else
		ok "$2"
	fi
}

check_ok "$WORK/good-procd"   "скрипт с реальным USE_PROCD=1 принят"
check_ok "$WORK/good-start"   "скрипт со start(), зовущим start_service, принят"
check_bad "$WORK/bad-comment" "USE_PROCD=1 только в комментарии отвергнут"
check_bad "$WORK/bad-start"   "start() без start_service отвергнут"
check_ok "$WORK/no-service"  "скрипт без start_service принят (проверка не нужна)"

# --- проверка на реальных файлах дерева -----------------------------------
#
# В CI тесты гоняются на дереве С ПРИМЕНЁННЫМИ патчами ($OW_TEST),
# поэтому там у наших init-скриптов уже есть рабочий start().
# Если $OW_TEST не задан (локальный прогон), проверку пропускаем:
# на голом дереве OpenWrt наших пакетов ещё нет.

if [ -n "$OW_TEST" ] && [ -d "$OW_TEST/package" ]; then
	for f in 40-pejir-sms 41-pejir-modem 47-pejir-lte 41-pejir-sync; do
		p="$(find "$OW_TEST/package" -name "$f" -path "*/init.d/*" 2>/dev/null | head -1)"
		if [ -n "$p" ]; then
			check_ok "$p" "реальный скрипт $f принят детектором"
		fi
	done
else
	echo "  ...   OW_TEST не задан - проверка на реальных файлах дерева пропущена"
fi

echo
if [ "$FAIL" -eq 0 ]; then
	echo "PASS: детектор init-скриптов работает верно"
	exit 0
fi
echo "FAIL: провалено проверок: $FAIL"
exit 1
