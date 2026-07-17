# XHTTP VPS setup

Интерактивный установщик чистого Ubuntu VPS: [3x-ui](https://github.com/MHSanaei/3x-ui), VLESS + XHTTP + REALITY и готовые клиентские подписки.

## Что даёт сборка

- Один вход VLESS/XHTTP/REALITY на TCP/443.
- **Self-steal:** на 443 работает собственный нейтральный сайт-заглушка через Nginx; схема не использует чужие популярные SNI.
- Production TLS от Let's Encrypt, UFW, BBR + fq, отключение IPv6 и ежедневные обновления безопасности.
- Готовые подписки для HAPP, INCY и Mihomo с правилами [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing).
- Опциональный [Cloudflare WARP](https://www.cloudflare.com/warp/) для доменов `.ru` и `geoip:ru`; включён по умолчанию. На VPS с ~1 ГБ RAM при WARP автоматически добавляется swap 1 ГБ.
- Режимы standalone-сервера и удалённой ноды для существующей панели.

## Требования

- Чистый Ubuntu 22.04+ и доступ `root` по SSH.
- Домен с A-записью на IPv4 VPS, без AAAA-записи.
- Подходит любой DNS-провайдер. Если используется Cloudflare — включите **DNS only**.
- Во внешнем firewall должны быть доступны SSH, TCP/80, TCP/443 и показанный установщиком порт панели.

> Не запускайте на VPS с существующими 3x-ui, Nginx или активным UFW.

## Запуск

Репозиторий приватный: загрузите через GitHub Desktop **оба** файла в `/root` VPS — `install-xhttp-vps.sh` и `finish-xhttp-vps.sh`.

```bash
chmod 700 /root/install-xhttp-vps.sh /root/finish-xhttp-vps.sh
/root/install-xhttp-vps.sh
```

Установщик создаст панель, первого клиента (в standalone-режиме), подписки и защищённый файл с результатом: `/root/xhttp-vps-result-*.txt`.

## Управление

- Восстановление прерванной настройки: `/root/finish-xhttp-vps.sh`
- Удаление управляемой установки: пункт `3` в меню.
- Подготовка VPS для нового запуска: пункт `4` в меню.

## Используемые проекты

[3x-ui](https://github.com/MHSanaei/3x-ui) · [Xray-core](https://github.com/XTLS/Xray-core) · [NGINX](https://github.com/nginx/nginx) · [Cloudflare WARP](https://www.cloudflare.com/warp/) · [RoscomVPN Routing](https://github.com/hydraponique/roscomvpn-routing)

Подробности о сторонних компонентах и лицензиях: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
