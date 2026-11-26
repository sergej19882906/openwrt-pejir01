#!/bin/sh
# Тест кодировки исходящих SMS.
#
# Дефект, который закрывает тест: русский текст в исходящем SMS доходил
# до телефона нечитаемым. Корень найден по исходникам smsd 3.1.21
# (smsd_cfg.c, smsd.c, charset.c) и подтверждён бинарём smsd из образа:
#
#   1) /usr/bin/sendsms (штатный скрипт smstools3) пишет тело сообщения
#      СЫРЫМ UTF-8 и БЕЗ заголовка "Alphabet:". Заголовок добавляется
#      только если в системе есть iconv (iconv -t ISO-8859-15); в нашем
#      образе iconv нет, поэтому текст кладётся как есть.
#
#   2) smsd читает файл очереди: readSMSheader() (smsd.c:1124) при
#      отсутствии заголовка "Alphabet:" берёт default_alphabet, а он по
#      умолчанию ALPHABET_ISO (smsd_cfg.c:380, smsd_cfg.h:125).
#      Файл с UTF-8 читается как ISO-8859-15.
#
#   3) Дальше исходящий путь (smsd.c:4648-4651): do_convert=1, потому
#      что алфавит ISO, и readSMStext() зовёт iso_utf8_2gsm(). Для
#      кириллицы utf8_to_iso_char() (charset.c:1148) не находит символа
#      в ISO-8859-15 и возвращает 2 байта, НЕ выставляя *iso, поэтому
#      ch=0, char2gsm(0) не найден, символ теряется, а в журнале пишется
#      "Cannot convert N character to GSM".
#
#   4) Ветка авто-UCS2 есть только для ALPHABET_UTF8 (smsd.c:4711):
#      если символы не помещаются в GSM 03.38, smsd сам переводит всё
#      сообщение в UCS2 (iso_utf8_2ucs) и отправляет с DCS 0x08.
#
#   Вывод: лечится ОДНОЙ глобальной опцией smsd.conf - "alphabet = utf".
#   Она меняет default_alphabet на ALPHABET_UTF8, и наш UTF-8-файл
#   обрабатывается правильной веткой.
#
# ВАЖНО: "alphabet", "outgoing_utf8" и "incoming_utf8" - ГЛОБАЛЬНЫЕ
# опции smsd. В секции [GM510] они недопустимы: readcfg_device()
# (smsd_cfg.c) для неизвестной опции печатает "Unknown setting for
# modem" и smsd не стартует. Глобальные опции читаются только ДО
# первой секции "[" (cfgfile.c: my_getline возвращает 0 на строке,
# начинающейся с "["), поэтому в конфиге они должны стоять выше "[GM510]".
#
# "incoming_utf8 = yes" нужен для входящих: иначе входящий UCS2
# переводится в ISO-8859-15 (smsd.c:3418), где кириллицы нет, и русский
# текст в списке входящих в LuCI тоже нечитаем.
#
# Тест проверяет ПОВЕДЕНИЕ, а не наличие строки: он запускает
# write_conf() из init-скрипта в песочнице и смотрит на результат.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие дерева - ошибка.
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"
INIT="$TREE/package/pejir-sms/root/etc/init.d/40-pejir-sms"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$INIT" ] || { echo "FAIL: нет файла $INIT"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- helper: запустить write_conf() из init-скрипта в песочнице ---------
# init-скрипт написан под rc.common и использует "local", поэтому
# запускаем его под bash (на устройстве это busybox ash).
# Копия правит пути конфига на песочницу, чтобы не трогать /etc.
run_write_conf() {
	local conf="$1" userconf="$2" port="$3"

	sed -e "s#^CONF=.*#CONF=\"$conf\"#" \
	    -e "s#^USER_CONF=.*#USER_CONF=\"$userconf\"#" \
	    -e "s#^LOG=.*#LOG=\"$WORK/smsd.log\"#" \
	    "$INIT" > "$WORK/init.sh"

	bash -c '. "$1"; write_conf "$2"' _ "$WORK/init.sh" "$port" \
		> "$WORK/out.txt" 2>&1
}

# Первая строка секции - граница между глобальной частью и секциями.
section_line() {
	grep -n '^[[:space:]]*\[' "$1" | head -1 | cut -d: -f1
}

opts_in_global_part() {
	local f="$1" sec
	sec="$(section_line "$f")"
	if [ -z "$sec" ]; then
		cat "$f"
	else
		sed -n "1,$((sec - 1))p" "$f"
	fi
}

opts_in_device_part() {
	local f="$1" sec
	sec="$(section_line "$f")"
	[ -n "$sec" ] || return 0
	sed -n "${sec},\$p" "$f"
}

check_global_opts() {
	local f="$1" what="$2" ok_all=1

	for opt in "alphabet = utf" "outgoing_utf8 = yes" "incoming_utf8 = yes"; do
		if opts_in_global_part "$f" | grep -qxF "$opt"; then
			ok "$what: в глобальной части есть '$opt'"
		else
			fail "$what: в глобальной части нет '$opt' - smsd прочитает файл как ISO-8859-15 и потеряет кириллицу"
			ok_all=0
		fi
	done

	# В секции устройства глобальные опции недопустимы.
	for opt in "alphabet" "outgoing_utf8" "incoming_utf8"; do
		if opts_in_device_part "$f" | grep -q "^[[:space:]]*$opt[[:space:]]*="; then
			fail "$what: '$opt' попала в секцию устройства - smsd скажет 'Unknown setting for modem' и не стартует"
			ok_all=0
		fi
	done

	return $((1 - ok_all))
}

# --- 1) конфиг, созданный с нуля ------------------------------------------
CONF="$WORK/smsd.conf"
USER_CONF="$WORK/smsd.conf.user"
rm -f "$CONF" "$USER_CONF"

if run_write_conf "$CONF" "$USER_CONF" /dev/ttyUSB2; then
	if [ -f "$CONF" ]; then
		ok "write_conf() создал конфиг"
	else
		fail "write_conf() не создал конфиг"
	fi
else
	fail "write_conf() завершился с ошибкой: $(cat "$WORK/out.txt" 2>/dev/null | head -3)"
fi

if [ -f "$CONF" ]; then
	check_global_opts "$CONF" "новый конфиг" || true

	if grep -q "^device = /dev/ttyUSB2$" "$CONF"; then
		ok "новый конфиг: порт модема прописан"
	else
		fail "новый конфиг: нет порта модема"
	fi
fi

# --- 2) обновление своего конфига (устройство уже с .45) ------------------
# На устройстве лежит конфиг, созданный старой версией скрипта: своего
# маркера нет, опций кодировки нет. write_conf() должна их добавить,
# сохранив остальной конфиг (в т.ч. секцию [GM510]).
CONF2="$WORK/smsd2.conf"
USER_CONF2="$WORK/smsd2.conf.user"
cat > "$CONF2" <<'OLDCONF'
#
# Description: Main configuration file for the smsd
#
# generated by 40-pejir-sms

devices = GM510
incoming = /var/spool/sms/incoming
outgoing = /var/spool/sms/outgoing
logfile = /var/log/smsd.log
loglevel = 5

[GM510]
device = /dev/ttyUSB2
baudrate = 115200
init = AT+CMGF=1
incoming = yes
outgoing = yes
decode_unicode_text = yes
OLDCONF

if run_write_conf "$CONF2" "$USER_CONF2" /dev/ttyUSB2; then
	ok "write_conf() отработала на своём старом конфиге"
else
	fail "write_conf() упала на своём старом конфиге: $(cat "$WORK/out.txt" 2>/dev/null | head -3)"
fi

if [ -f "$CONF2" ]; then
	check_global_opts "$CONF2" "обновлённый конфиг" || true

	# Секция устройства не должна потерять пользовательские настройки.
	if grep -q "^baudrate = 115200$" "$CONF2" && grep -q "^decode_unicode_text = yes$" "$CONF2"; then
		ok "обновлённый конфиг: секция [GM510] сохранена"
	else
		fail "обновлённый конфиг: секция [GM510] потеряна или испорчена"
	fi

	if grep -q "^device = /dev/ttyUSB2$" "$CONF2"; then
		ok "обновлённый конфиг: порт модема на месте"
	else
		fail "обновлённый конфиг: порт модема потерян"
	fi

	# Опции не должны дублироваться при повторном запуске.
	run_write_conf "$CONF2" "$USER_CONF2" /dev/ttyUSB2 || true
	n="$(grep -c '^alphabet = utf$' "$CONF2")"
	if [ "$n" -eq 1 ]; then
		ok "повторный запуск не дублирует опции кодировки"
	else
		fail "повторный запуск: опций 'alphabet = utf' стало $n (ожидалась 1)"
	fi
fi

# --- 2a) опции секции модема приводятся к канону -------------------------
# decode_unicode_text = yes нужен, чтобы входящие UCS2-сообщения
# (кириллица) сразу читались как UTF-8: без него smsd переводит их в
# ISO-8859-15, где кириллицы нет, и символы выбрасываются.
# notice_ucs2 = 0 - чтобы служебные строки NOTICE ("Cannot convert ...
# to GSM") не попадали в файлы сообщений, а оттуда - в текст сообщения
# на странице LuCI.
CONF4="$WORK/smsd4.conf"
cat > "$CONF4" <<'OLDCONF'
#
# generated by 40-pejir-sms

alphabet = utf
outgoing_utf8 = yes
incoming_utf8 = yes

devices = GM510
logfile = /var/log/smsd.log

[GM510]
device = /dev/ttyUSB2
baudrate = 115200
decode_unicode_text = no
notice_ucs2 = 2
incoming = yes
OLDCONF

sed -e "s#^CONF=.*#CONF=\"$CONF4\"#"     -e "s#^USER_CONF=.*#USER_CONF=\"$WORK/smsd4.conf.user\"#"     -e "s#^LOG=.*#LOG=\"$WORK/smsd.log\"#" \
    "$INIT" > "$WORK/init4.sh"
bash -c '. "$1"; ensure_device_options' _ "$WORK/init4.sh" > "$WORK/out4.txt" 2>&1

if grep -q "^decode_unicode_text = yes$" "$CONF4"; then
	ok "секция модема: decode_unicode_text приведён к yes"
else
	fail "секция модема: decode_unicode_text не приведён к yes"
fi

if grep -q "^notice_ucs2 = 0$" "$CONF4"; then
	ok "секция модема: notice_ucs2 приведён к 0"
else
	fail "секция модема: notice_ucs2 не приведён к 0"
fi

n="$(grep -c '^decode_unicode_text' "$CONF4")"
if [ "$n" -eq 1 ]; then
	ok "секция модема: decode_unicode_text не задвоилась"
else
	fail "секция модема: decode_unicode_text встречается $n раз"
fi

n="$(grep -c '^notice_ucs2' "$CONF4")"
if [ "$n" -eq 1 ]; then
	ok "секция модема: notice_ucs2 не задвоилась"
else
	fail "секция модема: notice_ucs2 встречается $n раз"
fi

# Пользовательские настройки секции должны остаться.
if grep -q "^baudrate = 115200$" "$CONF4" && grep -q "^device = /dev/ttyUSB2$" "$CONF4"; then
	ok "секция модема: пользовательские настройки сохранены"
else
	fail "секция модема: пользовательские настройки потеряны"
fi

# --- 3) чужой конфиг не трогаем -------------------------------------------
CONF3="$WORK/smsd3.conf"
USER_CONF3="$WORK/smsd3.conf.user"
cat > "$CONF3" <<'USERCONF'
# Пользовательский конфиг, правленный руками.
[GSM1]
device = /dev/ttyUSB9
USERCONF

run_write_conf "$CONF3" "$USER_CONF3" /dev/ttyUSB2 || true
if [ -f "$CONF3" ] && grep -q "^device = /dev/ttyUSB9$" "$CONF3"; then
	ok "чужой конфиг не переписан (правки пользователя сохранены)"
else
	fail "чужой конфиг переписан - правки пользователя потеряны"
fi

# --- 4) опции есть в самом init-скрипте ------------------------------------
for opt in "alphabet = utf" "outgoing_utf8 = yes" "incoming_utf8 = yes"; do
	if grep -qF "$opt" "$INIT"; then
		ok "init-скрипт содержит '$opt'"
	else
		fail "init-скрипт не содержит '$opt'"
	fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты кодировки SMS пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
