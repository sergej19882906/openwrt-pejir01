# Собственный mwan для Perenio PEJIR01 — дизайн

Дата: 2026-11-26
Статус: согласован с пользователем, готов к реализации
Релиз: `.65` (отдельно от текущего `.64`)

## 1. Задача

На PEJIR01 два выхода в интернет: `wan` (eth0, DHCP) и `lte` (eth1, DHCP,
`metric 30`). Сейчас работает только резервирование на уровне метрики:
пока eth0 поднят — трафик идёт в WAN, при его пропадании netifd убирает
маршрут и трафик уходит в LTE. Проверки живости нет (netifd знает только
«интерфейс поднят»), и деления трафика между каналами нет.

`mwan3` в образ не включён (патч 0132, релиз `.63`): в OpenWrt 25.12 он
работает только через iptables и тянул за собой стоковый
`/etc/config/mwan3` из образа. Остатки пакета в верхнем слое вычищаются
патчем 0135.

Требуется собственный модуль с тремя режимами, переключаемыми в LuCI:

- `balance` — новые соединения делятся между WAN и LTE, при падении одного
  канала весь трафик уходит на оставшийся;
- `failover` — основной канал + резервный, переключение по health-чеку;
- `pbr` — список адресов через LTE, остальное через WAN.

Модуль по умолчанию **выключен**.

## 2. Ограничения и решения

| Вопрос | Решение |
|---|---|
| Настоящий ECMP с весами | В netifd нет. Реализуем деление новых соединений через `nft numgen` + `ip rule fwmark` |
| Каналы | Ровно два, фиксированные: `wan` (eth0) и `lte` (eth1) |
| Состояние после прошивки | Выключено (`option enabled '0'`) — маршрутизация не меняется до явного включения |
| Основная таблица `main` | Не трогаем: если модуль сломается, интернет останется на старой маршрутизации |
| IPv6 | Не покрываем (LTE6/netifd как есть); ограничение показываем в UI |
| Инструменты в образе | Добавляем `ip-full` (busybox `ip` не умеет `ip rule fwmark` в полном виде); `nftables` уже есть |

## 3. Пакет и файлы

```
package/pejir-mwan/
  Makefile
  root/etc/config/pejir_mwan              # дефолтный конфиг (выключен)
  root/etc/init.d/50-pejir-mwan           # procd: демон, авторестарт
  root/usr/libexec/pejir-mwan             # демон
  root/usr/libexec/pejir-mwan-ctl         # status|enable|disable|apply|check
```

Плюс изменения в существующих пакетах:

- `package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/mwan.js` — страница;
- `package/luci-app-perenio/root/usr/share/rpcd/acl.d/luci-app-perenio.json` — гранты;
- `package/luci-app-perenio/po/ru/luci-app-perenio.po` — переводы;
- `build.sh` — `CONFIG_PACKAGE_pejir-mwan=y`, `CONFIG_PACKAGE_ip-full=y`.

## 4. Конфиг `/etc/config/pejir_mwan`

```
config mwan 'main'
	option enabled '0'            # по умолчанию выключено
	option mode 'balance'         # balance | failover | pbr
	option wan_iface 'wan'
	option wan_device 'eth0'
	option lte_iface 'lte'
	option lte_device 'eth1'
	option wan_table '100'
	option lte_table '200'
	option wan_weight '50'        # % новых соединений в режиме balance
	option check_interval '10'    # секунд между проверками
	option check_count '3'        # столько неудач подряд => канал down
	option check_target ''        # пусто => ping шлюза; IP => ping; http(s) => uclient-fetch
	option pbr_list ''            # CIDR через запятую => LTE (режим pbr)
```

`pbr_list` — список CIDR, разделённых запятой или пробелом; можно расширить
на список с одним CIDR в строке в отдельной секции `config pbr_entry` —
решается при реализации, формат через запятую является основным.

## 5. Механика

### 5.1 Таблицы маршрутизации

Демон получает шлюз и фактическое устройство из
`ubus call network.interface.<iface> status` (поля `data.up`,
`data.gateway`, `data.l3_device`) и строит две таблицы:

```
table 100 (wan):  ip route add <subnet eth0> dev eth0 scope link table 100
                  ip route add default via <gw_wan> dev eth0 table 100
table 200 (lte):  ip route add <subnet eth1> dev eth1 scope link table 200
                  ip route add default via <gw_lte> dev eth1 table 200
```

Маршруты в `main` не трогаем.

### 5.2 Разметка трафика (nftables), только режим `balance`

```
table inet pejir_mwan {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ct state established,related meta mark set ct mark
    ct state new numgen random mod 2 vmap { 0 : jump to_wan, 1 : jump to_lte }
    ct state new ct mark set meta mark
  }
  chain to_wan { meta mark set 0x1; return; }
  chain to_lte { meta mark set 0x2; return; }
}
```

- `numgen random mod 2` даёт честные 50/50 на каждое **новое** соединение;
- `ct mark` запоминает выбор, поэтому уже установленные сессии не «прыгают»
  между каналами;
- цепочки `output` НЕТ: помечается только клиентский трафик. Трафик самого
  роутера (резолвер, telegram-мост, OTA) идёт через `main`, где маршруты
  расставляет netifd, и потому следует за интерфейсами сам. Если бы мы
  помечали и его, то проверка живости канала сама улетала бы в другой
  канал (`ping -I` не мешает `ip rule` по метке) и врала;
- при недоступности `nft numgen` (ядро без `CONFIG_NFT_NUMGEN`) режим
  `balance` недоступен, демон работает в `failover`, UI показывает причину.

### 5.3 Правила `ip rule`

| Режим | Правила |
|---|---|
| balance, оба канала живы | `pref 100 fwmark 0x1 lookup 100`, `pref 101 fwmark 0x2 lookup 200`, `pref 900 lookup 100` |
| balance, жив только LTE | `pref 100 fwmark 0x1 lookup 200`, `pref 101 fwmark 0x2 lookup 200`; карта `numgen` в nft переключается на `to_lte` для обоих значений |
| balance, жив только WAN | симметрично, `lookup 100` |
| failover | `pref 100 lookup <активная таблица>`, `pref 900 lookup <вторая таблица>`; пока оба канала живы, активна таблица WAN |
| pbr | `pref 100 to <CIDR> lookup 200` для каждого адреса списка + `pref 900 lookup 100` |

Правила модуля используют префиксы 100–999; `stop` снимает именно их.

### 5.4 Health-чек

- источник истины — `ubus`: `data.up`, `data.gateway`, `data.l3_device`;
- проверка живости: `ping -I <устройство> -c1 -W2 <gateway>`; при заданном
  `check_target` пингуется внешний IP вместо шлюза. `-I` обязателен: иначе
  проверка ушла бы в другой канал. Проверка по URL не поддерживается —
  `uclient-fetch` не умеет привязаться к интерфейсу, а именно это здесь и
  нужно;
- `check_count` неудач подряд ⇒ канал `down` ⇒ переключение; один успех ⇒ `up`;
- для LTE дополнительно требуется наличие `eth1` и `data.up`.

### 5.5 DNS

Основную таблицу `main` модуль не меняет - в том числе DNS-маршруты в неё
не добавляет. Резолв и так устроен правильно: netifd ставит DNS-серверы
интерфейса в `main` вместе с его маршрутом и убирает, когда интерфейс
падает, поэтому DNS следует за каналами сам.

Что модуль делает для DNS: `check_target` позволяет отличить «канал жив»
(шлюз пингуется) от «интернет есть» (пингуется внешний IP). Если провайдер
WAN не отдаёт интернет, но шлюз доступен, health-чек с внешним адресом
правильно переключит трафик на LTE; с проверкой только шлюза этого не
произойдёт.

### 5.6 Управление состоянием

- демон — shell-цикл: опрос → пересчёт состояния → применение правил;
- состояние в `/tmp/pejir-mwan.state` (режим, каналы, активная таблица,
  uptime, счётчики); пути состояния и список сетевых устройств
  переопределяются переменными окружения (`PEJIR_MWAN_STATE`,
  `PEJIR_MWAN_APPLIED`, `PEJIR_MWAN_LOG`, `PEJIR_MWAN_NFT`,
  `PEJIR_MWAN_PID`, `PEJIR_MWAN_SYSNET`) - это нужно тесту, который
  работает на сборочной машине, где `eth0`/`eth1` не существуют;
- procd-автоперезапуск; повторная установка правил при рестарте сети
  (init-скрипт слушает hotplug через `netifd`/ubus или вызывается из
  `50-pejir-mwan` при `start`).
- `stop` снимает: nft-таблицу `pejir_mwan`, `ip rule` с префиксами 100–999,
  маршруты из таблиц 100/200 и DNS-маршруты, добавленные модулем.
- Если оба канала `down` — ничего не переключаем (лучше старый маршрут,
  чем пустота).

## 6. LuCI

Страница `perenio/mwan.js` в существующем приложении «Perenio» (без нового
приложения — меньше i18n-возни), правило меню рядом с остальными страницами
приложения.

Элементы:

- тумблер «Включено» с подписью «по умолчанию выключено»;
- выбор режима: `Баланс 50/50` / `Резерв` / `По адресам (PBR)`;
- поля: WAN/LTE — интерфейс и устройство; вес WAN (%); интервал и порог
  проверок; цель проверки;
- в режиме PBR — список CIDR;
- кнопки **Применить** и **Выключить**;
- блок состояния: режим, оба канала (up/down, время последней проверки),
  активная таблица, счётчики пакетов по меткам (из nft counters), uptime;
- если `nft numgen` недоступен — режим «Баланс» помечается недоступным с
  объяснением.

Данные читаются через `fs.read` конфига и `fs.exec` вызовом
`/usr/libexec/pejir-mwan-ctl status`; ACL-гранты добавляются в
`luci-app-perenio.json` (по образцу `pejir-sms-ctl`).

## 7. CLI

```
pejir-mwan-ctl status     # текущее состояние (для UI и CLI)
pejir-mwan-ctl enable     # включить и применить
pejir-mwan-ctl disable    # выключить и снять всё
pejir-mwan-ctl apply      # переприменить конфиг
pejir-mwan-ctl check      # однократная проверка каналов
```

## 8. Тесты

`tests/test-mwan.sh` с моками `ubus`, `ping`, `ip`, `nft`, `uclient-fetch`
(по образцу `tests/test-modem-mem.sh`). Проверки:

1. демон создаёт nft-таблицу и `ip rule` для режима `balance`;
2. режим `failover` ставит правило на активную таблицу;
3. режим `pbr` даёт `ip rule to <CIDR> lookup 200`;
4. при `up=down` у одного канала весь трафик уходит на второй;
5. при обоих `down` ничего не переключается;
6. `stop` снимает nft-таблицу, правила 100–999 и DNS-маршруты;
7. DNS-маршруты в `main` ставятся для DNS обоих каналов;
8. `enabled=0` → маршрутизация не меняется вообще.

Новый тест обязательно добавляется в `.github/workflows/build.yml`.

## 9. Серия патчей (релиз `.65`)

| Патч | Содержание |
|---|---|
| 0142 | пакет `pejir-mwan`: Makefile, демон, ctl, init, дефолтный конфиг |
| 0143 | LuCI: `perenio/mwan.js`, меню, ACL-гранты, русские переводы |

Правки репозитория (не патчи дерева OpenWrt): `build.sh`
(`CONFIG_PACKAGE_pejir-mwan=y`, `CONFIG_PACKAGE_ip-full=y`, проверка файлов
модуля в rootfs), `tests/test-mwan.sh` + подключение в
`.github/workflows/build.yml`, `VERSION`, `README.md`, `docs/CHANGELOG.md`.

Плюс `docs/CHANGELOG.md` и README (раздел про multi-WAN).

Правила серии: фиксы — новыми патчами поверх, номера не переиспользуются.
Формат патча — RFC2047 base64 (chunk 64), дата RFC2822 GMT, тема без
`[PATCH n/m]`; собирается `/workspace/mkpatchhdr.py <patch> <tree>`.

## 10. Порядок работ

1. дождаться и опубликовать `.64` (run `45750039094`), выложить ассеты,
   обновить README с размерами/sha256;
2. реализовать патчи 0142–0145 в дереве разработки (`/tmp/v112`);
3. проверить серию на чистом дереве: `git am --3way patches/*.patch`
   (exit 0) + `diff -r` = 0 + все `tests/*.sh` PASS;
4. запуш в `main` через `/workspace/push_via_api.py` с подробным описанием;
5. создать тег `v25.12.6-pejir01.65`, дождаться CI, выложить ассеты
   (`check_rel65.sh`, `zigbee_check.sh`, `.gbl`), обновить README;
6. проверка на устройстве: включение в каждом режиме, проверка баланса
   (счётчики пакетов по меткам), failover при выдёргивании WAN, работа DNS.

## 11. Критерии готовности

- модуль выключен по умолчанию и не меняет маршрутизацию;
- `pejir-mwan-ctl disable` возвращает систему к состоянию «как было»;
- в режиме `balance` счётчики nft показывают трафик в обоих каналах;
- при падении WAN весь новый трафик идёт в LTE, при возврате WAN — снова 50/50;
- DNS работает при любом состоянии каналов;
- тесты `tests/test-mwan.sh` проходят в CI;
- приведённые выше 8 проверок теста покрыты.
