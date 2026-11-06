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
`patches/*.patch` (`git am`) → достаёт вендорские `mcu/mcud/stm32flash/idata_*`
из заводской 9.0.4 → подключает фиды → `make download` → `make -j$(nproc)`.

### Где взять вендорские бинари

`build.sh` пробует источники по порядку:

1. **локальный файл** `./pejir-9.0.4.swu` или путь в `STOCK_FW=...` —
   заводская прошивка с вашего же роутера;
2. **публичный S3 Perenio** (`ci/1487/...`) — если он ещё доступен;
3. **zip-ассет релиза** `pejir-vendor-blobs-9.0.4.zip`.

Контрольная сумма стоковой прошивки проверяется, и при несовпадении
выводится предупреждение (сборка продолжается). Если не сработал ни один
источник — понятная ошибка со списком вариантов, а не молчаливый сбой.

### Сборка на GitHub

Workflow `.github/workflows/build.yml` делает то же самое на `ubuntu-latest`:
собирает образ, **проверяет содержимое собранного rootfs** (наличие
`/etc/smsd.conf`, `luci-app-perenio`, `pejir-idata` и корректность парсера
MAC) и выкладывает образы артефактом; при пуше тега `v*` — прикрепляет их
к Release. Повторные сборки быстрые: `dl/`, `build_dir/`, `staging_dir/`
кэшируются.

## Что внутри патча

| Файл | Назначение |
|---|---|
| `target/linux/ramips/dts/mt7621_perenio_pejir01-34-BA.dts` | DTS: NAND (kernel0/1, ubi, idata), GPIO STM32 (boot0/boot1/reset), uartlite2/3, DSA lan1/lan2/wan |
| `target/linux/ramips/image/mt7621.mk` | Образы: `factory.bin` (двойной kernel-слот) + `sysupgrade.bin` |
| `.../base-files/etc/board.d/02_network` | MAC из MTD `idata` |
| `.../base-files/lib/upgrade/platform.sh` | NAND sysupgrade: ядро в оба слота `kernel0`/`kernel1`, rootfs в UBI |
| `target/linux/generic/hack-6.12/921-add-gosuncn-gm510-usb-id.patch` | USB ID `305a:1415` для LTE GM510 |
| `package/uartmuxd/` | UART-мультиплексор → `/dev/umxtty0-2` (GPLv3, bovops) |
| `package/perenio-mcu/` | Обёртка вендорных `mcu/mcud/stm32flash` (блоба не в репо) |

## Ручной путь

Всё то же самое из `build.sh` — по шагам; если `git am` конфликтует
(дерево ушло вперёд), применяйте изменения руками и правьте контекст.

## Настройка под себя

После `build.sh` дерево остаётся в `$HOME/openwrt-pejir01-build/openwrt` —
можно править `make menuconfig` и пересобирать `make -j$(nproc)`.
