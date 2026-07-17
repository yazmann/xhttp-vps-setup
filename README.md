# XHTTP VPS setup

Установщик чистого Ubuntu VPS для VPN на базе [3x-ui](https://github.com/MHSanaei/3x-ui): VLESS + XHTTP + REALITY и готовые подписки.

## Главное

- Один вход VLESS/XHTTP/REALITY на TCP/443.
- **Self-steal:** при обычном открытии домена на 443 отображается собственный сайт-заглушка. Для VPN используется тот же порт; чужие домены и SNI не нужны.
- Автоматически настраиваются TLS-сертификат Let's Encrypt, firewall UFW, BBR, отключение IPv6 и ежедневные обновления безопасности.
- Подписки для HAPP, INCY и Mihomo уже содержат правила [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing).
- WARP для трафика к доменам `.ru` включён по умолчанию; при установке его можно выключить ответом `no`. На VPS с 1 ГБ RAM вместе с WARP добавляется swap 1 ГБ.
- Можно установить самостоятельный сервер или удалённую ноду для существующей панели.

## Требования

- Чистый Ubuntu 22.04+ и доступ `root` по SSH.
- Домен с A-записью на IPv4 VPS. AAAA-записи быть не должно.
- Любой DNS-провайдер.
- Если у провайдера есть внешний firewall, откройте SSH, TCP/80, TCP/443 и порт панели, который покажет установщик.

> Не запускайте скрипт на VPS, где уже установлены 3x-ui, Nginx или настроен UFW.

## Установка

Репозиторий приватный: через GitHub Desktop загрузите на VPS в `/root` оба файла — `install-xhttp-vps.sh` и `finish-xhttp-vps.sh`.

```bash
chmod 700 /root/install-xhttp-vps.sh /root/finish-xhttp-vps.sh
/root/install-xhttp-vps.sh
```

После установки результат сохранится в файле `/root/xhttp-vps-result-*.txt`.

## Если нужно продолжить или удалить установку

- Продолжить прерванную настройку: `/root/finish-xhttp-vps.sh`
- Удалить установку: пункт `3` меню.
- Подготовить VPS к новой установке: пункт `4` меню.

## Используемые проекты

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [NGINX](https://github.com/nginx/nginx) · [Cloudflare WARP](https://www.cloudflare.com/warp/) · [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing)

Сторонние компоненты и лицензии: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
