# OpenWrt 25.12 для Perenio Elegance (PEJIR01)

Порт **OpenWrt v25.12.6** (ядро 6.12) на мультфункциональный IoT-роутер
**Perenio Elegance / A1 Elegance (PEJIR01)** — MediaTek MT7621A, 256 МБ RAM,
128 МБ NAND, Wi-Fi 2.4+5 ГГц, гигабитные порты, LTE-модем, Zigbee.

> ⚠️ Порт сообщества. Гарантий нет: сначала бэкап, потом прошивка.
> Разделение прошивок A1/Perenio больше не требуется — один образ на оба бренда.
> **Калибровка Wi-Fi и MAC не затрагиваются** (раздел `factory`/`idata` — read-only).

## Что работает

| Компонент | Статус |
|---|---|
| Wi-Fi 2.4 (MT7603) / 5 ГГц (MT7612) | ✅ kmod-mt7603 / kmod-mt76x2 |
| LAN1/LAN2/WAN гигабит (DSA) | ✅ MAC из MTD-раздела `idata` |
| USB 2.0/3.0, extroot | ✅ block-mount + ext4 в комплекте |
| **LTE-автостарт** | ✅ `lte`/`lte6` (DHCP/DHCPv6) на `usb0` создаются сами, metric 20 и в зоне `wan` (NAT работает) ([docs](docs/LTE_IPV6.md)) |
| LTE-модем GOSUNCN GM510 (ECM/NCM) | ✅ патч ядра `305a:1415` + `mdm-at` |
| **Другие модемы** | ✅ QMI/MBIM/RNDIS/Huawei-NCM/Sierra + AT-консоль и телеметрия в LuCI ([docs](docs/MODEMS.md)) |
| Кнопка Reset | ✅ |
| **LED-индикация (STM32)** | ✅ вендорные `mcu`/`mcud` из стока 9.0.4 |
| **Значок АКБ в LuCI** | ✅ `luci-app-perenio`: SVG-заряд из `mcu getvolt`, события `pwroff/pr/paerr` ([docs](docs/STM32_BATTERY_SOUND.md)) |
| Звук (siren) | ⚠️ событие `mcud.mcu.siren` пробрасывается; ручной запуск — эксперимент ([docs](docs/STM32_BATTERY_SOUND.md)) |
| **SMS** | ✅ smstools3 (автодетект AT-порта) + чтение в LuCI; отправка — файл в `/var/spool/sms/outgoing` |
| **Миграция со стока** | ✅ `pejir-idata`: SSID/пароли Wi-Fi, страна, пароль root — из заводского раздела `idata` при первой загрузке. Пароль ставится только если он ещё не задан, в лог идёт предупреждение «смените его» |
| **Обновление** | ✅ `sysupgrade` пишет **и ядро** (в оба слота `kernel0`/`kernel1`), и rootfs в UBI ([docs](docs/FLASH.md)) |
| **Zigbee (EFR32)** | ✅ `uartmuxd` → `/dev/umxtty1`, координатор EZSP (HOMEd) — ставится на extroot одной командой |
| **LXC-контейнеры** | ✅ LXC 7.0 + cgroup2 + kmod-veth, `/srv/lxc` на extroot ([docs](docs/LXC.md)) |
| **AmneziaWG (AWG)** | ✅ kmod против нашего ядра + `awg` CLI + LuCI ([docs](docs/VPN_AWG.md)) |
| mosquitto / sing-box | ✅ вшиты (sing-box выключен, конфиг вручную) ([docs](docs/ZIGBEE_SINGBOX.md)) |
| **Мониторинг и сеть** | ✅ mwan3 (failover Ethernet↔LTE), sqm (QoS), collectd+графики, nlbwmon, banip, vnstat2 — с LuCI |
| **Диагностика** | ✅ picocom, usbutils, iperf3, tcpdump, htop |
| **DynDNS** | ✅ ddns-scripts + LuCI (100+ провайдеров, IPv4/IPv6) — Сеть→Dynamic DNS |
| **Тема** | ✅ Cyberpunk (тёмная OLED/HUD) по умолчанию |

## Скачать готовые образы

[Последний релиз](https://github.com/sergej19882906/openwrt-pejir01/releases/latest) — образы, apk-пакеты, вендор-блобы:

- [`openwrt-...-squashfs-factory.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-factory.bin) — прошивка со стока (U-Boot)
- [`openwrt-...-squashfs-sysupgrade.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-sysupgrade.bin) — обновление с OpenWrt (ядро + rootfs)
- [`openwrt-...-initramfs-kernel.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-initramfs-kernel.bin) — тест по TFTP без записи NAND
- `pejir-vendor-blobs-9.0.4.zip` — вендорные бинари (используются build.sh как fallback)

## Как собрать

```sh
git clone https://github.com/sergej19882906/openwrt-pejir01.git
cd openwrt-pejir01 && bash build.sh
```

Вендорные бинарники (`mcu`, `mcud`, `stm32flash`, `idata_*`) **не входят в репозиторий** —
build.sh берёт их из официальной прошивки 9.0.4 (публичный S3 Perenio),
при недоступности — из zip-ассета релиза, а если нет и его — из локального
файла прошивки: положите `pejir-9.0.4.swu` рядом с `build.sh` или укажите
путь в `STOCK_FW=... ./build.sh`. Детали: [docs/BUILD.md](docs/BUILD.md).

Серия патчей: `patches/0001..0013` (`git am` на чистый v25.12.6).

### Сборка на GitHub

В репозитории есть workflow [`.github/workflows/build.yml`](.github/workflows/build.yml):
он собирает образ на `ubuntu-latest`, **проверяет содержимое собранного rootfs**
(что `/etc/smsd.conf`, `luci-app-perenio` и `pejir-idata` реально попали в образ)
и отдаёт образы артефактом. При пуше тега `v*` образы дополнительно
прикрепляются к Release.

```sh
# запустить вручную
gh workflow run build.yml
# или поставить тег — релиз соберётся сам
git tag v25.12.6-pejir01.7 && git push origin v25.12.6-pejir01.7
```

Сборка занимает несколько часов (лимит GitHub-hosted — 6 ч), но повторные
запуски быстрые: `dl/`, `build_dir/` и `staging_dir/` кэшируются.

## Как прошить

Кратко (полностью — [docs/FLASH.md](docs/FLASH.md)):

1. **Бэкап** NAND-разделов со стока (SSH → `dd` → SCP) — страховка от ручных ошибок.
2. Зажать Reset, подать питание → веб-интерфейс U-Boot на `192.168.1.1`
   (ПК со статикой `192.168.1.2/24`).
3. Прошить `...squashfs-factory.bin`.

После прошивки: `192.168.1.1`, LuCI (тема Cyberpunk).
Пароль root — из стокового `admin_pass` (миграция idata); на «чистом» железе — пустой, задайте сразу.

Калибровка Wi-Fi и MAC не затрагиваются: разделы `factory`/`idata` — read-only,
прошивается только kernel+ubi.

## Документация

| Файл | О чём |
|---|---|
| [docs/FLASH.md](docs/FLASH.md) | Бэкап, прошивка через U-Boot, recovery, калибровка |
| [docs/POSTINSTALL.md](docs/POSTINSTALL.md) | Extroot на USB-флешку |
| [docs/ZIGBEE_SINGBOX.md](docs/ZIGBEE_SINGBOX.md) | HOMEd (EZSP), mosquitto, sing-box, LED-шпаргалка |
| [docs/VPN_AWG.md](docs/VPN_AWG.md) | AmneziaWG, awg-manager (и почему он не портируется) |
| [docs/LXC.md](docs/LXC.md) | Контейнеры, сеть, автостарт |
| [docs/MODEMS.md](docs/MODEMS.md) | Замена GM510: EC25/GM610/Huawei — рецепты по классам |
| [docs/STM32_BATTERY_SOUND.md](docs/STM32_BATTERY_SOUND.md) | Батарея, питание, сирена, команды `mcu` |
| [docs/LTE_IPV6.md](docs/LTE_IPV6.md) | IPv6 через LTE (диагностика AT), проброс портов за CGNAT |
| [docs/BUILD.md](docs/BUILD.md) | Сборка, состав патчей |

## Благодарности

- **koshev-msk (sid)** — исходный порт на OpenWrt 21.02, DTS, [modemfeed](https://github.com/koshev-msk/modemfeed)
- **bovops** — [uartmuxd](https://github.com/bovops/uartmuxd) (GPLv3), userspace-замена `uartmux.ko`
- **B1ackSn0w, ziam** — сборки 24.10/25.12 и отладка STM32 на 4PDA
- **u236** — [HOMEd](https://github.com/u236/homed-service-zigbee) (Zigbee-стек)
- **HCLonely** — [luci-theme-cyberpunk](https://github.com/HCLonely/luci-theme-cyberpunk)
- **Perenio** — заводская прошивка на базе OpenWrt и вендорные утилиты
- Тема [4PDA: IoT Perenio Elegance / A1 Elegance](https://4pda.to/forum/index.php?showtopic=1044575)

## Лицензии

Код порта — GPL-2.0-or-later OR MIT (как upstream OpenWrt).
`uartmuxd` — GPL-3.0 (upstream bovops). HOMEd — GPL-3.0, тема Cyberpunk —
Apache-2.0. Вендорные бинарники принадлежат Perenio: в репозиторий не входят,
собираются из официальной 9.0.4 (или берутся из zip-ассета релиза как
немодифицированные копии).
