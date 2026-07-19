# telemt-deploy

Автоустановка **telemt** + **nginx self-mask** + **MEKO SYN FIX** на Ubuntu 22.04/24.04.

## Быстрый старт

```bash
git clone git@github.com:propoker228-png/tg.git
cd tg
sudo bash install.sh
```

Полная инструкция по развёртыванию: [DEPLOY.md](DEPLOY.md)

Скрипт откроет **интерактивное меню** (установка, статистика, мониторинг, сервисы и др.) или выполнит установку по флагам.

## Интерактивное меню

```bash
sudo bash install.sh
```

Пункты меню:

| # | Действие |
|---|----------|
| 1 | Установка / переустановка |
| 2 | Статистика (разово, список IP) |
| 3 | Мониторинг live (обновление каждые 4 с, `q` — выход) |
| 4 | Сервисы (restart, логи) |
| 5 | Настройки прокси (ad_tag) |
| 6 | SSL |
| 7 | MEKO SYN FIX |
| 8 | Firewall |
| 9 | Проверки |
| 10 | Обновить telemt |
| 11 | Удалить стек |
| 0 | Выход |

В шапке меню: домен, версия telemt, **число подключённых** (жёлтым, как в MEKO), TCP, статусы сервисов.

Флаги `--status`, `--domain`, `--uninstall` и др. **обходят меню** (для автоматизации и cron).

## Быстрый старт (CLI)

| Флаг | Описание |
|------|----------|
| `--domain DOMAIN` | Домен с A-записью на этот сервер |
| `--ad-tag HEX32` | `ad_tag` из @MTProxybot (32 hex-символа) |
| `--telemt-version VER` | Предвыбор версии telemt в меню версий |
| `--meko-version VER` | Предвыбор версии MEKO в меню версий |
| `--meko-full` | Предвыбор полного MEKO Launcher в меню типа |
| `--yes` | Без лишних y/N; выбор версий остаётся интерактивным |
| `--fresh` | Удалить найденную установку и поставить с нуля |
| `--keep` | Оставить найденную установку как есть |
| `--status` | Статус и число подключённых (без меню) |
| `--check-rkn` | Проверить IP сервера в реестре РКН (без меню) |
| `--meko-upgrade` | Обновить MEKO SYN FIX до версии из комплекта |
| `--uninstall` | Удалить установленный стек |
| `-h`, `--help` | Справка |

## Примеры

Интерактивная установка:

```bash
sudo bash install.sh
```

Полностью автоматическая (домен + ad_tag; версии выбираются в меню):

```bash
sudo bash install.sh --domain example.com --ad-tag 13ea0123456789abcdef0123456789ab --yes
```

Перед установкой скрипт покажет выбор **4 версий telemt** и **4 версий MEKO** (сначала тип: inline / full), затем цветную сводку параметров.

Конкретная версия telemt:

```bash
sudo bash install.sh --domain example.com --telemt-version 3.4.23 --yes
```

Полный MEKO Launcher:

```bash
sudo bash install.sh --domain example.com --meko-full --yes
```

Удаление (секрет и сертификаты Let's Encrypt сохраняются):

```bash
sudo bash install.sh --uninstall
```

## Что устанавливается

1. Пакеты: nginx, certbot, iptables, ufw и др.
2. Временный nginx для ACME challenge → Let's Encrypt сертификат
3. Production nginx self-mask (порт 8444)
4. telemt на порту 443 с TLS-режимом
5. MEKO SYN FIX (inline или `--meko-full`)
6. UFW: порты 80 и 443

## Файлы на сервере

| Путь | Назначение |
|------|------------|
| `/root/telemt-secret.txt` | Секрет прокси (сохраняется при переустановке) |
| `/root/telemt-deploy.state` | Состояние последней установки |
| `/etc/telemt/telemt.toml` | Конфигурация telemt |
| `/etc/letsencrypt/live/DOMAIN/` | SSL-сертификат |

## Проверка

```bash
bash tests/smoke.sh          # синтаксис + безопасные helper/CLI проверки
bash install.sh --help       # справка
sudo tg                      # меню управления после установки
```

`tests/smoke.sh` не выполняет установку и не меняет `apt`, `nginx`, `systemd`,
`ufw`, `iptables` или `certbot`. Реальную проверку установки запускайте только
на подготовленном сервере с доменом и свободным портом 443.

## Требования

- Ubuntu 22.04 или 24.04
- root / sudo
- Домен с A-записью на публичный IP сервера
- Свободный порт 443
