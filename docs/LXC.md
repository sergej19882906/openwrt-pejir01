# LXC-контейнеры на PEJIR01 — не поддерживаются

> **Статус: LXC убран из образа (патч 0049, начиная с релиза `.28`).**
> Документ остался, чтобы объяснить, почему пункта меню «LXC Container mgr»
> в веб-интерфейсе больше нет.

## Почему убрали

Две независимые причины, каждая достаточна сама по себе.

### 1. Нет готовых образов под нашу архитектуру

PEJIR01 — это MediaTek MT7621, **MIPS 32-bit little-endian** (`mipsel`; в ELF
готового образа `e_machine=8`, class 32-bit, endianness LE).

В официальном репозитории образов `images.linuxcontainers.org` есть сборки
только для пяти архитектур:

```
amd64  arm64  armhf  loong64  riscv64
```

Сборок под `mipsel` нет вообще — ни для Alpine, ни для Debian/Ubuntu.

LuCI определяет целевую архитектуру через `uname -m` и фильтрует по ней
индекс образов (`lxc_get_download_target()` в `ucode/controller/lxc.uc`).
Для `mipsel` фильтр оставляет пустой список, и страница выдаёт:

> There are no templates for your architecture available.
> Please select another containers URL.

Сменить «containers URL» не помогает: на зеркалах LXC образов под MIPS нет.

### 2. Не хватит места

Контроллер LuCI требует свободного места **≥100 000 КБ (~98 МБ)** одновременно
в каталоге контейнеров и в `/tmp`:

```ucode
let min_space = int(ctx.get('lxc', 'lxc', 'min_space')) || 100000;
let min_temp  = int(ctx.get('lxc', 'lxc', 'min_temp'))  || 100000;
```

У устройства 128 МБ RAM и 16 МБ NAND. Даже при переносе overlay на USB-флешку
через extroot контейнер с полноценной ОС туда не помещается, а `/tmp` — это
RAM.

## Что было в образе

- `lxc`, `lxc-auto`, `lxc-attach`, `lxc-create`, `lxc-templates`, `lxc-hooks`
- `rpcd-mod-lxc` — ubus-объект `lxc` для страницы LuCI
- `luci-app-lxc` — сама страница «LXC Container mgr»
- `kmod-veth` — сеть контейнеров
- `pejir-lxc-base` — монтирование cgroup2 + каталог `/srv/lxc`

Всё это занимало **~1.3 МБ** флеша (`liblxc.so.1.9.0` — 1.19 МБ плюс
`lxc-start`/`lxc-create`/`lxc-attach`/`lxc-console`). Теперь эти ~1.3 МБ
свободны.

## Если контейнер всё-таки нужен

Единственный архитектурно-независимый путь — локальный шаблон `busybox`
(берёт busybox с самого роутера) или `local` (свой tarball с ОС):

```sh
# вручную из SSH, если нужны именно эти пакеты:
apk add lxc lxc-templates lxc-hooks kmod-veth
mkdir -p /srv/lxc
lxc-create -n busybox -t busybox
lxc-start -n busybox
lxc-attach -n busybox
```

Ограничения, которые при этом остаются:

- контейнер не создаётся через веб-интерфейс — только из командной строки;
- LuCI-контроллер всё равно откажет по месту (`min_space`/`min_temp`);
- нужен extroot на флешке, и `/tmp` в RAM остаётся узким местом;
- полноценная ОС (Alpine/Debian) под `mipsel` не существует в готовом виде —
  собирать rootfs придётся самостоятельно.

Практически полезного сценария на этом устройстве нет, поэтому проще
освободить флеш и не показывать нерабочее меню.
