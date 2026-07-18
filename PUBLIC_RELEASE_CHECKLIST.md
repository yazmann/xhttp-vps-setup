# Публичный релиз

Репозиторий уже публичный. Этот список нужен перед первым GitHub Release и последующими выпусками.

## Текст для GitHub About

**Описание**

> Установщик 3x-ui: VLESS/XHTTP/REALITY Self-steal с сайтом-заглушкой.

**Topics**

`vpn`, `vless`, `xhttp`, `reality`, `3x-ui`, `ubuntu`, `warp`, `nginx`, `xray`

## Перед публикацией

- [x] Репозиторий переведён в Public.
- [x] Добавлена [GNU GPL v3](LICENSE): форки, доработки и самостоятельные сборки разрешены при распространении исходного кода и изменений под GPLv3.
- [ ] Проверить всю историю коммитов GitHub Secret Scanning и убедиться, что там нет реальных паролей, токенов, IP-адресов, доменов и ссылок подписок.
- [ ] Включить GitHub Secret Scanning и Push Protection.
- [ ] Включить Private vulnerability reporting — правила уже описаны в [SECURITY.md](SECURITY.md).
- [ ] Включить Discussions, если нужна поддержка пользователей; Issues оставить для ошибок.
- [ ] Защитить `main`: изменения только через Pull Request и обязательная проверка **Script checks**.
- [ ] Проверить README, THIRD_PARTY_NOTICES.md и PHOTO_ATTRIBUTION.md после последнего изменения скрипта.
- [ ] Убедиться, что в репозитории нет результатов установок: `xhttp-vps-result-*.txt`, `3xui-*-*.env`, логов и скриншотов с данными доступа.

## Что уже подготовлено

- README с кратким назначением, требованиями, запуском и ссылками на используемые проекты.
- THIRD_PARTY_NOTICES.md и PHOTO_ATTRIBUTION.md со сторонними компонентами и фото.
- SECURITY.md, CONTRIBUTING.md и шаблон безопасного отчёта об ошибке.
- Автоматическая проверка Bash и ShellCheck в GitHub Actions.
