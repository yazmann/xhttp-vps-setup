# XHTTP VPS setup

Автоматическая настройка чистого Ubuntu VPS для VPN.

- 3x-ui + VLESS / XHTTP / REALITY на TCP/443
- Nginx и сайт-заглушка
- Production Let's Encrypt TLS
- Подписки для HAPP, INCY и Mihomo с RoscomVPN Routing
- Опциональная маршрутизация `.ru` и `geoip:ru` через WARP
- UFW, BBR + fq и отключение IPv6
- Обновление Ubuntu и установленных пакетов перед настройкой
- Ежедневные обновления безопасности Ubuntu без автоматической перезагрузки

## Требования

- Чистый Ubuntu 22.04, 24.04 или новее
- Доступ `root` по SSH
- Домен с A-записью на IPv4 VPS
- Нет AAAA-записи
- В Cloudflare включён **DNS only**, без proxy
- Внешний firewall разрешает SSH, TCP/80 и TCP/443

> Установщик обновляет Ubuntu и меняет firewall. Не запускайте его на сервере с существующей 3x-ui.

Если VPS уже содержит 3x-ui, Nginx, активный UFW или предыдущую установку этого скрипта, установщик остановится до изменений и подскажет безопасное действие: восстановление, удаление управляемой установки или новый VPS.

Для VPS с предыдущей установкой этого скрипта выберите в меню пункт `4) Prepare VPS for a fresh installation`: он удалит только записанные скриптом компоненты и снова откроет меню установки.

## Установка

```bash
wget -O /root/install-xhttp-vps.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/install-xhttp-vps.sh
chmod 700 /root/install-xhttp-vps.sh
/root/install-xhttp-vps.sh
```

Выберите режим, TLS, введите домен и подтвердите установку. В standalone-режиме скрипт создаёт первого клиента и выводит готовые ссылки подписок.

## После установки

Итоговый экран содержит:

- URL панели 3x-ui, логин и пароль;
- подписку HAPP / INCY с правилами маршрутизации;
- отдельную подписку Mihomo;
- результат всех проверок.

Реквизиты также сохраняются в `/root/xhttp-vps-result-*.txt` с правами доступа только для root.

## Восстановление после сбоя

Если основной установщик дошёл до установки 3x-ui, но прервался во время настройки, загрузите и запустите:

```bash
wget -O /root/finish-xhttp-vps.sh https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/finish-xhttp-vps.sh
chmod 700 /root/finish-xhttp-vps.sh
/root/finish-xhttp-vps.sh
```

## Удаление

В меню установщика выберите `3) Remove every change made by this script`. Удаляются VPN, 3x-ui, Nginx-конфигурация, сертификаты, созданные правила UFW и записанные настройки. Обновления Ubuntu намеренно остаются — их откат ухудшил бы безопасность системы.

## Документация

- [Проверка на чистом VPS](TEST.md)
- [Проверка через Termius](TERMIUS_TESTING.md)
- [Сторонние компоненты](THIRD_PARTY_NOTICES.md)
