# Часть 2 — Zigbee (HOMEd) и sing-box — ПОСЛЕ extroot

Выполнять после того, как extroot применился (`df -h /overlay` = размер флешки).

## 1. MQTT-брокер

```sh
apk update
apk search mosquitto            # узнаём точное имя (обычно mosquitto-nossl)
apk add mosquitto-nossl || apk add mosquitto
/etc/init.d/mosquitto enable && /etc/init.d/mosquitto start
```

## 2. Репозиторий HOMEd (APK, для OpenWrt 25.12+)

```sh
wget -O /etc/apk/keys/homed.pem https://apk.homed.dev/apk.key
echo "https://apk.homed.dev/$(cat /etc/apk/arch)/packages.adb" > /etc/apk/repositories.d/homed.list
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

## 5. sing-box

```sh
apk update && apk add sing-box
# конфиг: /etc/sing-box/config.json
/etc/init.d/sing-box enable && /etc/init.d/sing-box start
```

sing-box ~15+ МБ — после extroot спокойно ставится на флешку.
Правила трафика — в LuCI (Сеть→Firewall) или через nftables вручную.

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
