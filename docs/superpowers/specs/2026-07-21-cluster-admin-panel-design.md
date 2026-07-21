# telemt-deploy — админ-панель кластера и смена домена

**Дата:** 2026-07-21  
**Статус:** Утверждено  
**Версия целевая:** 3.0  
**Базируется на:** `2026-07-20-universal-role-wizard-design.md` (v2.9)

## Цель

При установке роли **Master + LB** развернуть админ-панель для мониторинга кластера и управления кластерным доменом. Панель доступна в **браузере** и дублируется в **CLI**. Ноды отправляют метрики на master push-агентом.

## Не в scope

- Смена mask-доменов нод (nginx/LE на каждой ноде)
- Автоматическое обновление DNS у регистратора
- Telegram-уведомления при падении нод
- Миграция standalone → cluster
- Push-агент как единственный health check (HAProxy TCP check остаётся)

## Требования (согласовано)

| Тема | Решение |
|------|---------|
| UI | Веб-панель + CLI (`tg cluster …`) |
| Метрики | Push-агент на нодах → HTTP POST на master |
| Смена домена | Только `CLUSTER_DOMAIN` (ссылка `server=`), mask не трогаем |
| Доступ к вебу | Публичный URL, логин/пароль при установке master |
| Миграция домена | Авто по SSH на все ноды; DNS настраивает администратор |

## Архитектура

```
┌─────────────┐     POST /api/v1/metrics      ┌──────────────────┐
│  Node 1..N  │ ─────────────────────────► │  Master + LB     │
│ telemt-agent│     Bearer NODE_TOKEN        │  panel :8443     │
│  :9091 local│                              │  nginx + API     │
└─────────────┘                              │  HAProxy :443    │
        ▲                                    └──────────────────┘
        │ SSH (domain migrate, tokens)                  │
        └───────────────────────────────────────────────┘
                              ▲
                    Browser / tg cluster monitor
```

- Порт **443** на master — HAProxy (MTProxy), без изменений.
- Порт **8443** — HTTPS админ-панель (nginx).

## Компоненты

### Master (новое при `master_lb`)

| Компонент | Назначение |
|-----------|------------|
| nginx `:8443` | TLS termination, static UI, reverse proxy к API |
| `panel_server.py` | HTTP API (stdlib), приём метрик, migrate domain |
| `/opt/telemt-panel/` | Статика dashboard (HTML/CSS/JS) |
| `/var/lib/telemt-deploy/metrics/` | Последние метрики по нодам (`<node>.json`) |
| `/etc/telemt-deploy.panel` | `PANEL_USER`, `PANEL_PASS` (chmod 600) |
| `/etc/telemt-deploy.cluster.tokens` | `node token` на строку (chmod 600) |

### Node (новое при `node` или при регистрации в inventory)

| Компонент | Назначение |
|-----------|------------|
| `telemt-agent.service` | Timer/cron каждые 10 с |
| `telemt-agent.sh` | Сбор с localhost:9091, POST на master |
| `/etc/telemt-deploy.agent` | `MASTER_URL`, `NODE_NAME`, `NODE_TOKEN` |

## Push-агент

**Интервал:** 10 с (конфиг `AGENT_INTERVAL_SEC`).

**Локальный сбор:**
- `people` — из `/v1/stats/users/active-ips` (логика как `fetch_proxy_online_people` в `lib/stats.sh`)
- `tcp` — из `/v1/users` (как `fetch_proxy_connections_total`)
- `telemt_active` — `systemctl is-active telemt`

**POST** `https://<master-ip>:8443/api/v1/metrics`

```json
{
  "node": "node1",
  "people": 42,
  "tcp": 128,
  "telemt_active": true,
  "ts": "2026-07-21T13:00:00Z"
}
```

**Заголовок:** `Authorization: Bearer <NODE_TOKEN>`

**Токен:** генерируется на master при `cluster_add_node`; доставляется на ноду при установке (`--cluster-agent-token`) или через `cluster_deploy_agent_ssh`.

## API master

| Метод | Путь | Auth | Описание |
|-------|------|------|----------|
| POST | `/api/v1/metrics` | Bearer NODE_TOKEN | Запись метрик ноды |
| GET | `/api/v1/cluster` | HTTP Basic (panel) | Состояние кластера + метрики + ссылка |
| POST | `/api/v1/domain/migrate` | HTTP Basic | Смена `CLUSTER_DOMAIN` |

**Ответ `GET /api/v1/cluster`:**

```json
{
  "cluster_domain": "proxy.example.com",
  "proxy_link": "tg://proxy?...",
  "nodes": [
    {
      "name": "node1",
      "ip": "203.0.113.10",
      "port": 443,
      "haproxy_up": true,
      "people": 42,
      "tcp": 128,
      "telemt_active": true,
      "last_seen_sec": 8,
      "status": "online"
    }
  ],
  "totals": { "people": 120, "tcp": 400 }
}
```

**Статус ноды в панели:**
- `online` — last POST < 30 с
- `stale` — 30–120 с
- `offline` — > 120 с или нет данных

`haproxy_up` — из существующего `cluster_check_node_tcp` (не заменяет HAProxy health check).

## Веб-панель

**URL:** `https://<master-ip>:8443/` (v1: self-signed сертификат; опционально LE в v3.1).

**Экраны:**
1. **Dashboard** — таблица нод, суммарные people/TCP, HAProxy status
2. **Ссылка** — единая `tg://proxy` с кнопкой копирования
3. **Домен** — форма нового `CLUSTER_DOMAIN`, кнопка «Применить»

**Авторизация:** HTTP Basic Auth (логин/пароль из `/etc/telemt-deploy.panel`). Пароль генерируется при установке master (16+ символов). Показ в конце `run_cluster_master_lb_install` и в `tg cluster panel-credentials`.

**Обновление UI:** polling `GET /api/v1/cluster` каждые 5 с.

## CLI

| Команда | Описание |
|---------|----------|
| `tg cluster status` | Snapshot (таблица нод + totals) |
| `tg cluster monitor` | Live, refresh 4 с, выход `q` |
| `tg cluster panel-credentials` | Показать URL, логин, пароль |
| `tg cluster migrate-domain NEW_DOMAIN` | Смена домена (как API) |

Меню **12) Кластер** — новые пункты:
- «Панель / учётные данные»
- «Мониторинг кластера (live)»
- «Сменить кластерный домен»

## Смена кластерного домена

**Вход:** `NEW_DOMAIN` (валидный домен).

**Шаги (`cluster_migrate_domain`):**
1. `require_valid_domain_name`
2. Сохранить `CLUSTER_DOMAIN_PREVIOUS` в `/etc/telemt-deploy.cluster.history` (одна строка)
3. Обновить `CLUSTER_DOMAIN` в `/etc/telemt-deploy.cluster`
4. Для каждой ноды в inventory (SSH `CLUSTER_SSH_USER`):
   - Обновить `public_host` и `tls_domain` в `/etc/telemt/telemt.toml` на `NEW_DOMAIN`
   - `systemctl restart telemt`
   - При ошибке SSH — логировать, продолжить остальные; итоговый отчёт
5. HAProxy — без изменения backends (`haproxy_reload` опционально no-op)
6. Вернуть новую `tg://proxy`-ссылку
7. Вывести напоминание: настроить DNS A-запись `NEW_DOMAIN` → IP master

**Не меняется:** mask-домены, nginx site на нодах, SECRET, порты backends.

## Установка (интеграция с wizard)

**`run_cluster_master_lb_install`** дополнительно:
1. `panel_install` — nginx, panel_server systemd unit, static files, self-signed cert
2. `panel_generate_credentials`
3. UFW: открыть `8443/tcp`
4. Вывести URL + credentials

**`run_cluster_node_install`** дополнительно:
1. Если задан `NODE_TOKEN` и `MASTER_PANEL_URL` — `agent_install` + start
2. Иначе — предупреждение «настройте агент с master»

**`cluster_add_node`** — генерировать токен, сохранять в `.cluster.tokens`.

## Новые модули

| Файл | Назначение |
|------|------------|
| `lib/panel.sh` | Установка панели, credentials, nginx site |
| `lib/panel_api.py` | HTTP API (metrics, cluster, migrate) |
| `lib/cluster_agent.sh` | Установка агента на ноде, deploy по SSH |
| `lib/cluster_migrate.sh` | `cluster_migrate_domain` |
| `templates/panel/index.html` | Dashboard UI |
| `templates/nginx-panel.tpl` | nginx vhost :8443 |
| `templates/telemt-agent.service` | systemd unit |
| `templates/telemt-agent.sh.tpl` | Скрипт агента |
| `templates/telemt-panel.service` | API server unit |
| `tests/panel_smoke.sh` | API auth, metrics write, migrate dry-run |

## Безопасность

| Риск | Митигация |
|------|-----------|
| Перехват метрик | HTTPS на :8443; токены per-node |
| Брутфорс панели | Basic Auth + длинный пароль; опционально fail2ban (v3.1) |
| Подделка метрик | Bearer token обязателен; неизвестный token → 401 |
| Утечка credentials | chmod 600; не логировать пароль |
| Migrate без auth | Только Basic Auth panel user |

## Ошибки

| Ситуация | Поведение |
|----------|-----------|
| Агент не может достучаться до master | Retry; нода `stale`/`offline` в панели |
| telemt API недоступен на ноде | POST с `people=0`, `telemt_active=false` |
| Migrate: SSH fail на ноде | Отчёт по нодам; частичный успех явно указан |
| Панель не установлена (старый master) | `tg cluster panel-credentials` → hint установить панель |

## Тестирование

- `tests/panel_smoke.sh` — POST metrics с токеном, GET cluster с Basic Auth, migrate валидация (mock SSH)
- `tests/cluster_smoke.sh` — token generation при add_node
- `tests/smoke.sh` — синтаксис новых модулей

## Версия

`INSTALLER_VERSION` → **3.0**
