# XHTTP VPS setup

Установщик чистого Ubuntu VPS для VPN на базе [3x-ui](https://github.com/MHSanaei/3x-ui): VLESS + XHTTP + **REALITY Self-steal** и готовые подписки.

## Главное

- [VLESS + XHTTP/REALITY](https://github.com/XTLS/Xray-core) Self-steal на TCP/443.
- [NGINX](https://github.com/nginx/nginx) с сайтом-заглушкой на том же домене — для схемы Self-steal.
- TLS-сертификат [Let's Encrypt](https://letsencrypt.org/), firewall [UFW](https://launchpad.net/ufw), [BBR](https://www.kernel.org/doc/html/latest/networking/bbr.html), отключение IPv6 и ежедневные обновления безопасности.
- Подписки для [HAPP](https://github.com/Happ-proxy/happ-desktop), [INCY](https://incy.cc/) и [Mihomo](https://github.com/MetaCubeX/mihomo) с правилами маршрутизации [RoscomVPN](https://github.com/hydraponique/roscomvpn-routing).
- [Cloudflare WARP](https://www.cloudflare.com/warp/) для трафика с VPS к российским доменам и IP-адресам; включён по умолчанию, отключается ответом `no`.
- Самостоятельный VPN-сервер или удалённая нода для существующей панели.

## Требования

- Чистый Ubuntu 22.04+ и доступ `root` по SSH.
- Домен с A-записью на IPv4 VPS. AAAA-записи быть не должно.
- Любой DNS-провайдер.
- Если у провайдера есть внешний firewall, откройте SSH, TCP/80, TCP/443 и порт панели, который покажет установщик.

> Не запускайте скрипт на VPS, где уже установлены 3x-ui, Nginx или настроен UFW.

## Установка

Войдите на VPS как `root` и выполните:

```bash
cd /root && curl -fsSLo install-xhttp-vps.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/install-xhttp-vps.sh && curl -fsSLo finish-xhttp-vps.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/finish-xhttp-vps.sh && curl -fsSLo optimize-xhttp-memory.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/optimize-xhttp-memory.sh && chmod 700 install-xhttp-vps.sh finish-xhttp-vps.sh optimize-xhttp-memory.sh && ./install-xhttp-vps.sh
```

Команда скачивает актуальную версию из `main`. Стабильные версии после первого выпуска будут фиксироваться тегами и GitHub Releases.

Скрипт задаст необходимые вопросы. После успешной установки он покажет готовый блок с панелью и подписками либо с параметрами ноды. Те же данные сохраняются в защищённом файле `/root/xhttp-vps-result-*.txt`.

## Управление

Чтобы снова открыть меню установщика:

```bash
/root/install-xhttp-vps.sh
```

- Пункт `5` — показать текущие настройки; появляется после завершённой установки.
- Если установка прервалась: `/root/finish-xhttp-vps.sh`.

## Полное удаление

Перед удалением сохраните нужные данные. Для изменения расхода памяти переустановка не требуется — используйте процедуру ниже.

1. Запустите `/root/install-xhttp-vps.sh`.
2. Выберите пункт `3` и подтвердите удаление ответом `yes` или `y`.

Удаляются только компоненты и настройки, созданные этим скриптом: 3x-ui, управляемая конфигурация Nginx и сайта-заглушки, сертификаты, firewall-правила, swap (если его создал скрипт), результаты установки и записанные пакеты. Обновления безопасности Ubuntu сохраняются.

Пункт `4` удаляет управляемую установку и сразу запускает настройку заново.

## Профиль памяти 3x-ui / XHTTP

Новая установка и восстановление применяют этот профиль:

| Параметр | Значение | Где действует |
|---|---|---|
| `policy.levels.0.bufferSize` | `64` КиБ | Буфер внутренних pipe Xray уровня 0 |
| `policy.levels.0.connIdle` | `180` секунд | Простой проксируемой сессии уровня 0 |
| `xmux.maxConcurrency` | `"0"` | Отключает выбор пула по concurrency |
| `xmux.maxConnections` | `"1"` | Размер клиентского пула XMUX |
| `xmux.cMaxReuseTimes` | `"0"` | Без ограничения по этому счётчику |
| `xmux.hMaxRequestTimes` | `"300-600"` | Порог запросов для смены транспорта |
| `xmux.hMaxReusableSecs` | `"600-900"` | Окно повторного использования транспорта |
| `xmux.hKeepAlivePeriod` | `0` | Значение по умолчанию ядра |

Это снижение нагрузки на память, а не исправление доказанной утечки в Xray. `bufferSize` не выделяется целиком каждому TCP-сокету и не ограничивает всю память процесса; линейную экономию по числу ESTAB обещать нельзя. `connIdle` не закрывает простаивающий внешний HTTP/2 transport. `hMaxReusableSecs` проверяется при выборе транспорта; активные запросы могут пережить этот срок. `maxConnections=1` не является жёстким пределом общего числа сокетов при ротации.

XMUX хранится в inbound панели для передачи клиентам через подписку. Обновите подписки и переподключите клиентов; на ноде проверьте также профиль, выдаваемый главной панелью. Строковые значения сохраняют совместимость экспорта в Mihomo. Старые клиенты могут игнорировать эти поля. Остальные уровни policy не меняются.

Для уже работающего сервера, установленного этим проектом, скопируйте `optimize-xhttp-memory.sh` рядом с установленными скриптами и выполните:

```bash
sudo bash /root/optimize-xhttp-memory.sh
```

Скрипт читает локальный state-файл, обновляет только policy уровня 0 и XMUX inbound с тегом `in-443-xhttp-reality`, сохраняет клиентов, ключи, пути, лимиты и маршрутизацию. Перед записью создаётся закрытая папка `/root/xhttp-memory-backup.*` с online-копией SQLite и исходными JSON. При уже применённом профиле повторный запуск ничего не меняет. При изменении выполняется перезапуск Xray, текущие соединения могут оборваться. Не запускайте параллельно с редактированием панели.

Если сохранение частично завершилось, путь к резервной копии выводится в ошибке. Исходный `xray.json` можно вернуть через редактор Xray Configs, а `inbound.json` — через API update того же inbound. Восстановление полной БД делайте только при остановленном `x-ui`, сохранив текущее состояние и учитывая файлы WAL/SHM; это откат всех изменений панели после копии.

Сравните RSS, swap, FD, ESTAB и goroutine при сходной нагрузке до изменения, через 30 минут и через сутки. Снижение сразу после рестарта само по себе не доказывает устранение утечки. При тысячах внешних H2-соединений потребуется также обновление/исправление ядра или клиентского транспорта; регулярные рестарты и `MemoryMax` не заменяют диагностику.

## Используемые проекты

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [NGINX](https://github.com/nginx/nginx) · [Let's Encrypt](https://letsencrypt.org/) · [UFW](https://launchpad.net/ufw) · [BBR](https://www.kernel.org/doc/html/latest/networking/bbr.html) · [Cloudflare WARP](https://www.cloudflare.com/warp/) · [HAPP](https://github.com/Happ-proxy/happ-desktop) · [INCY](https://incy.cc/) · [Mihomo](https://github.com/MetaCubeX/mihomo) · [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing)

Сторонние компоненты и лицензии: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
