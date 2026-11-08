# Perenio Elegance PEJIR01 — кастомная OpenWrt 25.12.6

Сборка: OpenWrt **v25.12.6** (ядро 6.12.112) + порт устройства + uartmuxd + perenio-mcu.

## Состав образа

| Компонент | Статус |
|---|---|
| Wi-Fi 2.4 (MT7603) / 5 ГГц (MT7612) | драйверы mt76, работает |
| LAN1/LAN2/WAN гигабит (DSA) | работает |
| USB 2.0/3.0, kmod-usb-storage(-uas), ext4, block-mount | для extroot |
| LTE-модем GM510/GM500 (ECM/NCM) | патч ядра `305a:1415` + cdc-ether/ncm |
| Кнопка Reset | работает |
| **uartmuxd** (bovops) | `ttyS1` → `/dev/umxtty0`(MCU), `umxtty1`(Zigbee), `umxtty2`(Z-Wave) |
| **perenio-mcu** (вендор 9.0.4) | LED-индикация STM32: демон `mcud` + CLI `mcu` |
| LuCI | веб-интерфейс |
| Zigbee | **не вшит**: ставится на USB (HOMEd, см. postinstall) |

## 0. БЭКАП (обязательно, до первой прошивки!)

На стоковой прошивке включите SSH (веб → расширенный вход `advanced`, инструкция в
[шапке 4PDA](https://4pda.to/forum/index.php?showtopic=1044575)) и снимите дампы:

```sh
mkdir -p /tmp/backup && cd /tmp/backup
for p in Bootloader Config Bdata factory crash crash_syslog reserved0 kernel0 kernel1 idata idata_old; do
  dd if=/dev/mtd$(cat /sys/class/mtd/ | grep -oP 'mtd\d+(?=.*\b'$p'\b)' | grep -oP '\d+' | head -1) of=/tmp/backup/$p.bin 2>/dev/null
done
# проще: найти индексы: cat /proc/mtd
# затем скачать всё по SCP на ПК: scp root@192.168.1.1:/tmp/backup/*.bin .
```

Минимально необходимы: `Bootloader`, `factory`, `Config`, `idata` — они позволят
восстановить MAC-адреса и заводские калибровки при откате.

## 1. Прошивка factory.bin через U-Boot

1. Выключите роутер.
2. Зажмите Reset, включите питание, держите ~5–7 сек до входа в загрузчик.
3. На ПК задайте статический IP `192.168.1.2`, маска `255.255.255.0`.
4. Откройте `http://192.168.1.1` — веб-интерфейс U-Boot.
5. Выберите файл `openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-factory.bin` и прошейте.
6. После прошивки: IP роутера `192.168.1.1`, LuCI: `http://192.168.1.1` (root, без пароля при первом входе).

Альтернатива sysupgrade (если уже стоит OpenWrt 21.02+/B1ackSn0w):
`sysupgrade openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-sysupgrade.bin` (Force, если ругнётся на совместимость: `sysupgrade -n` сбрасывает конфиг).

`sysupgrade` обновляет **и ядро, и rootfs**: ядро пишется в оба слота
`kernel0`/`kernel1` (активный слот выбирает U-Boot по переменной `imgidx`,
её значение скрипту неизвестно — поэтому пишем оба), rootfs уходит в UBI-раздел.
Переменные U-Boot при этом не меняются, так что неудачное обновление не
оставит устройство без загрузчика: останется старый kernel в активном слоте.

## 2. Recovery

- U-Boot веб-прошивка — основной способ, работающий всегда (кнопка Reset).
- Полный откат на сток: прошить бэкапы `kernel0`/`kernel1` и `ubi`-разделы через `mtd write` из OpenWrt, либо восстановить сток через U-Boot + стоковый `*.swu`.

### 2.1. Что происходит с калибровкой Wi-Fi

Калибровка радиомодулей (EEPROM MT7603/MT7612) живёт в разделе **`factory`**,
MAC-адреса — в `idata`. Прошивка их **не затрагивает**:

- `factory.bin` = только `kernel0`+`kernel1`+`ubi` — других адресов U-Boot
  не пишет;
- в DTS разделы `factory`/`Bdata`/`Config`/`idata` помечены `read-only`;
- `sysupgrade` обновляет kernel (оба слота) + ubi, оверлей — отдельно;
- MAC читается из `idata` (02_network), калибровка — из `factory` драйвером
  mt76 при старте.

Риск для калибровки — только ручные ошибки (`mtd write` не в тот раздел,
чужой образ, питание при записи). Страховка — бэкап из шага 0: с дампами
`factory`/`Config`/`idata` восстановимо всё, включая полный откат на сток.
Самый безопасный первый запуск — `initramfs-kernel.bin` по TFTP: NAND не
пишется вовсе.

## 3. Проверка железа после прошивки

```sh
# LED
service uartmuxd status && service mcud status   # umxtty0-2 должны появиться
ls -la /dev/umxtty*
mcu getver                                       # ответ STM32: OK vX.Y.Z ...
mcu setbright 5                                  # яркость LED 0..7
# Wi-Fi
iwinfo                                           # wlan0 2.4G + wlan1 5G? (или ra0/phy0-phy1)
# Модем (если SIM)
ip link                                          # usb0 (ECM) при подключённом модеме
# Zigbee-порт
ls -l /dev/umxtty1                               # канал EFR32
```

## 4. Дальше

- [docs/POSTINSTALL.sh](POSTINSTALL.sh) — скрипт для роутера: перенос overlay на
  USB-флешку (extroot). Дальше — по шагам, каждый со своей командой.
- HOMEd (Zigbee), mosquitto и sing-box — см. [docs/ZIGBEE_SINGBOX.md](ZIGBEE_SINGBOX.md).
- TTL для раздачи (если нужно): `advanced`-настройки стока не переносятся;
  на OpenWrt: iptables/nftables TTL mangle или `option` в конфиге.
