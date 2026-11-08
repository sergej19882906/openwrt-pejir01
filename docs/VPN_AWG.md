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

1. Настройте extroot ([POSTINSTALL.sh](POSTINSTALL.sh)) и установите Entware в `/opt`
   (инсталлер Entware поддерживает mipsel/mipselsf).
2. `wget -qO- http://repo.hoaxisr.ru/install.sh | sh`
3. Панель: `http://192.168.1.1:2222`

Альтернатива без Entware: LuCI-конфигурация (см. выше) + `ubus`/`awg show`
для мониторинга.

## Почему awg-manager не портируется «как есть»

[hoaxisr/awg-manager](https://github.com/hoaxisr/awg-manager) — менеджер
экосистемы Keenetic: управляет **NDMS-интерфейсами** (системные WireGuard
Keenetic), KeenDNS, Kill Switch и маршрутизацией через собственные
kernel-модули (`awg-proxy`, `awgm-relay`), собранные под ядра Keenetic
(4.9/5.10). Go-бэкенд кросс-компилируется в mipsel тривиально, но:

- слой NDMS-интерфейсов нужно переписывать на `awg`/ubus/uci/nftables;
- kernel-модули — отдельный проект портирования на 6.12;
- HydraRoute Neo — часть экосистемы Keenetic.

Вердикт: это форк-проект, а не адаптация. Для веб-управления **sing-box**
на OpenWrt правильный путь — встроенный `clash_api` + дашборд
[metacubexd](https://github.com/MetaCubeX/metacubexd) (GUI по подпискам,
прокси и правилам, аналогично awg-manager):

```json
"experimental": { "clash_api": { "external_ui": "/etc/sing-box/ui",
                                 "external_controller": "0.0.0.0:9090" } }
```

## Источники пакетов

Пакеты взяты из [2Grey/awg-openwrt](https://github.com/2Grey/awg-openwrt)
(kmod 3.1.20260906, tools 3.1.20260812), модуль — upstream
[amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module).
