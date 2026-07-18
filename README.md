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
cd /root && curl -fsSLo install-xhttp-vps.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/install-xhttp-vps.sh && curl -fsSLo finish-xhttp-vps.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/finish-xhttp-vps.sh && chmod 700 install-xhttp-vps.sh finish-xhttp-vps.sh && ./install-xhttp-vps.sh
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

1. Запустите `/root/install-xhttp-vps.sh`.
2. Выберите пункт `3` и подтвердите удаление ответом `yes` или `y`.

Удаляются только компоненты и настройки, созданные этим скриптом: 3x-ui, управляемая конфигурация Nginx и сайта-заглушки, сертификаты, firewall-правила, swap (если его создал скрипт), результаты установки и записанные пакеты. Обновления безопасности Ubuntu сохраняются.

Пункт `4` удаляет управляемую установку и сразу запускает настройку заново.

## Используемые проекты

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [NGINX](https://github.com/nginx/nginx) · [Let's Encrypt](https://letsencrypt.org/) · [UFW](https://launchpad.net/ufw) · [BBR](https://www.kernel.org/doc/html/latest/networking/bbr.html) · [Cloudflare WARP](https://www.cloudflare.com/warp/) · [HAPP](https://github.com/Happ-proxy/happ-desktop) · [INCY](https://incy.cc/) · [Mihomo](https://github.com/MetaCubeX/mihomo) · [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing)

Сторонние компоненты и лицензии: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
