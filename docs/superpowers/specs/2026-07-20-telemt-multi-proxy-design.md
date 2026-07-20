# telemt-deploy — мульти-прокси (одна ссылка, несколько серверов)

**Дата:** 2026-07-20  
**Статус:** Утверждено  
**Версия целевая:** 2.8

## Цель

Развернуть несколько telemt-нод за одним публичным доменом и выдавать пользователям **одну** `tg://proxy`-ссылку. Обеспечить балансировку нагрузки и автоматический failover при падении ноды через L4-балансировщик (HAProxy TCP passthrough).

## Ограничение протокола

Формат `tg://proxy?server=&port=&secret=` поддерживает только один сервер. Failover и балансировка реализуются на инфраструктурном уровне: DNS → HAProxy → пул telemt-нод.

## Роли

| Роль | Где запускается | Что устанавливает |
|------|-----------------|-------------------|
| `standalone` (по умолчанию) | Любой VPS | telemt + nginx + MEKO (текущее поведение) |
| `node` | Каждая telemt-нода | telemt + nginx + MEKO; `public_host` = кластерный домен |
| `lb` | VPS балансировщика | Только HAProxy :443 → backends |
| `master` | Управляющая машина | Инициализация кластера, inventory нод, синхронизация SECRET |

Роль `master` — логическая: машина с файлом `/etc/telemt-deploy.cluster` и `ROLE=master`. Может совпадать с `lb` или первой `node`.

## Файлы конфигурации

### `/etc/telemt-deploy.cluster`

```bash
ROLE=master          # master | lb | node
CLUSTER_DOMAIN=proxy.example.com
SSH_USER=root
CREATED_AT=2026-07-20T12:00:00Z
```

### `/etc/telemt-deploy.cluster.nodes`

По одной ноде на строку: `имя ip порт`

```
node1 203.0.113.10 443
node2 203.0.113.11 443
node3 203.0.113.12 443
```

### `/root/telemt-secret.txt`

Один SECRET на весь кластер. Генерируется на master, копируется на ноды (`cluster_sync_secret`).

## telemt.toml в кластере

| Поле | standalone | node |
|------|------------|------|
| `public_host` | `DOMAIN` (домен ноды) | `CLUSTER_DOMAIN` (домен LB) |
| `tls_domain` | `DOMAIN` | `CLUSTER_DOMAIN` (одинаковый на всех нодах) |
| nginx / LE | `DOMAIN` (маскировка на ноде) | `DOMAIN` (свой домен маски на каждой ноде) |

## HAProxy

- Режим: TCP passthrough (без TLS termination — FakeTLS ломается иначе).
- Балансировка: `balance source` (sticky по IP клиента).
- Health check: TCP connect на порт ноды, `inter 5s fall 3 rise 2`.
- Конфиг: `/etc/haproxy/haproxy.cfg` из `templates/haproxy.cfg.tpl`.

## CLI

```
--role ROLE              standalone | node | lb | master
--cluster-domain DOMAIN  Публичный домен ссылки (обязателен для node/lb/master)
--cluster-secret HEX     Секрет кластера (node: импорт с master)
--node SPEC              Добавить backend: name:ip:port (lb install / master)
```

Примеры:

```bash
# Master: инициализация кластера
sudo bash install.sh --role=master --cluster-domain proxy.example.com --yes

# Node
sudo bash install.sh --role=node --domain mask1.example.com \
  --cluster-domain proxy.example.com --yes

# LB
sudo bash install.sh --role=lb --cluster-domain proxy.example.com \
  --node node1:203.0.113.10:443 --node node2:203.0.113.11:443 --yes
```

## Меню

Пункт **12) Кластер / мульти-прокси**:

- Статус кластера и нод (health check)
- Единая ссылка прокси
- Добавить / удалить ноду
- Пересобрать HAProxy
- Синхронизировать SECRET на ноды (SSH)

## Поток данных

```
Клиент → tg://proxy?server=CLUSTER_DOMAIN
      → DNS → HAProxy:443
      → balance source → telemt node N:443
      → Telegram DC
```

При падении ноды HAProxy исключает её из пула; клиент переподключается к другой ноде.

## Риски

| Риск | Митигация |
|------|-----------|
| LB — единая точка отказа | Резервный LB + переключение DNS |
| Один SECRET на всех | SSH только по ключу; chmod 600 на secret |
| Разные версии telemt | Master предупреждает при sync |

## Новые модули

| Файл | Назначение |
|------|------------|
| `lib/cluster.sh` | Inventory, роли, sync, статус, ссылка |
| `lib/haproxy.sh` | Установка и деплой HAProxy |
| `templates/haproxy.cfg.tpl` | Шаблон балансировщика |
