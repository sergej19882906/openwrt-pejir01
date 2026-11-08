# LXC-контейнеры на PEJIR01

В образ включён стек **LXC 7.0** (тот же механизм, что вендор Perenio использует
для своих приложений в стоке — «LXC Execution Environment»). Контейнеры живут
на extroot (`/srv/lxc`), cgroup2 монтируется автоматически (init-скрипт
`cgroup2` из пакета `pejir-lxc-base`).

## Что в образе

- `lxc`, `lxc-auto`, `lxc-attach`, `lxc-create`, `lxc-templates`, `lxc-hooks`
- `kmod-veth` — сеть контейнеров
- `pejir-lxc-base` — монтирование cgroup2 + `/srv/lxc`

## Перед использованием

1. Настройте **extroot** (см. [POSTINSTALL.sh](POSTINSTALL.sh)) — NAND на 128 МБ для контейнеров мало.
2. Проверка:

```sh
mount | grep cgroup2         # cgroup2 смонтирован
lxc-create --version
ls /srv/lxc                  # хранилище контейнеров
```

## Создание контейнера (Alpine, самый лёгкий)

```sh
lxc-create -n alpine -t alpine
lxc-start -n alpine
lxc-attach -n alpine
lxc-stop -n alpine
```

Для остальных дистрибутивов (Debian/Ubuntu) — шаблон `download`:

```sh
lxc-create -n debian -t download -- --dist debian --release bookworm --arch armel
```

⚠️ 256 МБ RAM: лёгкие контейнеры (Alpine, mosquitto, мелкие сервисы) — да;
тяжёлые (Home Assistant) — нет, для этого берите внешний хост.

## Сеть контейнера

Классический вариант на OpenWrt — veth в бридж `br-lan`:

```sh
# /var/lib/lxc/alpine/config
lxc.net.0.type = veth
lxc.net.0.link = br-lan
lxc.net.0.flags = up
```

Контейнер получит адрес от DHCP роутера (или задайте статикой).

## Автостарт (lxc-auto, UCI)

```sh
uci add lxc-auto container
uci set lxc-auto.@container[-1].name='alpine'
uci commit lxc-auto
/etc/init.d/lxc-auto enable
```

## Отличие от стока Perenio

В стоке контейнеры управляются закрытым «LXC EE» (зашифрованные пакеты из
Developer Service, привязка к устройству). Здесь — стандартный открытый LXC:
полный контроль, любые образы, свои приложения.
