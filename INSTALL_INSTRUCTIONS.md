# telemt-deploy: подробная инструкция

Эта инструкция описывает установку, проверку, обслуживание и удаление проекта `telemt-deploy`.

`telemt-deploy` автоматически разворачивает MTProxy-стек:

- `telemt` на порту `443`
- `nginx` self-mask на `127.0.0.1:8444`
- Let's Encrypt SSL-сертификат
- MEKO SYN FIX через `iptables`
- UFW-правила для портов `80` и `443`

## 1. Требования

Сервер:

- Ubuntu `22.04` или `24.04`
- root-доступ или пользователь с `sudo`
- публичный IPv4-адрес
- свободные порты `80` и `443`
- домен с `A`-записью на IP сервера

Локально перед установкой проверьте DNS:

```bash
dig +short A example.com
curl -fsS --max-time 10 ifconfig.me
```

IP из DNS должен совпадать с публичным IP сервера.

## 2. Распаковка архива

Скопируйте архив на сервер, например в `/root`, и распакуйте:

```bash
cd /root
tar -xzf telemt-deploy-2026-07-15.tar.gz
cd telemt-deploy
```

Проверьте, что основные файлы на месте:

```bash
ls install.sh lib templates tests
```

## 3. Безопасная проверка перед установкой

Эти команды не выполняют установку и не меняют `apt`, `nginx`, `systemd`, `ufw`, `iptables` или `certbot`:

```bash
bash tests/smoke.sh
bash install.sh --help
```

Ожидаемый результат smoke-проверки:

```text
ALL SYNTAX OK
```

## 4. Интерактивная установка

Запустите установщик без флагов:

```bash
sudo bash install.sh
```

Откроется меню:

- `1` - установка / переустановка
- `2` - статистика
- `3` - live-мониторинг
- `4` - сервисы
- `5` - настройки прокси и `ad_tag`
- `6` - SSL
- `7` - MEKO SYN FIX
- `8` - Firewall
- `9` - проверки
- `10` - обновить telemt
- `11` - удалить стек
- `0` - выход

Для первой установки выберите пункт `1`, укажите домен и подтвердите запуск.

## 5. Автоматическая установка через CLI

Минимальный вариант:

```bash
sudo bash install.sh --domain example.com --yes
```

С `ad_tag` от `@MTProxybot`:

```bash
sudo bash install.sh --domain example.com --ad-tag 13ea0123456789abcdef0123456789ab --yes
```

С конкретной версией `telemt`:

```bash
sudo bash install.sh --domain example.com --telemt-version 3.4.23 --yes
```

Полный MEKO Launcher вместо inline SYN FIX:

```bash
sudo bash install.sh --domain example.com --meko-full --yes
```

## 6. Что делает установка

Установщик выполняет шаги:

1. Ставит системные пакеты: `nginx`, `certbot`, `iptables`, `ufw`, `jq`, `dialog` и другие.
2. Настраивает временный `nginx` для ACME challenge.
3. Получает SSL-сертификат Let's Encrypt.
4. Настраивает production `nginx` self-mask на `127.0.0.1:8444`.
5. Скачивает и устанавливает `telemt`.
6. Генерирует или переиспользует секрет MTProxy.
7. Устанавливает systemd-сервис `telemt`.
8. Устанавливает MEKO SYN FIX.
9. Открывает `80/tcp` и `443/tcp` в UFW.
10. Запускает проверки и показывает данные для `@MTProxybot`.

## 7. Данные для @MTProxybot

После установки скрипт покажет:

- сервер: `example.com:443`
- секрет
- ссылку MTProxy, если API `telemt` уже доступен

В `@MTProxybot` используйте:

1. `/newproxy`
2. Отправьте сервер и секрет.
3. Через `/myproxies` настройте promotion и публичный канал.
4. Полученный `ad_tag` можно внести в меню через пункт `5` или при следующем CLI-запуске через `--ad-tag`.

## 8. Проверка после установки

Статус через установщик:

```bash
sudo bash install.sh --status
```

или:

```bash
sudo bash status.sh
```

Ручная диагностика:

```bash
systemctl is-active telemt nginx mtpr-synfix
ss -tlnp | grep ':443 '
curl -fsS http://127.0.0.1:9091/v1/users | jq .
curl -sk "https://example.com/" --resolve "example.com:443:127.0.0.1" -o /dev/null -w '%{http_code}\n'
sudo nginx -t
sudo iptables -L MTPR_SYNFIX -n -v
sudo ufw status verbose
sudo openssl x509 -in /etc/letsencrypt/live/example.com/fullchain.pem -noout -dates
journalctl -u telemt -n 30 --no-pager
```

Для mask-site ожидается HTTP-код `200` при локальной проверке через `--resolve`.

## 9. Обслуживание

Перезапуск `telemt`:

```bash
sudo systemctl restart telemt
```

Перезапуск `nginx`:

```bash
sudo systemctl restart nginx
```

Логи `telemt`:

```bash
journalctl -u telemt -n 100 --no-pager
```

Live-мониторинг:

```bash
sudo tg
```

или:

```bash
sudo bash install.sh
```

Затем выберите пункт `3`. Выход: `q` или `0`.

Команда `tg` устанавливается автоматически в `/usr/local/bin/tg` и открывает то же меню управления.

## 10. MEKO SYN FIX: версия и обновление

Проверить версию и статус:

```bash
sudo bash install.sh
```

Пункт меню `7` показывает:

- установленную версию
- версию в комплекте telemt-deploy
- доступность обновления

Обновить через CLI:

```bash
sudo bash install.sh --meko-upgrade
```

Принудительно переустановить правила:

```bash
sudo bash install.sh --meko-upgrade --yes
```

## 11. Переустановка и существующая установка

Если установка уже найдена, скрипт предложит:

- удалить и установить заново
- оставить текущую установку как есть

CLI-варианты:

```bash
sudo bash install.sh --domain example.com --fresh --yes
sudo bash install.sh --keep
```

`--fresh` удаляет установленный стек перед новой установкой. Секрет `/root/telemt-secret.txt` и сертификаты Let's Encrypt сохраняются.

## 12. Удаление

Интерактивно:

```bash
sudo bash install.sh
```

Затем выберите пункт `11`.

Через CLI:

```bash
sudo bash install.sh --uninstall
```

Удаляются:

- systemd-сервисы `telemt` и `mtpr-synfix`
- бинарник `/bin/telemt`
- конфиг `/etc/telemt`
- nginx-сайты `telemt-site` и `telemt-acme-temp`
- inline MEKO-файлы в `/opt/mtpr-simple`
- state-файл `/root/telemt-deploy.state`

Сохраняются:

- `/root/telemt-secret.txt`
- сертификаты в `/etc/letsencrypt/live/DOMAIN/`

## 13. Основные файлы

- `install.sh` - точка входа, CLI-флаги и интерактивное меню
- `status.sh` - короткий запуск `install.sh --status`
- `lib/common.sh` - общие функции, валидация, wait/helper-логика
- `lib/install_flow.sh` - основной поток установки
- `lib/verify.sh` - проверки работоспособности
- `lib/menu.sh` - интерактивное меню
- `lib/telemt.sh` - установка бинарника и конфигурации `telemt`
- `lib/nginx.sh` - временный и production nginx
- `lib/ssl.sh` - выпуск сертификата
- `lib/meko.sh` - MEKO SYN FIX
- `lib/firewall.sh` - UFW-правила
- `templates/` - шаблоны systemd, nginx и telemt
- `tests/smoke.sh` - безопасные локальные проверки

## 14. Troubleshooting

### DNS не совпадает с IP сервера

Проверьте:

```bash
dig +short A example.com
curl -fsS --max-time 10 ifconfig.me
```

Исправьте `A`-запись и дождитесь обновления DNS.

### Порт 443 занят

Проверьте:

```bash
sudo ss -tlnp | grep ':443 '
```

Остановите конфликтующий сервис или перенесите его на другой порт.

### Certbot не получил сертификат

Проверьте:

```bash
sudo systemctl status nginx --no-pager
sudo nginx -t
dig +short A example.com
sudo ufw status verbose
```

Порт `80/tcp` должен быть доступен извне.

### telemt не стартует

Проверьте:

```bash
journalctl -u telemt -n 100 --no-pager
sudo /bin/telemt --version
sudo ls -l /etc/telemt/telemt.toml
```

### Нет ссылки из API

Проверьте локальный API:

```bash
curl -fsS http://127.0.0.1:9091/v1/users | jq .
```

Если API недоступен, смотрите логи `telemt`.

### MEKO SYN FIX не применён

Проверьте:

```bash
systemctl is-active mtpr-synfix
sudo iptables -L MTPR_SYNFIX -n -v
```

При необходимости переустановите через меню, пункт `7`.

## 14. Важные замечания по безопасности

- Установка меняет `nginx`, `systemd`, `ufw` и `iptables`.
- Перед установкой убедитесь, что SSH-доступ не зависит от закрываемых firewall-правил.
- `--meko-full` запускает внешний установщик MEKO. Используйте его только если доверяете источнику.
- Секрет MTProxy хранится в `/root/telemt-secret.txt` с правами `600`.
- Не публикуйте `/root/telemt-deploy.state`, секрет и вывод handoff в публичных местах.
