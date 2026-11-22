# OpenWrt 25.12 для Perenio Elegance (PEJIR01)

Порт **OpenWrt v25.12.6** (ядро 6.12.112) на мультфункциональный IoT-роутер
**Perenio Elegance / A1 Elegance (PEJIR01)** — MediaTek MT7621A, 256 МБ RAM,
128 МБ NAND, Wi-Fi 2.4+5 ГГц, гигабитные порты, LTE-модем, Zigbee.

> ⚠️ Порт сообщества. Гарантий нет: сначала бэкап, потом прошивка.
> Разделение прошивок A1/Perenio больше не требуется — один образ на оба бренда.
> **Калибровка Wi-Fi и MAC не затрагиваются** (раздел `factory`/`idata` — read-only).

**Актуальный релиз — `25.12.6-pejir01.34`**: тема **Argon** (остальные
темы — включая Cyberpunk — доступны в выпадающем списке), **настоящий
русский интерфейс LuCI** с переводами, **5 ГГц на втором радио**, правильное
имя интерфейса LTE-модема (`eth1`, а не `usb0`), сохранение настроек при
обновлении по воздуху, **extroot и swap с USB-флешки** и **рабочий LTE с
мобильным трафиком**.

В `.34` исправлено главное, что оставалось: **LTE поднимался, но трафика
не было**. Модем GM510 отвечает на AT только с символом конца строки CR: на
`AT\n` (только LF) он **не отвечает вовсе** — 6 минут проб дали тишину, — а
`mdm-at`, который шлёт `AT\r`, порт находил. Из-за этого `47-pejir-lte` не
находил порт, не ставил APN и не создавал PDP-контекст. Теперь проба
трёхступенчатая (`AT\r` → `AT+CSQ\r` → `AT+CSQ\n`), а `smsd` на время
AT-обмена отпускает порт — иначе он забирал ответы модема себе (патч 0059).

**Актуальный релиз — `25.12.6-pejir01.36`**: на странице **«SMS (Perenio)»**
теперь есть блок **«Исходящие SMS»** (в очереди на отправку, отправленные и
неотправленные — патч 0060) и блок **«USSD-запрос»** — можно узнать баланс
и остаток пакета прямо в браузере (`AT+CUSD`, патч 0061). Раньше страница
показывала только входящие, а страница диагностики вместо вывода показывала
«[object Object]» (исправлено в патче 0062).

Сборка `.34`: run `45032740390`, релиз `454539117`, sysupgrade 17 541 688 Б
(sha256 `0398e9c5802d7f763b78ce6d248b349677b9d1da8576d42d45c05b7021f6ea2f`),
factory 23 855 104 Б, initramfs 16 857 786 Б, rootfs 14 058 496 Б
(том `rootfs` на устройстве — 23 998 464 Б).

Сборка `.33`: run `45020303294`, релиз `454440700`, sysupgrade 17 531 448 Б
(sha256 `e661fe0c873488eafc6644f8d0acd87aa278f32df85a78d99c724868ac8453bf`),
factory 23 855 104 Б, initramfs 16 858 241 Б, rootfs 14 057 472 Б
(том `rootfs` на устройстве — 23 998 464 Б).

Сборка `.32`: run `45008024707`, релиз `454360496`, sysupgrade 18 494 008 Б
(sha256 `b2e35837cb08fdd775338174297f30a8ba0cf967f37983e0a5307d069fca058e`),
factory 24 903 680 Б, initramfs 17 764 386 Б, rootfs 15 013 888 Б.

В `.33` исправлено ожидание модема: AT-порт GM510 оживает через минуту-две
после перечисления USB, а скрипты делали **ровно одну** попытку и сдавались —
из-за этого LTE не поднимался, а `/etc/smsd.conf` оставался стоковым.
Теперь модем опрашивается **до 15 минут**, а интерфейс LTE настраивается
даже если модем не отвечает на AT.

В `.33` **ModemManager удалён из образа** (патч 0058). Он сам находит
AT-порт модема и забирает его себе, а LTE и SMS у нас ведут собственные
скрипты через тот же `/dev/ttyUSB2` — одновременно работать они не могут.
Модули ядра для USB-модемов (`option`, `cdc-mbim`, `qmi-wwan`, `uqmi`,
`umbim`) остались. **Страница LuCI «Модем» пропала** — она была частью
ModemManager; LTE/SMS работают как и раньше, через собственные скрипты.

В `.33` исправлен **extroot и swap**: `pejir-extroot` писал служебные
сообщения прямо в `/etc/config/fstab`, и fstab переставал парситься
(`Parse error at line 20`) — вместе с секцией extroot и секцией swap.
Из-за этого overlay оставался на внутренней NAND-памяти, swap не
включался, а настройки с флешки не подхватывались (патч 0057).

В `.32` исправлено то, что ломало связку «модем → LTE и SMS» на устройстве:
**AT-порт теперь находится при загрузке** (раньше ожидание модема
заканчивалось за 30 секунд, а модем перечислялся позже — из-за этого
`/etc/smsd.conf` оставался стоковым, `smsd` не запускался, и LTE не
поднимался без ручного вмешательства), а поиск порта **продолжается в
фоне**, если модем ещё не готов. В образ добавлен **ModemManager** с
страницей LuCI «Модем» (в `.33` удалён — см. выше). В маркере версии
`/usr/lib/pejir/version` теперь стоит реальный номер релиза.

В `.28` исправлены вещи, которые были сломаны и раньше, но мешали
пользоваться устройством: **страницы порта больше не отдают «Permission
denied»** (в ACL LuCI 25.12 не хватало раздела `file` — подробности в
`docs/CHANGELOG.md`), **smsd запускается** с правильным портом модема
(`ttyUSB2`), **добавлен ECM data call** `AT+ZECMCALL=1`, а `mcud` при
неудачном старте пишет причину в журнал, а не выходит молча.

**Язык интерфейса** — русский по умолчанию, английский переключается
на **System → Administration → Language** (там же `auto`). Переводы
есть и у штатных страниц LuCI, и у страниц порта: их исходные строки
английские, русские — в `*.ru.lmo`.

**Overlay можно перенести на USB-флешку** (extroot): `pejir-extroot`
покажет состояние, `pejir-extroot setup` подготовит флешку (ext4) и
запишет конфигурацию, после `reboot` настройки хранятся на флешке, а не
в NAND.

В предыдущем релизе `.26` было главное — **само обновление прошивки по
воздуху**: rootfs пишется в существующий UBI-том, `rootfs_data` (overlay с
настройками) не стирается.
В `.26` из образа убран `sing-box` (50 МБ) — rootfs стал 14 МБ и влезает в
существующий UBI-том, поэтому обновление больше не стирает настройки
(Wi-Fi, LTE, пароли). Ставится отдельно: `apk add sing-box`.
В `.24` DTB приведён к реальному железу: `kernel0` больше не `read-only`
(иначе ядро не записывалось при обновлении), кнопка на плане — это WPS,
а не reset; `i2c` и третий UART выключены, как в заводском DTB.
Полный список изменений — [docs/CHANGELOG.md](docs/CHANGELOG.md).
Обновляться можно сразу с `.12` на `.25`.

## Что работает

| Компонент | Статус |
|---|---|
| Wi-Fi 2.4 (MT7603) / 5 ГГц (MT7612) | ✅ kmod-mt7603 / kmod-mt76x2; настройка радио — **Сеть → Беспроводная связь** (не «Сеть → Интерфейсы») |
| LAN1/LAN2/WAN гигабит (DSA) | ✅ MAC из MTD-раздела `idata` |
| USB 2.0/3.0, extroot | ✅ block-mount + ext4 в комплекте; хост-контроллер `xhci` в dtsi включён по умолчанию, патч 0015 лишь фиксит `status = "okay"` явно; патч 0026 делает питание xHCI необязательным (иначе DTB загрузчика без `vbus-supply` убивал контроллер целиком) |
| **LTE-автостарт** | ✅ `lte`/`lte6` (DHCP/DHCPv6) создаются при каждом старте (init-скрипт `47-pejir-lte`), metric 30 и в зоне `wan` (NAT работает). Имя интерфейса модема **определяется в runtime** (на этой плате — `eth1`, а не `usb0`: ядро 6.12 переименовывает CDC-Ethernet в `eth%d`) ([docs](docs/LTE_IPV6.md)) |
| LTE-модем GOSUNCN GM510 (ECM/NCM) | ✅ патч ядра `305a:1415` + `mdm-at`; раздел «Модем» (luci-app-modeminfo) настроен на AT-порт GM510 |
| **Другие модемы** | ✅ QMI/MBIM/RNDIS/Huawei-NCM/Sierra + AT-консоль и телеметрия в LuCI ([docs](docs/MODEMS.md)) |
| Кнопка Reset | ✅ |
| **LED-индикация (STM32)** | ✅ вендорные `mcu`/`mcud` из стока 9.0.4 |
| **Значок АКБ в LuCI** | ✅ `luci-app-perenio`: SVG-заряд из `mcu getvolt`, события `pwroff/pr/paerr` ([docs](docs/STM32_BATTERY_SOUND.md)) |
| **Заводские данные** | ✅ страница «Заводские данные (Perenio)»: штатные SSID/пароли Wi-Fi, пароль root, WPS PIN и серийный номер из раздела `idata` |
| Звук (siren) | ⚠️ событие `mcud.mcu.siren` пробрасывается; ручной запуск — эксперимент ([docs](docs/STM32_BATTERY_SOUND.md)) |
| **SMS** | ✅ страница «SMS (Perenio)» всегда видна: состояние smsd, AT-порты, журнал, входящие, отправка через `sendsms`; конфиг `smsd.conf` готовится при каждой загрузке ([changelog](docs/CHANGELOG.md)) |
| **Миграция со стока** | ✅ `pejir-idata`: SSID/пароли Wi-Fi, страна, пароль root — из заводского раздела `idata` при первой загрузке. Пароль ставится только если он ещё не задан, в лог идёт предупреждение «смените его» |
| **Обновление** | ✅ `sysupgrade` пишет **и ядро** (в оба слота `kernel0`/`kernel1`), и rootfs в UBI ([docs](docs/FLASH.md)) |
| **Автонастройка** | ✅ после прошивки extroot (overlay на флешку, swap с неё) и Zigbee HOMEd настраиваются сами, если ещё не настроены ([docs](docs/ZIGBEE_SINGBOX.md)) |
| **OTA по кнопке** | ✅ Система → Обновление прошивки (PEJIR01): проверка релиза на GitHub, сверка sha256, `sysupgrade --test` и прошивка. Автообновления нет — только по нажатию ([docs](docs/OTA.md)) |
| **Zigbee (EFR32)** | ✅ `uartmuxd` → `/dev/umxtty1`, координатор EZSP (HOMEd) — ставится на extroot одной командой |
| **LXC-контейнеры** | ❌ убраны: в официальном репозитории образов (`images.linuxcontainers.org`) есть только amd64/arm64/armhf/loong64/riscv64, а PEJIR01 — MIPS 32-bit (mipsel). Плюс LuCI требует ~98 МБ свободного места, а здесь 128 МБ RAM и 16 МБ NAND ([docs](docs/LXC.md)) |
| **AmneziaWG (AWG)** | ✅ kmod против нашего ядра + `awg` CLI + LuCI ([docs](docs/VPN_AWG.md)) |
| mosquitto / sing-box | ✅ mosquitto вшит; sing-box убран из образа (экономит 50 МБ) — ставится из официального фида: `apk add sing-box` ([docs](docs/ZIGBEE_SINGBOX.md)) |
| **Мониторинг и сеть** | ✅ mwan3 (failover Ethernet↔LTE), sqm (QoS), collectd+графики, nlbwmon, banip, vnstat2 — с LuCI |
| **Язык интерфейса** | ✅ русский по умолчанию: переводы LuCI для всех установленных приложений + собственные страницы порта (в `.27` исправлен переключатель — переводы действительно попадают в образ) |
| **Диагностика** | ✅ picocom, usbutils, iperf3, tcpdump, htop |
| **DynDNS** | ✅ ddns-scripts + LuCI (100+ провайдеров, IPv4/IPv6) — Сеть→Dynamic DNS |
| **Тема** | ✅ Cyberpunk (тёмная OLED/HUD) по умолчанию |

## Скачать готовые образы

[Последний релиз](https://github.com/sergej19882906/openwrt-pejir01/releases/latest) — образы, apk-пакеты, вендор-блобы:

- [`openwrt-...-squashfs-factory.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-factory.bin) — прошивка со стока (U-Boot)
- [`openwrt-...-squashfs-sysupgrade.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-squashfs-sysupgrade.bin) — обновление с OpenWrt (ядро + rootfs)
- [`openwrt-...-initramfs-kernel.bin`](https://github.com/sergej19882906/openwrt-pejir01/releases/latest/download/openwrt-ramips-mt7621-perenio_pejir01-34-BA-initramfs-kernel.bin) — тест по TFTP без записи NAND
- `pejir-vendor-blobs-9.0.4.zip` — вендорные бинари (используются build.sh как fallback)

### Как появляется релиз

Релиз создаёт workflow `Build` — но только при пуше тега вида `v*`:

1. тег `v<версия>` указывает на нужный коммит `main`;
2. workflow собирает образы и прикрепляет их к релизу с этим тегом
   (`factory.bin`, `sysupgrade.bin`, `initramfs-kernel.bin`, `sha256sums`).

Тег можно поставить через веб-интерфейс GitHub: **Releases → Create new release →
«Create new tag on: main»**. Сборка занимает около часа, кэш сборки переиспользуется.

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

Серия патчей: `patches/0001..0030` (`git am` на чистый v25.12.6).

### Сборка на GitHub

В репозитории есть workflow [`.github/workflows/build.yml`](.github/workflows/build.yml):
он собирает образ на `ubuntu-latest`, **проверяет содержимое собранного rootfs**
(что OTA-модуль, `luci-app-perenio`, `pejir-idata`, вендорные `mcu`/`mcud` и
symlink'и `libubox`/`libubus` реально попали в образ — иначе сборка падает)
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

После прошивки: `192.168.1.1`, LuCI (тема Argon; остальные — в выпадающем списке).
Пароль root — из стокового `admin_pass` (миграция idata); на «чистом» железе — пустой, задайте сразу.

Калибровка Wi-Fi и MAC не затрагиваются: разделы `factory`/`idata` — read-only,
прошивается только kernel+ubi.

> ⚠️ **При обновлении через LuCI всегда ставьте галочку «Сохранить настройки
> и текущую конфигурацию».** Без неё overlay очищается, и теряются Wi-Fi,
> WAN/LTE и — главное — fstab extroot: флешка перестаёт монтироваться, а
> путь к `/overlay` приходится создавать заново. Настройки стоковой прошивки
> (SSID, пароли, MAC) восстанавливаются из раздела `idata` автоматически,
> но всё, что настроено руками, — нет.

## Документация

| Файл | О чём |
|---|---|
| [docs/FLASH.md](docs/FLASH.md) | Бэкап, прошивка через U-Boot, recovery, калибровка |
| [docs/OTA.md](docs/OTA.md) | Обновление прошивки кнопкой в LuCI (без автообновления) |
| [docs/POSTINSTALL.sh](docs/POSTINSTALL.sh) | Скрипт для роутера: extroot на USB-флешку |
| [docs/ZIGBEE_SINGBOX.md](docs/ZIGBEE_SINGBOX.md) | HOMEd (EZSP), mosquitto, sing-box, LED-шпаргалка |
| [docs/VPN_AWG.md](docs/VPN_AWG.md) | AmneziaWG, awg-manager (и почему он не портируется) |
| [docs/LXC.md](docs/LXC.md) | Контейнеры, сеть, автостарт |
| [docs/MODEMS.md](docs/MODEMS.md) | Замена GM510: EC25/GM610/Huawei — рецепты по классам |
| [docs/STM32_BATTERY_SOUND.md](docs/STM32_BATTERY_SOUND.md) | Батарея, питание, сирена, команды `mcu` |
| [docs/LTE_IPV6.md](docs/LTE_IPV6.md) | IPv6 через LTE (диагностика AT), проброс портов за CGNAT |
| [docs/BUILD.md](docs/BUILD.md) | Сборка, состав патчей |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Что изменилось в каждом релизе (`.19` — модемные утилиты, `.18` — язык, `.17` — все правки с `.12`) |

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
`uartmuxd` — GPL-3.0 (upstream bovops). HOMEd — GPL-3.0, темы Cyberpunk и
Argon — Apache-2.0. Вендорные бинарники принадлежат Perenio: в репозиторий не входят,
собираются из официальной 9.0.4 (или берутся из zip-ассета релиза как
немодифицированные копии).
