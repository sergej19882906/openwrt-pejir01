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

## 3. Конфигурация HOMEd ZigBee (координатор EFR32 на umxtty1)

`/etc/homed/homed-zigbee.conf` — секция [zigbee]:

```ini
[zigbee]
adapter=ezsp
port=/dev/umxtty1
baudrate=115200
reset=soft
write=false
```

`reset=soft` — обязательно: GPIO-сброс EFR32 на PEJIR01 идёт через STM32 и
прямому GPIO не доступен.

```sh
/etc/init.d/homed-zigbee enable && /etc/init.d/homed-zigbee start
logread -e homed
```

Панель HOMEd Web: `http://192.168.1.1:8080` (если ставили homed-web).

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
