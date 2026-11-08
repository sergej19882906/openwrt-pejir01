# Другие модемы (замена GM510)

В PEJIR01 стоит mPCIe-слот с USB-шиной — подойдёт большинство cat.4+ модемов
в этом форм-факторе. Образ несёт **универсальный стек драйверов**: QMI, MBIM,
ECM/NCM, RNDIS, Huawei-NCM + usb-modeswitch + AT-инструменты.

## Классы модемов и как поднимать

| Класс | Модемы | Драйвер (вшит) | Интерфейс в LuCI |
|---|---|---|---|
| ECM/NCM | GM510, EC25/EP06 в NCM, GM610 | `cdc-ether`/`cdc-ncm` | Сеть → Интерфейсы → DHCP на `usb0` (уже создано: `wan`/`wan6`) |
| QMI | EC25/EComm в QMI, EM7455, MC7421 | `kmod-usb-net-qmi-wwan` + `uqmi` | протокол **UQMI** (`/dev/cdc-wdm0`) |
| MBIM | EC25 в MBIM, SIM7600 MBIM | `kmod-usb-net-cdc-mbim` + `umbim` | протокол **MBIM** |
| RNDIS | GM610 (RNDIS-режим), телефоны по USB | `kmod-usb-net-rndis` | DHCP на `usb0` |
| Huawei-стиль | E3372 в NCM | `kmod-usb-net-huawei-cdc-ncm` | DHCP/NCM |
| Serial-only | старые 3G-стики | `option` (вшит), `sierrawireless` | PPP (`comgt`) |

`usb-modeswitch` вшит — модемы «флешечного» типа переключатся сами
(пакет `usb-modeswitch-data` в 25.12 отсутствует — правила в комплекте
основного пакета).

## Инструменты в образе

- `mdm-at "AT..."` — AT-команды с автопоиском порта (наш)
- `atinout` + **LuCI: Сервис → AT commands** — то же с веб-морды (modemfeed)
- **LuCI: Статус → Modem info** (`luci-app-modeminfo`) — сигнал, оператор, температура
- `pingcontrol` — watchdog LTE (перезвон при потере пинга; конфиг
  `/etc/config/pingcontrol`)

## Рецепты

### Quectel EC25 (QMI — самый гибкий)

1. Вставить, `lsusb` — видно `2c7c:0125`.
2. LuCI → Интерфейсы → Добавить → протокол **UQMI**,
   модем-узел `/dev/cdc-wdm0`, APN оператора.
3. AT-порт: `/dev/ttyUSB2` (обычно), `atinout "AT+CFUN=1,1" /dev/ttyUSB2`.

### EC25/EP06 в NCM (проще всего)

Ничего не настраивать: `wan` на `usb0` уже создан — DHCP поднимет.

### GM610 (Marvell, RNDIS)

Переключить модем в RNDIS (AT или его веб-конфиг) → `usb0` поднимется
в RNDIS, `wan` подхватит.

## Оговорки

- mPCIe-слот PEJIR01 — **USB 2.0**, потолок ~300-400 Мбит/с: cat.6+ модемы
  не раскроются.
- Питание: EC25/EP06 дают пики до 2 А — на аккумуляторе возможны просадки
  (следите за `mcu getvolt`).
- Вендорские RTL модема (GM510/GM610) — скорость/SMS могут отличаться;
  SMS-стек (smstools3) привязан к AT-порту — после смены модема
  перепроверьте `/etc/smsd.conf` (файл перегенерируется только при первом
  загрузке — правьте вручную или `rm /etc/uci-defaults/41-pejir-sms` +
  перезагрузка).

## Источник тулз

[modemfeed](https://github.com/koshev-msk/modemfeed) (koshev-msk, GPL) —
вендорены: `atinout`, `qminfo`, `pingcontrol`, `xmm-modem`,
`luci-app-atinout`, `luci-app-modeminfo`.

Из этого набора **в образе** собраны все шесть: `atinout`, `qminfo`,
`pingcontrol`, `xmm-modem`, `luci-app-atinout` и `luci-app-modeminfo`.

- `qminfo` (`/usr/bin/qminfo`) — подробная диагностика QMI-модема:
  оператор, сигнал, полосы, IMSI/ICCID. Тянет за собой `libqmi` и `glib2`.
- `xmm-modem` — протокол Fibocom L850/L860/FM350: скрипты `gcom` в
  `/etc/gcom/` и обработчик netifd `/lib/netifd/proto/xmm.sh`. Штатному
  модему PEJIR01 (GM510, Qualcomm) он не нужен — лежит на случай замены.
