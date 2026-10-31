# OpenWrt 25.12 для Perenio Elegance (PEJIR01)

Порт **OpenWrt v25.12.6** (ядро 6.12) на мультфункциональный IoT-роутер
**Perenio Elegance / A1 Elegance (PEJIR01)** — MediaTek MT7621A, 256 МБ RAM,
128 МБ NAND, Wi-Fi 2.4+5 ГГц, гигабитные порты, LTE-модем, Zigbee.

> ⚠️ Порт сообщества. Гарантий нет: сначала бэкап, потом прошивка.
> Разделение прошивок A1/Perenio больше не требуется — один образ на оба бренда.

## Что работает

| Компонент | Статус |
|---|---|
| Wi-Fi 2.4 (MT7603) / 5 ГГц (MT7612) | ✅ kmod-mt7603 / kmod-mt76x2 |
| LAN1/LAN2/WAN гигабит (DSA) | ✅ MAC из MTD-раздела `idata` |
| USB 2.0/3.0, extroot | ✅ block-mount + ext4 в комплекте |
| LTE-модем GOSUNCN GM510 (ECM/NCM) | ✅ патч ядра `305a:1415` |
| Кнопка Reset | ✅ |
| **LED-индикация (STM32)** | ✅ вендорные `mcu`/`mcud` из стока 9.0.4 |
| **Zigbee (EFR32)** | ✅ через `uartmuxd` → `/dev/umxtty1`, координатор EZSP (HOMEd) — ставится на extroot |
| **LXC-контейнеры** | ✅ LXC 7.0 + cgroup2 + kmod-veth, `/srv/lxc` на extroot ([docs](docs/LXC.md)) |
| **AmneziaWG (AWG)** | ✅ kmod против нашего ядра + `awg` CLI + LuCI ([docs](docs/VPN_AWG.md)) |
| Батарея/питание | ✅ `mcu getvolt`/`getsys` + ubus-события; **значок АКБ в LuCI** (`luci-app-perenio`) ([docs](docs/STM32_BATTERY_SOUND.md)) |
| Звук (siren) | ⚠️ событие `mcud.mcu.siren` пробрасывается; ручной запуск — эксперимент ([docs](docs/STM32_BATTERY_SOUND.md)) |

## Скачать готовые образы

[Релиз v25.12.6-pejir01.1](https://github.com/sergej19882906/openwrt-pejir01/releases/latest) — прошивка, sysupgrade, initramfs (TFTP) + apk-пакеты:

- [`openwrt-...-squashfs-factory.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-factory.bin) — прошивка со стока (U-Boot)
- [`openwrt-...-squashfs-sysupgrade.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-sysupgrade.bin) — обновление с OpenWrt
- [`openwrt-...-initramfs-kernel.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-initramfs-kernel.bin) — тест по TFTP без записи NAND

## Как собрать

```sh
./build.sh          # всё: зависимости, OpenWrt v25.12.6, патчи, вендорные блобы, сборка
```

Подробности — [docs/BUILD.md](docs/BUILD.md). Вендорные бинарники (`mcu`, `mcud`,
`stm32flash`) **не распространяются в этом репозитории** — скрипт скачивает их из
официальной заводской прошивки 9.0.4 с публичного S3-бакета Perenio.

Готовые образы: `bin/targets/ramips/mt7621/openwrt-*-perenio_pejir01-34-BA-squashfs-{factory,sysupgrade}.bin`

## Как прошить

Кратко (полностью — [docs/FLASH.md](docs/FLASH.md)):

1. **Бэкап** NAND-разделов со стока (SSH → `dd` → SCP).
2. Зажать Reset, подать питание → веб-интерфейс U-Boot на `192.168.1.1`
   (ПК со статикой `192.168.1.2/24`).
3. Прошить `...squashfs-factory.bin`.

После прошивки: `192.168.1.1`, LuCI, root без пароля.

## Zigbee / HOMEd / sing-box

`docs/POSTINSTALL.md` — extroot на USB-флешку, `docs/ZIGBEE_SINGBOX.md` —
HOMEd (`adapter=ezsp`, `port=/dev/umxtty1`), mosquitto, sing-box.

## Благодарности

- **koshev-msk (sid)** — исходный порт на OpenWrt 21.02, DTS, [modemfeed](https://github.com/koshev-msk/modemfeed)
- **bovops** — [uartmuxd](https://github.com/bovops/uartmuxd) (GPLv3), userspace-замена `uartmux.ko`
- **B1ackSn0w, ziam** — сборки 24.10/25.12 и отладка STM32 на 4PDA
- **Perenio** — заводская прошивка на базе OpenWrt и вендорные утилиты
- Тема [4PDA: IoT Perenio Elegance / A1 Elegance](https://4pda.to/forum/index.php?showtopic=1044575)

## Лицензии

Код порта — GPL-2.0-or-later OR MIT (как upstream OpenWrt).
`uartmuxd` — GPL-3.0 (upstream bovops). Вендорные бинарники принадлежат Perenio
и не входят в репозиторий.
