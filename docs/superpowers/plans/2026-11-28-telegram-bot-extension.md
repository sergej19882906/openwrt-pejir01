# Расширение Telegram-бота PEJIR01 — план реализации

> **Для агентных исполнителей:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Расширить мост Telegram на роутере: управление Wi-Fi, LTE и светодиодами, диагностика `/signal`, `/uptime`, `/battery`, отправка файлов и чтение веб-страниц.

**Architecture:** Существующий helper `pejir-tg` (разбор команды, безопасность, цикл опроса) остаётся точкой входа и почти не растёт. Рядом появляются два маленьких helper'а: `pejir-sys` (системные команды: signal/uptime/battery/led/wifi/lte/web) и `pejir-tg-send` (Telegram: текст и документ через multipart). Опасные команды требуют защитный код, который передаётся последним словом команды.

**Tech Stack:** POSIX shell (ash), `uci`, `wget-ssl` (GNU wget), `flock`, `jsonfilter`-совместимый разбор через `sed`, LuCI/uhttpd/rpcd (без изменений).

## Global Constraints

- Патч `0175`, релиз `.77`. Сборку `.76` не трогаем.
- Новых пакетов в образе нет: файлы добавляются в существующий пакет `pejir-telegram` (он уже включён через `CONFIG_PACKAGE_pejir-telegram=y`).
- В образе нет `curl`; есть `/usr/bin/wget` → `/usr/libexec/wget-ssl` (GNU wget с TLS). Multipart отправляется через `wget --post-file` + `--header`.
- Отправка файлов: только из `/tmp` и `/www`, размер ≤ 20 МБ (20 971 520 Байт).
- Текст в Telegram обрезается до 4000 символов (лимит Telegram — 4096).
- Веб-страницы: разрешены внешние и локальные адреса; HTML-теги вырезаются.
- Защитный код: `pejir_telegram.main.protect`. Опасные команды (`/wifi`, `/lte`, `/file`, `/web`, `/sms`, `/reboot`) требуют код; код — последнее слово команды. Если код не задан, опасные команды не выполняются.
- Команды выполняются только из чата `pejir_telegram.main.chat`; команды старше 10 минут не выполняются.
- Команды без защитного кода: `/status`, `/signal`, `/uptime`, `/battery`, `/led …`, `/help`, `/chatid`.
- Тест обязан ПАДААТЬ на старом коде и проходить на новом; новый тест обязательно добавляется в `.github/workflows/build.yml`.
- Исходники нормализованы к LF (git am режет CR).

## Структура файлов

| Файл | Ответственность |
|---|---|
| `package/pejir-telegram/root/usr/libexec/pejir-tg` | Точка входа: цикл опроса, разбор команды, проверка чата/возраста/кода, вызовы `pejir-sys` и `pejir-tg-send` |
| `package/pejir-telegram/root/usr/libexec/pejir-tg-send` | Telegram: `text` и `file` (multipart). Знает только про Telegram |
| `package/pejir-telegram/root/usr/libexec/pejir-sys` | Система: `signal`, `uptime`, `battery`, `led`, `wifi`, `lte`, `web`. Знает только про систему |
| `package/pejir-telegram/Makefile` | Установка трёх helper'ов |
| `tests/test-telegram-sys.sh` | Тест системных команд (новый) |
| `tests/test-telegram-bridge.sh` | Тест маршрутизации, защитного кода и отправки файла (новый) |
| `tests/test-telegram.sh` | Существующий тест: правится под требование кода для `/sms` |
| `.github/workflows/build.yml` | Запуск двух новых тестов |
| `docs/superpowers/plans/2026-11-28-telegram-bot-extension.md` | Этот план |

---

### Task 1: `pejir-sys` — диагностика (signal, uptime, battery)

**Files:**
- Create: `package/pejir-telegram/root/usr/libexec/pejir-sys`
- Modify: `package/pejir-telegram/Makefile`
- Test: `tests/test-telegram-sys.sh`

**Interfaces:**
- Consumes: `/tmp/pejir-modem.json` (формат `{"modem":[{"rssi":"...","csq_per":"...","cops":"...","mode":"..."}]}`), `/tmp/pejir-battery` (строка `OK ChrgConn=1 ... BatLev=95% VBat=4164 ...`), `/proc/uptime`, `/proc/loadavg`, `/proc/meminfo`.
- Produces: CLI `pejir-sys signal|uptime|battery`; каждая команда печатает текст и возвращает 0 (успех) или 1 (нет данных).

- [ ] **Step 1: Написать падающий тест**

`tests/test-telegram-sys.sh` (создать):

```sh
#!/bin/sh
# Тест системных команд Telegram-моста (/usr/libexec/pejir-sys).
#
# Проверяется поведение на подставных файлах:
#   1) signal  - разбор кеша модема (RSSI, CSQ, оператор);
#   2) uptime  - время работы, load average, память;
#   3) battery - разбор ответа STM32 (уровень, напряжение, зарядка);
#   4) наличие файла и синтаксис shell.
#
# Тест обязан падать на старом коде (файла pejir-sys ещё нет).

set -u

if [ -n "${OW_TEST:-}" ]; then
	TREE="$OW_TEST"
else
	TREE="${PEJIR_OW_TEST:-/workspace/ow-test}"
	[ -d "$TREE" ] || { echo "FAIL: нет дерева $TREE (задайте OW_TEST)"; exit 1; }
fi

SYS="$TREE/package/pejir-telegram/root/usr/libexec/pejir-sys"
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$SYS" ] || { echo "FAIL: нет $SYS"; exit 1; }
[ -x "$SYS" ] && ok "helper: исполняемый" || fail "helper: не исполняемый"
sh -n "$SYS" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"

WORK="${PEJIR_TEST_WORK:-/tmp/pejir-test-tgsys}"
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/pejir-modem.json" <<'JSONEOF'
{"modem":[{"device":"/dev/ttyUSB2","cops":"25001,MCC MNC","mode":"LTE","csq_per":"99","rssi":"-77"}]}
JSONEOF

cat > "$WORK/pejir-battery" <<'BATEOF'
OK ChrgConn=1 ChrgType=3 ChrgStat=0 BatLev=95% VBat=4164 VBus=12200 VSys=4224 TBat=51
BATEOF

export PEJIR_SYS_MODEM_JSON="$WORK/pejir-modem.json"
export PEJIR_SYS_BATTERY="$WORK/pejir-battery"

out="$("$SYS" signal 2>/dev/null)"
printf '%s' "$out" | grep -q '\-77' && ok "signal: RSSI из кеша модема" \
	|| fail "signal: RSSI не показан ($out)"
printf '%s' "$out" | grep -qi 'LTE' && ok "signal: тип сети из кеша модема" \
	|| fail "signal: тип сети не показан ($out)"

out="$("$SYS" uptime 2>/dev/null)"
printf '%s' "$out" | grep -qi 'время работы\|uptime' && ok "uptime: время работы" \
	|| fail "uptime: время работы не показано ($out)"

out="$("$SYS" battery 2>/dev/null)"
printf '%s' "$out" | grep -q '95' && ok "battery: уровень заряда" \
	|| fail "battery: уровень не показан ($out)"
printf '%s' "$out" | grep -q '4164' && ok "battery: напряжение" \
	|| fail "battery: напряжение не показано ($out)"

echo "---"
if [ "$FAILED" -eq 0 ]; then
	echo "PASS: системные команды Telegram-моста"
	exit 0
fi
echo "FAIL: провалено проверок: $FAILED"
exit 1
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-sys.sh`
Expected: `FAIL: нет .../pejir-sys` (exit 1)

- [ ] **Step 3: Реализовать `pejir-sys` (первая часть)**

Создать `package/pejir-telegram/root/usr/libexec/pejir-sys`:

```sh
#!/bin/sh
# Системные команды для Telegram-моста PEJIR01.
#
# Helper ничего не знает про Telegram: он только исполняет команду и
# печатает результат. Разбор и безопасность - в pejir-tg.
#
# Подкоманды:
#   signal               уровень сигнала, оператор, тип сети;
#   uptime               время работы, load average, память;
#   battery              заряд батареи (STM32);
#   led <аргументы...>   индикаторы (см. /usr/libexec/pejir-led);
#   wifi status|radio <имя> on|off|ssid <имя> on|off|reload
#   lte status|apn <apn>|restart
#   web <url>            текст веб-страницы без HTML-тегов.
#
# Пути переопределяются переменными окружения - только для тестов.

set -u

MODEM_JSON="${PEJIR_SYS_MODEM_JSON:-/tmp/pejir-modem.json}"
BATTERY_FILE="${PEJIR_SYS_BATTERY:-/tmp/pejir-battery}"
LED_BIN="${PEJIR_SYS_LED:-/usr/libexec/pejir-led}"
WIRELESS_CONF="${PEJIR_SYS_WIRELESS:-/etc/config/wireless}"
LTE_INIT="${PEJIR_SYS_LTE_INIT:-/etc/init.d/47-pejir-lte}"
UCI_BIN="${PEJIR_SYS_UCI:-uci}"
WIFI_BIN="${PEJIR_SYS_WIFI:-wifi}"
WGET="${PEJIR_SYS_WGET:-wget}"
WEB_MAX="${PEJIR_SYS_WEB_MAX:-4000}"
WEB_TIMEOUT="${PEJIR_SYS_WEB_TIMEOUT:-20}"

# Значение одного строкового поля JSON-кеша модема.
# Ключи в кеше уникальны, поэтому достаточно одного совпадения.
json_str() {
	[ -f "$1" ] || return 1
	sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

# Значение поля из ответа STM32 вида "OK ChrgConn=1 ... BatLev=95% ...".
stm_fld() {
	printf '%s' "$1" | sed -n "s/.*[ $2]=\([^ ]*\).*/\1/p"
}

cmd_signal() {
	[ -f "$MODEM_JSON" ] || { echo "нет данных модема ($MODEM_JSON)"; return 1; }

	_rssi="$(json_str "$MODEM_JSON" rssi)"
	_csq="$(json_str "$MODEM_JSON" csq_per)"
	_cops="$(json_str "$MODEM_JSON" cops)"
	_mode="$(json_str "$MODEM_JSON" mode)"

	[ -n "$_rssi" ] || { echo "в кеше модема нет данных"; return 1; }

	echo "сигнал: ${_rssi:-n/a} dBm"
	[ -n "$_csq" ] && echo "CSQ: ${_csq}/99"
	[ -n "$_cops" ] && echo "оператор: ${_cops}"
	[ -n "$_mode" ] && echo "сеть: ${_mode}"
	return 0
}

cmd_uptime() {
	_up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
	case "$_up" in
	''|*[!0-9.]*) echo "нет данных о времени работы"; return 1 ;;
	esac

	_sec="${_up%%.*}"
	_d=$((_sec / 86400))
	_h=$(((_sec % 86400) / 3600))
	_m=$(((_sec % 3600) / 60))

	echo "время работы: ${_d} д ${_h} ч ${_m} мин"

	if [ -r /proc/loadavg ]; then
		echo "загрузка: $(cut -d' ' -f1-3 /proc/loadavg)"
	fi

	if [ -r /proc/meminfo ]; then
		_total="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)"
		_avail="$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)"
		[ -n "$_total" ] && echo "память: свободно $((_avail / 1024)) из $((_total / 1024)) МБ"
	fi

	return 0
}

cmd_battery() {
	[ -f "$BATTERY_FILE" ] || { echo "нет данных батареи ($BATTERY_FILE)"; return 1; }

	_raw="$(cat "$BATTERY_FILE" 2>/dev/null)"
	case "$_raw" in
	*OK*) ;;
	*) echo "STM32 не ответил"; return 1 ;;
	esac

	_level="$(stm_fld "$_raw" BatLev)"
	_vbat="$(stm_fld "$_raw" VBat)"
	_vbus="$(stm_fld "$_raw" VBus)"
	_vsys="$(stm_fld "$_raw" VSys)"
	_stat="$(stm_fld "$_raw" ChrgStat)"

	echo "уровень: ${_level:-n/a}"
	[ -n "$_vbat" ] && echo "напряжение батареи: ${_vbat} мВ"
	[ -n "$_vbus" ] && echo "напряжение шины: ${_vbus} мВ"
	[ -n "$_vsys" ] && echo "напряжение системы: ${_vsys} мВ"

	case "$_stat" in
	1|2) echo "зарядка: идёт" ;;
	3) echo "зарядка: завершена" ;;
	*) echo "зарядка: не идёт" ;;
	esac

	return 0
}

case "${1:-}" in
signal) cmd_signal ;;
uptime) cmd_uptime ;;
battery) cmd_battery ;;
*)
	echo "usage: pejir-sys {signal|uptime|battery}" >&2
	exit 2
	;;
esac
```

`chmod 0755` для файла.

- [ ] **Step 4: Добавить установку в Makefile**

В `package/pejir-telegram/Makefile` рядом с установкой `pejir-tg` добавить:

```make
	$(INSTALL_BIN) ./root/usr/libexec/pejir-sys $(1)/usr/libexec/pejir-sys
```

- [ ] **Step 5: Прогнать тест**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-sys.sh`
Expected: `PASS: системные команды Telegram-моста`

- [ ] **Step 6: Коммит**

```bash
git add package/pejir-telegram && git commit -m "Telegram-мост: системные команды (сигнал, uptime, батарея)"
```

---

### Task 2: `pejir-sys` — индикаторы, Wi-Fi, LTE, веб

**Files:**
- Modify: `package/pejir-telegram/root/usr/libexec/pejir-sys`
- Test: `tests/test-telegram-sys.sh`

**Interfaces:**
- Consumes: `/usr/libexec/pejir-led` (`status`, `set`, `auto`, `off`, `brightness`), `/etc/config/wireless` (через `uci`), `/etc/init.d/47-pejir-lte` (рестарт), `wget` (веб).
- Produces: `pejir-sys led …`, `pejir-sys wifi …`, `pejir-sys lte …`, `pejir-sys web <url>`.

- [ ] **Step 1: Дописать в тест проверки led/wifi/lte/web**

Добавить в `tests/test-telegram-sys.sh` (перед блоком `echo "---"`):

```sh
# --- led: вызов идёт в pejir-led ------------------------------------------
cat > "$WORK/led" <<'LEDEOF'
#!/bin/sh
printf 'led %s\n' "$*" >> "${TG_SYS_LED_LOG:-/dev/null}"
exit 0
LEDEOF
chmod 0755 "$WORK/led"
export PEJIR_SYS_LED="$WORK/led"
export TG_SYS_LED_LOG="$WORK/led.log"

"$SYS" led status >/dev/null 2>&1
grep -q "led status" "$TG_SYS_LED_LOG" 2>/dev/null \
	&& ok "led: команда уходит в pejir-led" || fail "led: pejir-led не вызван"

# --- wifi: включение/выключение SSID --------------------------------------
cat > "$WORK/uci" <<'UCIEOF'
#!/bin/sh
printf 'uci %s\n' "$*" >> "${TG_SYS_UCI_LOG:-/dev/null}"
case "$1" in
	-q)
		case "$2" in
		show)
			printf 'wireless.radio0=wifi-device\nwireless.radio0.disabled=0\nwireless.@wifi[0]=wifi-iface\nwireless.@wifi[0].ssid=MyNet\nwireless.@wifi[0].disabled=0\n'
			;;
		*) ;;
		esac
		;;
	get)
		case "$3" in
		*disabled) printf '0\n' ;;
		*) printf '\n' ;;
		esac
		;;
	esac
exit 0
UCIEOF
chmod 0755 "$WORK/uci"
export PEJIR_SYS_UCI="$WORK/uci"
export PEJIR_SYS_WIFI_RELOAD="$WORK/wifi-reload"
cat > "$WORK/wifi-reload" <<'WEOF'
#!/bin/sh
printf 'reload\n' >> "${TG_SYS_WIFI_LOG:-/dev/null}"
exit 0
WEOF
chmod 0755 "$WORK/wifi-reload"
export TG_SYS_UCI_LOG="$WORK/uci.log"
export TG_SYS_WIFI_LOG="$WORK/wifi.log"

out="$("$SYS" wifi status 2>/dev/null)"
printf '%s' "$out" | grep -q 'MyNet' && ok "wifi status: виден SSID" \
	|| fail "wifi status: SSID не показан ($out)"

"$SYS" wifi ssid MyNet off >/dev/null 2>&1
grep -q "set wireless.@wifi\[0\].disabled=1" "$TG_SYS_UCI_LOG" 2>/dev/null \
	&& ok "wifi ssid off: интерфейс помечен отключённым" \
	|| fail "wifi ssid off: uci set не выполнен"

# --- lte: смена APN и перезапуск -----------------------------------------
cat > "$WORK/lte-init" <<'LEOF'
#!/bin/sh
printf 'lte %s\n' "$*" >> "${TG_SYS_LTE_LOG:-/dev/null}"
exit 0
LEOF
chmod 0755 "$WORK/lte-init"
export PEJIR_SYS_LTE_INIT="$WORK/lte-init"
export TG_SYS_LTE_LOG="$WORK/lte.log"

"$SYS" lte apn internet >/dev/null 2>&1
grep -q "set network.lte.apn=internet" "$TG_SYS_UCI_LOG" 2>/dev/null \
	&& ok "lte apn: APN записан" || fail "lte apn: APN не записан"
grep -q "lte restart" "$TG_SYS_LTE_LOG" 2>/dev/null \
	&& ok "lte apn: LTE перезапущен" || fail "lte apn: LTE не перезапущен"

# --- web: страница читается, теги вырезаются --------------------------------
cat > "$WORK/wget" <<'WGETEOF'
#!/bin/sh
printf '<html><head><title>T</title></head><body><p>Привет</p></body></html>\n'
exit 0
WGETEOF
chmod 0755 "$WORK/wget"
export PEJIR_SYS_WGET="$WORK/wget"

out="$("$SYS" web https://example.com 2>/dev/null)"
printf '%s' "$out" | grep -q 'Привет' && ok "web: текст страницы получен" \
	|| fail "web: текст не получен ($out)"
printf '%s' "$out" | grep -q '<p>' && fail "web: HTML-теги не вырезаны" \
	|| ok "web: HTML-теги вырезаны"
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-sys.sh`
Expected: `FAIL: led: pejir-led не вызван` и другие новые проверки

- [ ] **Step 3: Реализовать подкоманды в `pejir-sys`**

В `package/pejir-telegram/root/usr/libexec/pejir-sys` добавить переменные:

```sh
WIFI_RELOAD="${PEJIR_SYS_WIFI_RELOAD:-wifi reload}"
```

и функции (перед блоком `case`):

```sh
cmd_led() {
	[ -x "$LED_BIN" ] || { echo "нет помощника индикаторов ($LED_BIN)"; return 1; }
	shift 2>/dev/null || true
	[ -n "$1" ] || { echo "usage: pejir-sys led {status|off|set <имя> <цвет> [режим]|auto <имя> on|off|brightness <0-7>}"; return 2; }
	"$LED_BIN" "$@"
}

# Имя wifi-iface по SSID.
wifi_iface_by_ssid() {
	"$UCI_BIN" -q show wireless 2>/dev/null | awk -v want="$1" '
		/^wireless\.[^.]+=wifi-iface/ {
			section = $0; sub(/^wireless\./, "", section); sub(/=wifi-iface.*$/, "", section)
			next
		}
		/^wireless\.[^.]+\.ssid=/ {
			value = $0; sub(/^[^=]*=/, "", value); gsub(/"/, "", value)
			if (value == want) { print section; exit }
		}'
}

cmd_wifi_status() {
	[ -f "$WIRELESS_CONF" ] || { echo "Wi-Fi не настроен ($WIRELESS_CONF отсутствует)"; return 1; }

	_out="$("$UCI_BIN" -q show wireless 2>/dev/null)"
	[ -n "$_out" ] || { echo "Wi-Fi не настроен"; return 1; }

	printf '%s\n' "$_out" | awk '
		/^wireless\.[^.]+=wifi-device/ {
			section = $0; sub(/^wireless\./, "", section); sub(/=wifi-device.*$/, "", section)
			radio = section; next
		}
		/^wireless\.[^.]+\.disabled=/ && radio != "" {
			value = $0; sub(/^[^=]*=/, "", value); gsub(/"/, "", value)
			printf "радио %s: %s\n", radio, (value == "1" ? "выключен" : "включён")
			radio = ""; next
		}
		/^wireless\.[^.]+=wifi-iface/ {
			section = $0; sub(/^wireless\./, "", section); sub(/=wifi-iface.*$/, "", section)
			iface = section; next
		}
		/^wireless\.[^.]+\.ssid=/ {
			value = $0; sub(/^[^=]*=/, "", value); gsub(/"/, "", value)
			ssid = value; next
		}
		/^wireless\.[^.]+\.disabled=/ && iface != "" {
			value = $0; sub(/^[^=]*=/, "", value); gsub(/"/, "", value)
			printf "сеть %s (%s): %s\n", ssid, iface, (value == "1" ? "выключена" : "включена")
			iface = ""; next
		}'
}

cmd_wifi() {
	_mode="${1:-status}"
	shift 2>/dev/null || true

	case "$_mode" in
	status)
		cmd_wifi_status
		;;
	radio)
		_name="${1:-}"
		_state="${2:-}"
		[ -n "$_name" ] && [ -n "$_state" ] || {
			echo "usage: pejir-sys wifi radio <radio0|radio1> on|off"; return 2; }
		[ -f "$WIRELESS_CONF" ] || { echo "Wi-Fi не настроен"; return 1; }
		case "$_state" in
		on)  _dis="0" ;;
		off) _dis="1" ;;
		*) echo "состояние должно быть on или off"; return 2 ;;
		esac
		"$UCI_BIN" set "wireless.$_name.disabled=$_dis" || { echo "не удалось записать wireless.$_name.disabled"; return 1; }
		"$UCI_BIN" commit wireless || { echo "не удалось сохранить конфиг"; return 1; }
		# shellcheck disable=SC2086
		$WIFI_RELOAD >/dev/null 2>&1
		echo "радио $_name: $([ "$_dis" = "1" ] && echo выключен || echo включён)"
		;;
	ssid)
		_ssid="${1:-}"
		_state="${2:-}"
		[ -n "$_ssid" ] && [ -n "$_state" ] || {
			echo "usage: pejir-sys wifi ssid <имя> on|off"; return 2; }
		[ -f "$WIRELESS_CONF" ] || { echo "Wi-Fi не настроен"; return 1; }
		_iface="$(wifi_iface_by_ssid "$_ssid")"
		[ -n "$_iface" ] || { echo "сеть \"$_ssid\" не найдена"; return 1; }
		case "$_state" in
		on)  _dis="0" ;;
		off) _dis="1" ;;
		*) echo "состояние должно быть on или off"; return 2 ;;
		esac
		"$UCI_BIN" set "wireless.$_iface.disabled=$_dis" || { echo "не удалось записать wireless.$_iface.disabled"; return 1; }
		"$UCI_BIN" commit wireless || { echo "не удалось сохранить конфиг"; return 1; }
		# shellcheck disable=SC2086
		$WIFI_RELOAD >/dev/null 2>&1
		echo "сеть $_ssid: $([ "$_dis" = "1" ] && echo выключена || echo включена)"
		;;
	reload)
		# shellcheck disable=SC2086
		$WIFI_RELOAD >/dev/null 2>&1 && echo "конфиг беспроводной связи перезагружен" \
			|| { echo "не удалось перезагрузить Wi-Fi"; return 1; }
		;;
	*)
		echo "usage: pejir-sys wifi {status|radio <имя> on|off|ssid <имя> on|off|reload}"
		return 2
		;;
	esac
}

cmd_lte() {
	_mode="${1:-status}"
	shift 2>/dev/null || true

	case "$_mode" in
	status)
		_apn="$("$UCI_BIN" -q get network.lte.apn 2>/dev/null)"
		_dev="$("$UCI_BIN" -q get network.lte.device 2>/dev/null)"
		_if="$("$UCI_BIN" -q get network.lte.ifname 2>/dev/null)"
		echo "APN: ${_apn:-не задан}"
		echo "интерфейс: ${_if:-не задан}"
		echo "устройство: ${_dev:-не задано}"
		if [ -n "$_if" ] && [ -d "/sys/class/net/$_if" ]; then
			echo "состояние: поднят"
		else
			echo "состояние: не поднят"
		fi
		;;
	apn)
		_apn="${1:-}"
		[ -n "$_apn" ] || { echo "usage: pejir-sys lte apn <apn>"; return 2; }
		"$UCI_BIN" set "network.lte.apn=$_apn" || { echo "не удалось записать network.lte.apn"; return 1; }
		"$UCI_BIN" commit network || { echo "не удалось сохранить конфиг"; return 1; }
		[ -x "$LTE_INIT" ] || { echo "APN записан: $_apn (перезапуск LTE недоступен)"; return 0; }
		"$LTE_INIT" restart >/dev/null 2>&1
		echo "APN записан: $_apn, LTE перезапускается (статус - через минуту)"
		;;
	restart)
		[ -x "$LTE_INIT" ] || { echo "нет init-скрипта LTE ($LTE_INIT)"; return 1; }
		"$LTE_INIT" restart >/dev/null 2>&1
		echo "LTE перезапускается (статус - через минуту)"
		;;
	*)
		echo "usage: pejir-sys lte {status|apn <apn>|restart}"
		return 2
		;;
	esac
}

cmd_web() {
	_url="${1:-}"
	[ -n "$_url" ] || { echo "usage: pejir-sys web <url>"; return 2; }

	case "$_url" in
	http://*|https://*) ;;
	*) echo "поддерживаются только http и https"; return 2 ;;
	esac

	_body="$("$WGET" -qO- -T "$WEB_TIMEOUT" --max-redirect=3 "$_url" 2>/dev/null)"
	if [ -z "$_body" ]; then
		echo "не удалось получить страницу"
		return 1
	fi

	printf '%s' "$_body" \
		| sed -e 's/<[sS][cC][rR][iI][pP][tT][^>]*>.*<\/[sS][cC][rR][iI][pP][tT]>//g' \
		      -e 's/<[^>]*>/ /g' \
		| tr '\n\t' '  ' \
		| sed -e 's/[[:space:]]\{2,\}/ /g' -e 's/^ //' -e 's/ $//' \
		| cut -c1-"$WEB_MAX"

	echo
	return 0
}
```

и расширить блок `case`:

```sh
case "${1:-}" in
signal) cmd_signal ;;
uptime) cmd_uptime ;;
battery) cmd_battery ;;
led) shift; cmd_led "$@" ;;
wifi) shift; cmd_wifi "$@" ;;
lte) shift; cmd_lte "$@" ;;
web) shift; cmd_web "$@" ;;
*)
	echo "usage: pejir-sys {signal|uptime|battery|led …|wifi …|lte …|web <url>}" >&2
	exit 2
	;;
esac
```

- [ ] **Step 4: Прогнать тест**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-sys.sh`
Expected: `PASS: системные команды Telegram-моста`

- [ ] **Step 5: Коммит**

```bash
git add package/pejir-telegram && git commit -m "Telegram-мост: индикаторы, Wi-Fi, LTE и чтение веб-страниц"
```

---

### Task 3: `pejir-tg-send` — текст и файл (multipart)

**Files:**
- Create: `package/pejir-telegram/root/usr/libexec/pejir-tg-send`
- Modify: `package/pejir-telegram/Makefile`
- Test: `tests/test-telegram-bridge.sh`

**Interfaces:**
- Consumes: `wget` (TLS), `pejir_telegram` (token/chat), файлы из `/tmp` и `/www`.
- Produces: `pejir-tg-send text <строка>` (код 0/1), `pejir-tg-send file <путь> [подпись]` (код 0/1).

- [ ] **Step 1: Написать падающий тест**

Создать `tests/test-telegram-bridge.sh`:

```sh
#!/bin/sh
# Тест отправки сообщений и файлов Telegram-мостом (pejir-tg-send).
#
# Проверяется:
#   1) helper на месте, исполняемый, синтаксис shell корректен;
#   2) текст уходит в sendMessage;
#   3) файл уходит в sendDocument как multipart/form-data, с правильным
#      именем и содержимым;
#   4) файлы вне /tmp и /www и файлы больше 20 МБ не отправляются.

set -u

if [ -n "${OW_TEST:-}" ]; then
	TREE="$OW_TEST"
else
	TREE="${PEJIR_OW_TEST:-/workspace/ow-test}"
	[ -d "$TREE" ] || { echo "FAIL: нет дерева $TREE (задайте OW_TEST)"; exit 1; }
fi

SEND="$TREE/package/pejir-telegram/root/usr/libexec/pejir-tg-send"
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$SEND" ] || { echo "FAIL: нет $SEND"; exit 1; }
[ -x "$SEND" ] && ok "helper: исполняемый" || fail "helper: не исполняемый"
sh -n "$SEND" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"

WORK="${PEJIR_TEST_WORK:-/tmp/pejir-test-tgsend}"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/www"

cat > "$WORK/bin/wget" <<'WGETEOF'
#!/bin/sh
post=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
	--post-file) post="$2"; shift 2 ;;
	--header|-T|--timeout|--max-redirect) shift 2 ;;
	-qO-|-q|--quiet|-O) shift ;;
	--) shift; break ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
printf 'URL %s\n' "$url" >> "$SEND_LOG"
[ -n "$post" ] && printf 'BODY %s\n' "$post" >> "$SEND_LOG"
if [ -n "$post" ] && [ -f "$post" ]; then
	cat "$post" >> "$SEND_LOG"
fi
printf '{"ok":true,"result":{"message_id":1}}\n'
exit 0
WGETEOF
chmod 0755 "$WORK/bin/wget"

export PEJIR_TG_SEND_WGET="$WORK/bin/wget"
export PEJIR_TG_SEND_TMP="$WORK/tmp"
export PEJIR_TG_SEND_ROOTS="$WORK/tmp $WORK/www"
export PEJIR_TG_SEND_API="https://api.telegram.org"
export PEJIR_TG_SEND_TOKEN="TESTTOKEN"
export PEJIR_TG_SEND_CHAT="12345"
export SEND_LOG="$WORK/wget.log"

printf 'привет из моста\n' > "$WORK/tmp/отчёт.txt"
printf 'данные\n' > "$WORK/www/page.html"

"$SEND" text "тестовое сообщение" >/dev/null 2>&1
grep -q "sendMessage" "$SEND_LOG" 2>/dev/null && ok "text: запрос в sendMessage" \
	|| fail "text: sendMessage не найден"

: > "$SEND_LOG"
"$SEND" file "$WORK/tmp/отчёт.txt" >/dev/null 2>&1
grep -q "sendDocument" "$SEND_LOG" 2>/dev/null && ok "file: запрос в sendDocument" \
	|| fail "file: sendDocument не найден"
grep -q "multipart/form-data" "$SEND_LOG" 2>/dev/null && ok "file: multipart/form-data" \
	|| fail "file: нет multipart/form-data"
grep -q 'filename=' "$SEND_LOG" 2>/dev/null && ok "file: имя файла в multipart" \
	|| fail "file: нет имени файла"
grep -q "привет из моста" "$SEND_LOG" 2>/dev/null && ok "file: содержимое файла в теле" \
	|| fail "file: содержимое файла не передано"

# файл вне разрешённых корней
: > "$SEND_LOG"
"$SEND" file /etc/passwd >/dev/null 2>&1
[ -s "$SEND_LOG" ] && fail "file: отправлен файл вне /tmp и /www" \
	|| ok "file: файл вне /tmp и /www не отправляется"

# файл больше лимита
dd if=/dev/zero of="$WORK/tmp/big.bin" bs=1024 count=21 2>/dev/null
: > "$SEND_LOG"
"$SEND" file "$WORK/tmp/big.bin" >/dev/null 2>&1
[ -s "$SEND_LOG" ] && fail "file: отправлен файл больше 20 МБ" \
	|| ok "file: файл больше 20 МБ не отправляется"

echo "---"
if [ "$FAILED" -eq 0 ]; then
	echo "PASS: отправка сообщений и файлов"
	exit 0
fi
echo "FAIL: провалено проверок: $FAILED"
exit 1
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-bridge.sh`
Expected: `FAIL: нет .../pejir-tg-send`

- [ ] **Step 3: Реализовать `pejir-tg-send`**

Создать `package/pejir-telegram/root/usr/libexec/pejir-tg-send`:

```sh
#!/bin/sh
# Отправка сообщений и файлов в Telegram.
#
# Helper знает только про Telegram: разбор команды и проверка
# безопасности - в pejir-tg.
#
# Команды:
#   text <строка>            обычное сообщение;
#   file <путь> [подпись]    документ (multipart/form-data).
#
# В образе нет curl, есть wget-ssl (GNU wget) - multipart собираем
# вручную и отправляем через --post-file: тело готовится на диске,
# поэтому файл не читается в память целиком.

set -u

API="${PEJIR_TG_SEND_API:-https://api.telegram.org}"
TOKEN="${PEJIR_TG_SEND_TOKEN:-}"
CHAT="${PEJIR_TG_SEND_CHAT:-}"
WGET="${PEJIR_TG_SEND_WGET:-${PEJIR_TG_WGET:-wget}}"
TMPDIR_SEND="${PEJIR_TG_SEND_TMP:-/tmp}"
ROOTS="${PEJIR_TG_SEND_ROOTS:-/tmp /www}"
MAXSIZE="${PEJIR_TG_SEND_MAXSIZE:-20971520}"
TEXT_MAX="${PEJIR_TG_SEND_TEXT_MAX:-4000}"
TIMEOUT="${PEJIR_TG_SEND_TIMEOUT:-20}"

log() {
	logger -t pejir-tg-send "$*" 2>/dev/null
	echo "pejir-tg-send: $*" >&2
}

urlencode() {
	printf '%s' "$1" | tr '\n' '\001' | LC_ALL=C awk '
BEGIN {
	for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
	nl = sprintf("%c", 1)
}
{
	for (i = 1; i <= length($0); i++) {
		c = substr($0, i, 1)
		if (c == nl) { printf "%%0A"; continue }
		if (c ~ /[A-Za-z0-9]/) { printf "%s", c; continue }
		if (c == " ") { printf "+"; continue }
		if (c == "-") { printf "%%2D"; continue }
		if (c == "_") { printf "%%5F"; continue }
		if (c == ".") { printf "%%2E"; continue }
		printf "%%%02X", ord[c]
	}
}'
}

http_post() {
	"$WGET" -qO- -T "$TIMEOUT" --post-data "$2" "$1" 2>/dev/null
}

# Ответ Telegram: ok или текст ошибки.
check_reply() {
	case "$1" in
	*'"ok":true'*) return 0 ;;
	esac
	printf '%s' "$1" | sed -e 's/.*"description":"\([^"]*\)".*/\1/' | cut -c1-200
	return 1
}

cmd_text() {
	_text="${1:-}"
	[ -n "$_text" ] || { echo "пустое сообщение"; return 2; }
	[ -n "$TOKEN" ] || { echo "не задан токен бота"; return 1; }
	[ -n "$CHAT" ] || { echo "не задан chat ID"; return 1; }

	_len="${#_text}"
	[ "$_len" -gt "$TEXT_MAX" ] && _text="$(printf '%s' "$_text" | cut -c1-"$TEXT_MAX")..."

	_reply="$(http_post "$API/bot$TOKEN/sendMessage" \
		"chat_id=$(urlencode "$CHAT")&text=$(urlencode "$_text")")"

	if check_reply "$_reply" >/dev/null; then
		return 0
	fi

	log "отправка не удалась: $_reply"
	check_reply "$_reply"
	return 1
}

# Путь разрешён, если он внутри одного из корней.
path_allowed() {
	_p="${1:-}"
	[ -n "$_p" ] || return 1
	case "$_p" in
	/*) ;;
	*) return 1 ;;
	esac
	for _root in $ROOTS; do
		case "$_p" in
		"$_root"/*) return 0 ;;
		esac
	done
	return 1
}

cmd_file() {
	_path="${1:-}"
	_caption="${2:-}"
	[ -n "$_path" ] || { echo "не указан файл"; return 2; }
	[ -f "$_path" ] || { echo "файл не найден: $_path"; return 1; }
	[ -n "$TOKEN" ] || { echo "не задан токен бота"; return 1; }
	[ -n "$CHAT" ] || { echo "не задан chat ID"; return 1; }

	path_allowed "$_path" || {
		echo "файл отправляется только из: $ROOTS"
		return 1
	}

	_size="$(stat -c %s "$_path" 2>/dev/null)"
	case "$_size" in
	''|*[!0-9]*) echo "не удалось узнать размер файла"; return 1 ;;
	esac
	[ "$_size" -le "$MAXSIZE" ] || {
		echo "файл больше лимита ($MAXSIZE байт): $_size"
		return 1
	}

	_name="${_path##*/}"
	_boundary="----PejirBoundary$$"
	_body="$TMPDIR_SEND/pejir-tg-body.$$"
	_head="$TMPDIR_SEND/pejir-tg-head.$$"

	{
		printf -- '--%s\r\n' "$_boundary"
		printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n'
		printf '%s\r\n' "$CHAT"
		printf -- '--%s\r\n' "$_boundary"
		printf 'Content-Disposition: form-data; name="caption"\r\n\r\n'
		printf '%s\r\n' "$_caption"
		printf -- '--%s\r\n' "$_boundary"
		printf 'Content-Disposition: form-data; name="document"; filename="%s"\r\n' "$_name"
		printf 'Content-Type: application/octet-stream\r\n\r\n'
	} > "$_head"

	cat "$_path" >> "$_head"
	printf -- '\r\n--%s--\r\n' "$_boundary" >> "$_head"

	_reply="$("$WGET" -qO- -T "$TIMEOUT" \
		--header="Content-Type: multipart/form-data; boundary=$_boundary" \
		--post-file="$_head" \
		"$API/bot$TOKEN/sendDocument" 2>/dev/null)"

	rm -f "$_head" "$_body" 2>/dev/null

	if check_reply "$_reply" >/dev/null; then
		return 0
	fi

	log "отправка файла не удалась: $_reply"
	check_reply "$_reply"
	return 1
}

case "${1:-}" in
text) shift; cmd_text "$@" ;;
file) shift; cmd_file "$@" ;;
*)
	echo "usage: pejir-tg-send {text <строка>|file <путь> [подпись]}" >&2
	exit 2
	;;
esac
```

- [ ] **Step 4: Добавить установку в Makefile**

```make
	$(INSTALL_BIN) ./root/usr/libexec/pejir-tg-send $(1)/usr/libexec/pejir-tg-send
```

- [ ] **Step 5: Прогнать тест**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-bridge.sh`
Expected: `PASS: отправка сообщений и файлов`

- [ ] **Step 6: Коммит**

```bash
git add package/pejir-telegram && git commit -m "Telegram-мост: отправка файлов (multipart) отдельным helper'ом"
```

---

### Task 4: `pejir-tg` — маршрутизация команд, защитный код, flock

**Files:**
- Modify: `package/pejir-telegram/root/usr/libexec/pejir-tg`
- Modify: `tests/test-telegram.sh` (правится под код для `/sms`)
- Test: `tests/test-telegram-bridge.sh` (дополнить), `tests/test-telegram.sh`

**Interfaces:**
- Consumes: `pejir-sys`, `pejir-tg-send`, `pejir_telegram.main.protect`.
- Produces: новые команды `/signal`, `/uptime`, `/battery`, `/led`, `/wifi`, `/lte`, `/file`, `/web`; правило «код — последнее слово» для опасных команд.

- [ ] **Step 1: Дописать в тест моста проверки маршрутизации и кода**

В `tests/test-telegram-bridge.sh` добавить перед `echo "---"`:

```sh
# --- маршрутизация команд и защитный код ----------------------------------
TG="$TREE/package/pejir-telegram/root/usr/libexec/pejir-tg"
[ -f "$TG" ] || { echo "FAIL: нет $TG"; exit 1; }

cat > "$WORK/telegram.conf" <<'CONFEOF'
enabled=1
token=TESTTOKEN
chat=12345
interval=60
commands=1
protect=secret
CONFEOF

cat > "$WORK/bin/pejir-sys" <<'SYSEOF'
#!/bin/sh
printf 'sys %s\n' "$*" >> "${TG_SYS_CALL_LOG:-/dev/null}"
exit 0
SYSEOF
chmod 0755 "$WORK/bin/pejir-sys"

cat > "$WORK/bin/pejir-tg-send" <<'SENDEOF'
#!/bin/sh
printf 'send %s\n' "$*" >> "${TG_SEND_CALL_LOG:-/dev/null}"
exit 0
SENDEOF
chmod 0755 "$WORK/bin/pejir-tg-send"

export PATH="$WORK/bin:$PATH"
export PEJIR_TG_CONF="$WORK/telegram.conf"
export PEJIR_TG_STATE="$WORK/state"
export PEJIR_TG_SPOOL="$WORK/spool"
export PEJIR_TG_WGET="$WORK/bin/wget"
export PEJIR_TG_API="https://api.telegram.org"
export PEJIR_TG_SYS="$WORK/bin/pejir-sys"
export PEJIR_TG_SEND="$WORK/bin/pejir-tg-send"
export TG_SYS_CALL_LOG="$WORK/sys.log"
export TG_SEND_CALL_LOG="$WORK/send.log"

mkdir -p "$WORK/state" "$WORK/spool"

# /signal без кода - выполняется
NOW="$(date +%s)"
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":700,"message":{"message_id":1,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/signal"}}]}
JSONEOF
: > "$TG_SYS_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "sys signal" "$TG_SYS_CALL_LOG" 2>/dev/null && ok "/signal: команда без кода выполнена" \
	|| fail "/signal: команда не выполнена"

# /wifi без кода - НЕ выполняется
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":701,"message":{"message_id":2,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/wifi radio0 off"}}]}
JSONEOF
: > "$TG_SYS_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "sys wifi" "$TG_SYS_CALL_LOG" 2>/dev/null && fail "/wifi: выполнена без защитного кода" \
	|| ok "/wifi: без защитного кода не выполняется"

# /wifi с кодом - выполняется
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":702,"message":{"message_id":3,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/wifi radio0 off secret"}}]}
JSONEOF
: > "$TG_SYS_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "sys wifi radio0 off" "$TG_SYS_CALL_LOG" 2>/dev/null \
	&& ok "/wifi: с защитным кодом выполнена" || fail "/wifi: с кодом не выполнена"

# /file с кодом - файл отправляется
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":703,"message":{"message_id":4,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/file $WORK/tmp/отчёт.txt secret"}}]}
JSONEOF
: > "$TG_SEND_CALL_LOG"
"$TG" commands >/dev/null 2>&1
grep -q "send file" "$TG_SEND_CALL_LOG" 2>/dev/null && ok "/file: файл уходит в pejir-tg-send" \
	|| fail "/file: файл не отправлен"
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram-bridge.sh`
Expected: `FAIL: /signal: команда не выполнена`

- [ ] **Step 3: Реализовать маршрутизацию в `pejir-tg`**

В `package/pejir-telegram/root/usr/libexec/pejir-tg`:

а) добавить переменные рядом с существующими путями:

```sh
SYS_BIN="${PEJIR_TG_SYS:-/usr/libexec/pejir-sys}"
SEND_BIN="${PEJIR_TG_SEND:-/usr/libexec/pejir-tg-send}"
LOCK_FILE="${PEJIR_TG_LOCK:-/tmp/pejir-tg.lock}"
```

б) рядом с `exec_command()` добавить функции:

```sh
# Последнее слово команды - защитный код. Если оно совпало с кодом,
# команда разрешена, а сам код из аргументов убирается.
#
# Опасные команды (/wifi, /lte, /file, /web, /sms, /reboot) требуют
# кода: без него они не выполняются вовсе.
protect_ok() {
	_prot="$(cfg protect)"
	[ -n "$_prot" ] || return 1
	_last="${1##* }"
	[ "$_last" = "$_prot" ] || return 1
	return 0
}

strip_protect() {
	_prot="$(cfg protect)"
	[ -n "$_prot" ] || { printf '%s' "$1"; return 0; }
	case "$1" in
	*" $_prot") printf '%s' "${1% $_prot}" ;;
	*) printf '%s' "$1" ;;
	esac
}

# Опасная операция под замком: два запроса не должны наложиться.
run_locked() {
	exec 9>"$LOCK_FILE" || return 1
	flock -w 60 9 || return 1
	"$@"
}
```

в) в `exec_command()` добавить ветки (перед `*)`):

```sh
	/signal*|/uptime*|/battery*)
		"$SYS_BIN" "$1" 2>&1 | sed -n '1,20p' | while IFS= read -r _line; do
			tg_send "$_line"
		done
		;;
	/led*)
		_cmd="$(strip_protect "$_cmd")"
		_out="$("$SYS_BIN" led ${_cmd#/led } 2>&1 | head -20)"
		tg_send "$_out"
		;;
	/wifi*)
		protect_ok "$_cmd" || { tg_send "Нужен защитный код (последнее слово команды)."; return 0; }
		_cmd="$(strip_protect "$_cmd")"
		run_locked "$SYS_BIN" wifi ${_cmd#/wifi } 2>&1 | while IFS= read -r _line; do
			tg_send "$_line"
		done
		;;
	/lte*)
		protect_ok "$_cmd" || { tg_send "Нужен защитный код (последнее слово команды)."; return 0; }
		_cmd="$(strip_protect "$_cmd")"
		run_locked "$SYS_BIN" lte ${_cmd#/lte } 2>&1 | while IFS= read -r _line; do
			tg_send "$_line"
		done
		;;
	/file*)
		protect_ok "$_cmd" || { tg_send "Нужен защитный код (последнее слово команды)."; return 0; }
		_cmd="$(strip_protect "$_cmd")"
		_path="${_cmd#/file }"
		_path="${_path%% *}"
		run_locked "$SEND_BIN" file "$_path" 2>&1 | while IFS= read -r _line; do
			tg_send "$_line"
		done
		;;
	/web*)
		protect_ok "$_cmd" || { tg_send "Нужен защитный код (последнее слово команды)."; return 0; }
		_cmd="$(strip_protect "$_cmd")"
		_url="${_cmd#/web }"
		run_locked "$SYS_BIN" web "$_url" 2>&1 | while IFS= read -r _line; do
			tg_send "$_line"
		done
		;;
```

г) `/sms` теперь тоже требует кода — в существующей ветке `/sms\ *|/sms@*` после проверки `commands` добавить проверку кода:

```sh
		if [ "$(cfg commands)" != "1" ]; then
			tg_send "Команды выключены - включите их на странице SMS."
			return 0
		fi
		if ! protect_ok "$_cmd"; then
			tg_send "Нужен защитный код (последнее слово команды)."
			return 0
		fi
		_cmd="$(strip_protect "$_cmd")"
		_rest="${_cmd#* }"
```

д) в `help_text()` добавить новые команды:

```sh
help_text() {
	printf 'Команды:\n/sms <номер> <текст> <код> - отправить SMS\n/status - состояние модема\n/signal - уровень сигнала\n/uptime - время работы и память\n/battery - заряд батареи\n/led <имя> <цвет> - индикаторы\n/wifi radio <имя> on|off <код> - Wi-Fi\n/lte apn <apn> <код> - сменить APN и перезапустить LTE\n/file <путь> <код> - прислать файл\n/web <url> <код> - прислать страницу\n/reboot <код> - перезагрузить роутер\n/chatid - показать ID этого чата\n/help - эта справка'
}
```

- [ ] **Step 4: Править существующий тест `tests/test-telegram.sh`**

В блоке 5c заменить команду `/sms 79161234567 привет из чата` на
`/sms 79161234567 привет из чата secret`, а команду из чужого чата оставить
без кода. Добавить отдельную проверку, что `/sms` без кода не исполняется:

```sh
# /sms без защитного кода - не выполняется
: > "$TG_FAKE_SMS"
cat > "$WORK/updates.json" <<JSONEOF
{"ok":true,"result":[
{"update_id":610,"message":{"message_id":9,"chat":{"id":12345,"type":"private"},"date":$NOW,"text":"/sms 79161234567 без кода"}}]}
JSONEOF
"$HELPER" commands >/dev/null 2>&1
[ -s "$TG_FAKE_SMS" ] && fail "команды: /sms выполнен без защитного кода" \
	|| ok "команды: /sms без защитного кода не выполняется"
```

- [ ] **Step 5: Прогнать оба теста**

Run: `OW_TEST=/workspace/w79v sh tests/test-telegram.sh && OW_TEST=/workspace/w79v sh tests/test-telegram-bridge.sh`
Expected: оба `PASS`

- [ ] **Step 6: Коммит**

```bash
git add package/pejir-telegram tests/test-telegram.sh && git commit -m "Telegram-мост: команды Wi-Fi, LTE, индикаторов, файлов и веба; защитный код для опасных команд"
```

---

### Task 5: CI, проверка на устройстве, документация, патч

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `docs/CHANGELOG.md`
- Modify: `README.md`
- Create: `check_rel77.sh` (в репозитории `openwrt-pejir01` → `/workspace/check_rel77.sh`)

**Interfaces:**
- Produces: патч `0175` в `patches/`, тесты в CI, скрипт проверки на устройстве.

- [ ] **Step 1: Добавить тесты в CI**

В `.github/workflows/build.yml` рядом с `sh tests/test-telegram.sh` добавить:

```yaml
          sh tests/test-telegram-sys.sh
          sh tests/test-telegram-bridge.sh
```

- [ ] **Step 2: Проверить, что оба теста падают на старом дереве**

Run: `OW_TEST=/workspace/w77v sh tests/test-telegram-sys.sh; OW_TEST=/workspace/w77v sh tests/test-telegram-bridge.sh`
Expected: обе падают (нет файлов `pejir-sys`/`pejir-tg-send`)

- [ ] **Step 3: Собрать патч 0175**

```bash
cd /workspace/w79v
git format-patch --stdout -1 HEAD > /tmp/0175.patch
python3 /workspace/mkpatchhdr.py /tmp/0175.patch /workspace/w79v
cp /tmp/0175.patch /workspace/openwrt-pejir01/patches/0175-telegram-bot-extension.patch
```

- [ ] **Step 4: Проверить серию целиком**

```bash
cd /workspace/w71
git worktree add --detach /workspace/w80v 64900e756efa667774214f9c6b17c113222e01f7
cd /workspace/w80v
git am --3way /workspace/openwrt-pejir01/patches/*.patch
cd /workspace/openwrt-pejir01
for t in tests/test-*.sh; do OW_TEST=/workspace/w80v sh "$t" || echo "FAIL $t"; done
```

Expected: `git am` exit 0, ни одного `FAIL`.

- [ ] **Step 5: Написать `check_rel77.sh`**

Скопировать `/workspace/check_rel75.sh` в `/workspace/check_rel77.sh`, добавить
проверку 46) — «Telegram-мост расширен»:

```sh
# --- 46) РАСШИРЕННЫЙ TELEGRAM-МОСТ (релиз .77) -----------------------------
head1 "46) РАСШИРЕННЫЙ TELEGRAM-МОСТ"

for f in /usr/libexec/pejir-tg /usr/libexec/pejir-tg-send /usr/libexec/pejir-sys; do
	if [ -x "$f" ]; then
		ok "есть $f"
	else
		bad "нет $f - расширение бота не установлено"
	fi
done

if grep -q "pejir-sys" /usr/libexec/pejir-tg 2>/dev/null; then
	ok "мост вызывает системный helper"
else
	bad "мост не вызывает pejir-sys"
fi

if grep -q "pejir-tg-send" /usr/libexec/pejir-tg 2>/dev/null; then
	ok "мост вызывает helper отправки"
else
	bad "мост не вызывает pejir-tg-send"
fi

if /usr/libexec/pejir-sys signal 2>/dev/null | grep -q "сигнал"; then
	ok "pejir-sys signal отдаёт данные"
else
	bad "pejir-sys signal не отдаёт данные (нет кеша модема?)"
fi

if /usr/libexec/pejir-sys battery 2>/dev/null | grep -q "уровень"; then
	ok "pejir-sys battery отдаёт данные"
else
	bad "pejir-sys battery не отдаёт данные"
fi
```

- [ ] **Step 6: Обновить CHANGELOG и README**

В `docs/CHANGELOG.md` добавить раздел `## 25.12.6-pejir01.77` с описанием
новых команд и правил (защитный код, лимиты файлов).

В `README.md` — раздел про Telegram-мост с таблицей команд.

- [ ] **Step 7: Коммит и пуш**

```bash
cd /workspace/openwrt-pejir01
git add -A
python3 /workspace/push_via_api.py main "Telegram-мост: Wi-Fi, LTE, индикаторы, /signal, /uptime, /battery, файлы и веб-страницы"
```

- [ ] **Step 8: Собрать релиз `.77`**

Дождаться успешного CI, создать тег `v25.12.6-pejir01.77`, опубликовать
релиз, залить ассеты (`check_rel77.sh`, `zigbee_check.sh`, `.gbl`),
сверить sha256.

## Self-review

- **Покрытие спецификации:** §3.1 (multipart) — Task 3; §3.2 (все подкоманды
  `pejir-sys`) — Tasks 1–2; §3.3 (список команд) — Task 4; §3.4 (защитный
  код, чат, возраст) — Task 4; §4 (поток данных) — Task 4; §5 (ошибки) —
  Tasks 1–4; §6 (тесты) — Tasks 1–4 + проверка «падает на старом коде» в
  Task 5 Step 2; §7 (релиз `.77`, патч `0175`) — Task 5.
- **Заглушки:** нет; код приведён целиком в каждом шаге.
- **Согласованность имён:** `pejir-sys`, `pejir-tg-send`, `SYS_BIN`,
  `SEND_BIN`, `LOCK_FILE`, `protect_ok`, `strip_protect`, `run_locked` —
  одинаково используются в Task 3, Task 4 и тестах.
- **Расхождение со спецификацией:** в спецификации §3.2 перечислены
  `signal`, `uptime`, `battery`, `led`, `wifi`, `lte`; подкоманда `web`
  добавлена в §3.2 при реализации (Task 2) — спецификацию нужно дополнить
  строкой `web` в таблице.
