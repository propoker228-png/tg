# telemt-deploy

Автоустановка **telemt** + **nginx self-mask** + **MEKO SYN FIX** на Ubuntu 22.04/24.04.

Установщик **v3.0** — универсальный мастер ролей: одиночный прокси, нода кластера или master+LB с **веб-панелью** кластера.

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
| 1 | Установка / переустановка (мастер ролей) |
| 2 | Статистика (разово, список IP) |
| 3 | Мониторинг live (обновление каждые 4 с, `q` — выход) |
| 4 | Сервисы (restart, логи) |
| 5 | Настройки прокси (ad_tag) |
| 6 | SSL |
| 7 | MEKO SYN FIX |
| 8 | Firewall |
| 9 | Проверки (быстрая / doctor) |
| 10 | Обновить telemt |
| 11 | Удалить стек |
| 12 | Кластер / мульти-прокси |
| 0 | Выход |

При выборе **1) Установка** откроется **мастер ролей** (installer v3.0):

| # | Роль | Компоненты |
|---|------|------------|
| 1 | Одиночный прокси | telemt + nginx + MEKO |
| 2 | Нода кластера | telemt + nginx + MEKO, общий SECRET |
| 3 | Master + балансировщик | HAProxy + управление кластером |

Мастер задаёт только недостающие вопросы для выбранной роли, показывает сводку и запрашивает подтверждение.

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
| `--doctor` | Полная диагностика (как `tg doctor`) |
| `--meko-upgrade` | Обновить MEKO SYN FIX до версии из комплекта |
| `--uninstall` | Удалить установленный стек |
| `--role ROLE` | `standalone` \| `node` \| `lb` \| `master` \| `master-lb` (кластер) |
| `--cluster-agent-token HEX` | Токен push-агента (для node) |
| `--master-panel-url URL` | URL панели master (`https://IP:8443`) |
| `--node-name NAME` | Имя ноды в кластере |

### Панель и CLI кластера (v3.0)

На **master_lb** поднимается панель на **https://&lt;IP&gt;:8443** (логин/пароль выводятся после установки).

```bash
tg cluster status
tg cluster monitor
tg cluster panel-credentials
tg cluster migrate-domain NEW_DOMAIN
```

| `--cluster-domain DOMAIN` | Публичный домен единой ссылки |
| `--cluster-secret HEX` | Секрет кластера (для node) |
| `--node SPEC` | Backend LB: `name:ip:port` (можно несколько раз) |
| `-h`, `--help` | Справка |

## Кластер / мульти-прокси

Несколько telemt-нод за одним доменом и **одной** `tg://proxy`-ссылкой. HAProxy (TCP passthrough) балансирует нагрузку и исключает мёртвые ноды.

```bash
# 1. Master + LB (v3.0): HAProxy, панель :8443, управление кластером
sudo bash install.sh --role=master-lb --cluster-domain proxy.example.com \
  --node node1:203.0.113.10:443 --node node2:203.0.113.11:443 --yes

# 2. Master (legacy): инициализация кластера и SECRET
sudo bash install.sh --role=master --cluster-domain proxy.example.com --yes

# 3. Node: на каждом VPS (mask-домен + кластерный домен)
sudo bash install.sh --role=node --domain mask1.example.com \
  --cluster-domain proxy.example.com --cluster-secret HEX --fresh --yes

# 4. LB (legacy): HAProxy на отдельном VPS (DNS proxy.example.com → IP LB)
sudo bash install.sh --role=lb --cluster-domain proxy.example.com \
  --node node1:203.0.113.10:443 --node node2:203.0.113.11:443 --yes
```

Интерактивно: пункт меню **1)** → роль **3) Master + балансировщик** (или **2) Нода кластера**).

Управление через меню: пункт **12) Кластер / мульти-прокси**.

Спецификация: [docs/superpowers/specs/2026-07-20-telemt-multi-proxy-design.md](docs/superpowers/specs/2026-07-20-telemt-multi-proxy-design.md)

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

## Команды tg

```bash
sudo tg doctor              # полная диагностика
sudo tg doctor --quick      # быстрая проверка
sudo tg link                # ссылка прокси
sudo tg link --qr           # ссылка + QR (нужен qrencode)
sudo tg backup              # полный бэкап (сертификаты Let's Encrypt)
sudo tg restore /root/telemt-backup-....tar.gz
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
bash tests/smoke.sh              # синтаксис + безопасные helper/CLI проверки
bash tests/cluster_smoke.sh      # кластер и HAProxy (без root)
bash tests/panel_smoke.sh       # API панели (без root)
bash tests/role_wizard_smoke.sh  # мастер ролей: summary, SECRET, ноды (без root)
bash install.sh --help           # справка
sudo tg                          # меню управления после установки
```

`tests/smoke.sh` не выполняет установку и не меняет `apt`, `nginx`, `systemd`,
`ufw`, `iptables` или `certbot`. Реальную проверку установки запускайте только
на подготовленном сервере с доменом и свободным портом 443.

## Требования

- Ubuntu 22.04 или 24.04
- root / sudo
- Домен с A-записью на публичный IP сервера
- Свободный порт 443
