# AmneziaWG (AWG) на PEJIR01

В образ включён **AmneziaWG 3.1** — форк WireGuard с обфускацией
(устойчив к DPI/блокировкам). Состав:

- `kmod-amneziawg` — модуль ядра (собран против **нашего** ядра 6.12.112,
  поэтому ставится без возражений, в отличие от чужих готовых сборок)
- `amneziawg-tools` — CLI `awg` (аналог `wg`)
- `luci-proto-amneziawg` — настройка туннелей в LuCI

## Настройка в LuCI

Сеть → Интерфейсы → Добавить → протокол **AWG**:
обычный набор WireGuard (приватный ключ, пиры) + параметры обфускации:

- `Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1..H4` — junk-пакеты и специальные
  заголовки (значения выдаёт сервер Amnezia; на клиенте должны совпадать 1-в-1)
- опционально `HeaderProtectionKey`, `RandomTrailers` (AWG 3.x)

## Проверка из консоли

```sh
awg show                    # интерфейсы и пиры
awg showconf awg0           # полная конфигурация
logread | grep -i awg       # ошибки модуля
```

## awg-manager (веб-панель управления пирами)

[hoaxisr/awg-manager](https://github.com/hoaxisr/awg-manager) — веб-интерфейс
управления туннелями AWG/sing-box (пиры, мониторинг, speedtest). Проект
ориентирован на Keenetic/**Entware** (ставится в `/opt`, порт 2222).

На нашем роутере он тоже работает — поверх **Entware на extroot**:

1. Настройте extroot (POSTINSTALL.md) и установите Entware в `/opt`
   (инсталлер Entware поддерживает mipsel/mipselsf).
2. `wget -qO- http://repo.hoaxisr.ru/install.sh | sh`
3. Панель: `http://192.168.1.1:2222`

Альтернатива без Entware: LuCI-конфигурация (см. выше) + `ubus`/`awg show`
для мониторинга.

## Источники пакетов

Пакеты взяты из [2Grey/awg-openwrt](https://github.com/2Grey/awg-openwrt)
(kmod 3.1.20260906, tools 3.1.20260812), модуль — upstream
[amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module).
