# Часть 2 — Zigbee (HOMEd) и sing-box

`mosquitto` **уже вшит в образ** (mosquitto-nossl + клиент). `sing-box`
**не вшит**: пакет весит 50 МБ, из-за чего rootfs не помещался в UBI-том
устройства и обновление по «OTA» ломалось. Ставится одной командой из
официального фида (см. раздел 5). Фид HOMEd преднастроен
(`pejir-homed-feed`): ключ `/etc/apk/keys/homed.pem` и запись в
`repositories.d` создаются при первой загрузке — остаётся одна команда
установки. Ставить на extroot (см. [POSTINSTALL.sh](POSTINSTALL.sh)).

## 1. MQTT-брокер (уже установлен)

```sh
/etc/init.d/mosquitto enable && /etc/init.d/mosquitto start
# конфиг: /etc/mosquitto/mosquitto.conf (порт 1883, без TLS)
```

## 2. HOMEd (одна команда)

```sh
apk update
apk add homed-zigbee homed-automation homed-web
```

**Фид уже прописан в образе:** `pejir-homed-feed` кладёт ключ
`/etc/apk/keys/homed.pem` и uci-defaults `40-homed-feed`, который пишет
`/etc/apk/repositories.d/homed.list` вида
`https://apk.homed.dev/$(cat /etc/apk/arch)/packages.adb`.
На PEJIR01 `/etc/apk/arch` = `mipsel_24kc`, и в фиде **есть** сборка под нашу
архитектуру: `homed-zigbee-3.16.4.apk` (305 КБ), `homed-qt-5.15.4.9.apk`
(4 МБ — HOMEd везёт свой Qt), `homed-web` (829 КБ), `homed-automation` (120 КБ).
Ключ в образе побайтово совпадает с `apk.key` на сервере, поэтому проверка
подписи проходит.

**Внимание:** uci-defaults выполняется один раз и потом удаляется (whiteout).
Если overlay когда-то пересоздавался, а файл `homed.list` при этом не
появился, фид не зарегистрируется — тогда добавьте его руками:

```sh
echo "https://apk.homed.dev/$(cat /etc/apk/arch)/packages.adb" > /etc/apk/repositories.d/homed.list
```

Готовый скрипт установки (в релиз `.28` как ассет `zigbee-setup.sh`) делает
всё сразу: регистрирует фид, ставит пакеты, правит конфиг, включает сервис.

**Места хватает в NAND:** пакеты ~4,4 МБ в сжатом виде, развёрнутые — десятки
МБ; том `rootfs_data` — 83 МБ. На extroot выносить нужно только `sing-box`
(50 МБ), а не HOMEd.

## 3. Конфигурация HOMEd ZigBee (координатор EFR32 на umxtty1)

`/etc/homed/homed-zigbee.conf` — секция [zigbee]:

```ini
[zigbee]
adapter=ezsp
port=/dev/umxtty1
baudrate=115200
panid=
channel=11
reset=soft
write=false
```

**Конфиг из пакета по умолчанию рассчитан на Raspberry Pi** (`adapter=znp`,
`port=/dev/ttyUSB0`) — на PEJIR01 его надо заменить на `ezsp` + `/dev/umxtty1`,
иначе координатор не поднимется. Секция `[gpio]` остаётся с `-1`: прямого
доступа к GPIO EFR32 нет.

`port=/dev/umxtty1` — это EFR32: `uartmuxd` мультиплексирует `/dev/ttyS1` в
`umxtty0` (STM32/MCU), `umxtty1` (Zigbee) и `umxtty2` (Z-Wave).

**Рабочий конфиг PEJIR01 (из стоковой прошивки, лежит в overlay и переживает
OTA):**

```ini
[zigbee]
adapter=ezsp
port=/dev/umxtty1
baudrate=115200
panid=0xb7f7
channel=11
reset=soft
write=true
```

**Про `write=true`:** при `write=false` HOMEd не может перенастроить
координатор — если сетевой ключ в EFR32 не совпадает с заданным, он пишет
«Adapter configuration can't be changed, write protection enabled» и сеть не
поднимает (`ezsp.cpp`, ветка `startNetwork()`). С `write=true` HOMEd сам
заливает в адаптер PAN ID и сетевой ключ. На PEJIR01 `write=true` нужен.

**PAN ID менять нельзя:** `panid` и сетевой ключ привязывают уже спаренные
Zigbee-устройства — после смены они не переподключатся к сети. Поэтому
`zigbee-setup.sh` **не трогает** существующий `/etc/homed/homed-zigbee.conf`
(он и так переживает OTA вместе с overlay), а пишет свой только если конфига
нет. Перед установкой полезно снять факты с устройства:

```sh
cat /etc/homed/homed-zigbee.conf
```

`reset=soft` — обязательно: GPIO-сброс EFR32 на PEJIR01 идёт через STM32 и
прямому GPIO не доступен.

```sh
/etc/init.d/homed-zigbee enable && /etc/init.d/homed-zigbee start
logread -e homed
```

Панель HOMEd Web: `http://192.168.1.1:8080` (если ставили homed-web).

У HOMEd есть **своя страница в LuCI**: *Администрирование → HOMEd → ZigBee
Service Configuration* (пакет кладёт `menu.d/luci-app-homed-zigbee.json` и
`view/homed/zigbee.js`).

## 4. Если EFR32 без прошивки NCP / с заводской вендорской

Если координатор не стартует (EZSP-хендшейк не проходит), нужно прошить NCP:
- вендорная прошивка EFR32 из стока 9.0.4: файл `efm32-ota-0.17.5-200-jenkins.bin`
  (лежит в `/ota/` стоковой прошивки; сообщество в 4PDA #816 льёт её через
  `ncp.py` на `/dev/umxtty1`);
- либо universal-silabs-flasher (pip, python3 ставится на extroot):
  `pip3 install universal-silabs-flasher` →
  `universal-silabs-flasher --device /dev/umxtty1 flash --ezsp-firmware fw.gbl`.
- Проверить, что отвечает: `mcu getver` (STM32) и `hexdump -C /dev/umxtty1 | head`
  после `stty -F /dev/umxtty1 115200`.

## 5. sing-box (ставится отдельно)

```sh
apk update && apk add sing-box
# конфиг: /etc/sing-box/config.json
/etc/init.d/sing-box enable && /etc/init.d/sing-box start
```

Правила трафика — в LuCI (Сеть→Firewall) или через nftables вручную.
Пакет лежит в NAND (~50 МБ); при частых обновлениях его лучше перенести
на extroot (см. [POSTINSTALL.sh](POSTINSTALL.sh)).

## 6. LED-индикация (шпаргалка)

```sh
mcu getver            # версия STM32
mcu setbright 0..7    # яркость
mcu l 2=0,s10         # канал 2.4G: цвет/яркость (r,g,b,p,w,y,o,m)
mcu l 5=1,s10         # канал 5G
mcu l zb=...,i=...,sh=...,a=...   # zigbee, internet, shield, alarm
echo "#0on 1" > /dev/ttyS1        # реле/питание портов 1..7
```

Каналы и коды — из практики 4PDA #794/#816; штатная индикация работает через
демон `mcud` автоматически (Wi-Fi/WAN статусы).
