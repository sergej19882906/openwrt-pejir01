# Сборка

## Требования

- Debian/Ubuntu x86_64 (в Windows — WSL2), ~30 ГБ свободного места, 8+ ГБ RAM
- Root/ sudo для установки зависимостей; сборка от root требует
  `FORCE_UNSAFE_CONFIGURE=1` (build.sh выставляет сам)

## Быстрый путь

```sh
git clone https://github.com/sergej19882906/openwrt-pejir01.git
cd openwrt-pejir01
./build.sh
```

Скрипт: ставит зависимости → клонирует OpenWrt `v25.12.6` → применяет
`patches/*.patch` (`git am`) → скачивает вендорные `mcu/mcud/stm32flash` из
заводской 9.0.4 (публичный S3 Perenio) → подключает фиды → `make download` →
`make -j$(nproc)`.

## Что внутри патча

| Файл | Назначение |
|---|---|
| `target/linux/ramips/dts/mt7621_perenio_pejir01-34-BA.dts` | DTS: NAND (kernel0/1, ubi, idata), GPIO STM32 (boot0/boot1/reset), uartlite2/3, DSA lan1/lan2/wan |
| `target/linux/ramips/image/mt7621.mk` | Образы: `factory.bin` (двойной kernel-слот) + `sysupgrade.bin` |
| `.../base-files/etc/board.d/02_network` | MAC из MTD `idata` |
| `.../base-files/lib/upgrade/platform.sh` | NAND sysupgrade |
| `target/linux/generic/hack-6.12/921-add-gosuncn-gm510-usb-id.patch` | USB ID `305a:1415` для LTE GM510 |
| `package/uartmuxd/` | UART-мультиплексор → `/dev/umxtty0-2` (GPLv3, bovops) |
| `package/perenio-mcu/` | Обёртка вендорных `mcu/mcud/stm32flash` (блоба не в репо) |

## Ручной путь

Всё то же самое из `build.sh` — по шагам; если `git am` конфликтует
(дерево ушло вперёд), применяйте изменения руками и правьте контекст.

## Настройка под себя

После `build.sh` дерево остаётся в `$HOME/openwrt-pejir01-build/openwrt` —
можно править `make menuconfig` и пересобирать `make -j$(nproc)`.
