# Vision / XHTTP VPS setup

Установка защищённого VLESS VPN на чистый Ubuntu VPS: TCP Vision или XHTTP с REALITY Self-steal.

## Что входит

- 3x-ui и Xray-core: самостоятельный сервер или удалённая нода.
- VLESS + REALITY на TCP/443 с выбором Vision или XHTTP.
- Nginx cover-site и сертификат Let's Encrypt.
- UFW, Fail2ban, BBR, key-only SSH и обновления безопасности.
- Подписки HAPP, INCY и Mihomo с правилами RoscomVPN.
- Опциональный Cloudflare WARP для российских ресурсов.
- Восстановление, удаление с архивом и профиль для снижения расхода памяти.

Требуются чистый Ubuntu 22.04+, root-доступ, SSH-ключ и домен с единственной A-записью на IPv4 VPS. AAAA-записи быть не должно.

> Не запускайте установщик поверх существующих 3x-ui, Nginx или настроенного UFW.

## Установка

Выполните от `root`:

```bash
set -euo pipefail
cd /root
readonly REV='v0.5.0'
base="https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/${REV}"
curl -fsSLO "$base"/{install-xhttp-vps.sh,finish-xhttp-vps.sh,optimize-xhttp-memory.sh,xhttp-vps-common.sh}
printf '%s\n' \
  'a57bae37db62f4cd8f61008ce1219caf37de6f91d1561a34476a97ff812313dd  install-xhttp-vps.sh' \
  '71cadfd1c5b487b33996958b8f1dfda525b16dcf491e3ffc72cd7b715d27564f  finish-xhttp-vps.sh' \
  '6001886a100e88218d7de950d8078f7d6c72af5e49d102d53ab4b588dbbbeff1  optimize-xhttp-memory.sh' \
  '5287fc164472f3310c30361bbd3e573d6c7efcd8cfb60e994d4c790026edc9c4  xhttp-vps-common.sh' \
  | sha256sum -c -
chmod 700 ./{install-xhttp-vps.sh,finish-xhttp-vps.sh,optimize-xhttp-memory.sh,xhttp-vps-common.sh}
./install-xhttp-vps.sh
```

## Команды

```bash
# Открыть меню и показать сохранённые настройки
sudo /root/install-xhttp-vps.sh

# Продолжить или восстановить установку
sudo /root/finish-xhttp-vps.sh

# Применить профиль снижения расхода памяти
sudo bash /root/optimize-xhttp-memory.sh
```

Удаление выполняется через пункт `3` меню установщика. Перед закрытием первой SSH-сессии обязательно проверьте вход выбранным администратором во втором терминале.

[Подробная документация](docs/DETAILS.md) · [Безопасность](SECURITY.md) · [История изменений](CHANGELOG.md) · [Лицензии компонентов](THIRD_PARTY_NOTICES.md)
