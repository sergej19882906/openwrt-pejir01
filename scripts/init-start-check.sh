#!/bin/sh
# Детектор «умеет ли init-скрипт стартовать при загрузке».
#
# ФОН:
#   /etc/rc.common вызывает start_service() ТОЛЬКО если скрипт объявил
#   USE_PROCD=1. Без этого флага rc.common выполняет собственную
#   заглушку start() { return 0; } - скрипт молча ничего не делает
#   (дефект патча 0018, исправлен патчем 0085).
#
#   Поэтому рабочий способ запуска - один из двух:
#     * реальное присваивание USE_PROCD=1 (в начале строки, НЕ в
#       комментарии);
#     * собственный start(), который зовёт start_service.
#
# ВАЖНО про USE_PROCD=1:
#   Искать его надо ЯКОРНЫМ grep -E '^[[:space:]]*USE_PROCD=1'.
#   Простой grep без якоря совпадает с КОММЕНТАРИЕМ вида
#       "# Объявляем USE_PROCD=1 нельзя: ..." -
#   и объявляет исправный скрипт годным, скрывая дефект.
#
# ИСПОЛЬЗОВАНИЕ:
#   init-start-check.sh <путь-к-init-скрипту>
#   Код 0 - рабочий способ запуска есть (или проверка не нужна).
#   Код 1 - скрипт молчал бы при загрузке.
#   Сообщение с причиной печатается в stdout.

set -u

f="${1:-}"

if [ -z "$f" ]; then
	echo "ИСПОЛЬЗОВАНИЕ: init-start-check.sh <init-скрипт>" >&2
	exit 2
fi

if [ ! -f "$f" ]; then
	echo "нет файла: $f"
	exit 1
fi

# Скрипт, который не определяет start_service(), проверять нечего:
# он и так отработает по своему усмотрению.
if ! grep -qE '^[[:space:]]*start_service[[:space:]]*\(\)' "$f"; then
	echo "OK: $f не использует start_service() - проверка не нужна"
	exit 0
fi

# Реальное USE_PROCD=1 (не комментарий!).
if grep -qE '^[[:space:]]*USE_PROCD=1([[:space:]]|$)' "$f"; then
	echo "OK: $f объявляет USE_PROCD=1"
	exit 0
fi

# Собственный start(), который зовёт start_service.
if grep -qE '^[[:space:]]*start[[:space:]]*\(\)' "$f"; then
	if grep -A6 -E '^[[:space:]]*start[[:space:]]*\(\)' "$f" | grep -q 'start_service'; then
		echo "OK: $f определяет start(), зовущий start_service()"
		exit 0
	fi
	echo "ПЛОХОЙ: $f определяет start(), но он НЕ зовёт start_service()"
	exit 1
fi

echo "ПЛОХОЙ: $f определяет start_service(), но ни USE_PROCD=1, ни start() - скрипт молчит при загрузке"
exit 1
