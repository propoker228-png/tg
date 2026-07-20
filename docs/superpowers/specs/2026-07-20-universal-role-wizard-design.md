# telemt-deploy — универсальный мастер установки по ролям

**Дата:** 2026-07-20  
**Статус:** Утверждено  
**Версия целевая:** 2.9  
**Базируется на:** `2026-07-20-telemt-multi-proxy-design.md` (v2.8)

## Цель

Сделать установщик универсальным: при первой установке пользователь выбирает роль сервера, мастер задаёт недостающие вопросы и ставит **только** нужный набор компонентов. Поддерживаются три сценария:

1. **Одиночный прокси** — один VPS, одна ссылка (текущее поведение).
2. **Нода кластера** — telemt-нода с общим SECRET и кластерным доменом в ссылке.
3. **Master + LB** — управление кластером и HAProxy на одном сервере (без telemt).

## Не в scope

- Миграция standalone → cluster на серверах с пользователями (отдельная задача).
- Автоматическая регистрация ноды на master по обратному SSH.
- Пошаговый wizard с кнопкой «Назад» (отложено).

## Роли

| ID | Роль | `ROLE` в конфиге | Компоненты |
|----|------|------------------|------------|
| 1 | Одиночный прокси | `standalone` | prereq, nginx, ssl, telemt, meko, firewall, tg |
| 2 | Нода кластера | `node` | то же + cluster config, общий SECRET |
| 3 | Master + LB | `master_lb` | prereq (minimal), haproxy, cluster init, firewall |

CLI для автоматизации сохраняет `--role=standalone|node|lb|master|master-lb`. Значения `master` и `lb` остаются для обратной совместимости; интерактив предлагает объединённую роль `master_lb`.

## Точка входа

Мастер ролей запускается когда:

- Меню → **1) Установка / переустановка**
- `sudo bash install.sh` без action-флагов и без существующей установки (опционально — первый запуск)

Не запускается когда:

- Переданы `--domain`, `--role`, `--cluster-domain` и др. action-флаги (CLI-путь без изменений, кроме `master-lb`)
- `--status`, `--doctor`, подкоманды `tg`

### Экран выбора роли

```
=== Выберите роль сервера ===
  1) Одиночный прокси          (telemt + nginx + MEKO)
  2) Нода кластера             (telemt + nginx + MEKO, общий SECRET)
  3) Master + балансировщик    (HAProxy + управление кластером)
  0) Отмена
```

При повторной установке: показать текущую роль из `/etc/telemt-deploy.cluster` (если есть) и спросить — оставить / сменить / отмена.

Перед стартом — цветная сводка параметров и подтверждение `y/N` (как version picker).

## Мастер по ролям

### 1) Одиночный прокси

Порядок вопросов (существующая логика v2.8):

1. Способ подключения: свой домен / IP-only
2. Домен или TLS-маска
3. Version picker (telemt + MEKO)
4. `ad_tag` (опционально)
5. Сводка → подтверждение

Вызывает: `prepare_install_domain` → `prepare_install_options` → `run_install_flow`.

### 2) Нода кластера

Порядок вопросов:

1. **Кластерный домен** — публичный домен единой ссылки (`CLUSTER_DOMAIN`)
2. **Способ подключения ноды:** свой домен / IP-only + TLS-маска (оба режима как у standalone)
3. **Домен маски** (`DOMAIN` / `TLS_DOMAIN`)
4. **SECRET:**
   - `1)` Ввести вручную (32 hex)
   - `2)` Скачать с master по SSH → `IP master`, `SSH user` (default `root`)
5. Version picker
6. `ad_tag` (опционально)
7. Сводка (SECRET маскирован, preview кластерной ссылки)
8. Подтверждение

Вызывает: `run_cluster_node_install` (после сбора параметров).

Валидация:

- `CLUSTER_DOMAIN` — валидный домен; DNS на эту ноду не требуется
- `DOMAIN` / mask — DNS на IP этой ноды (как standalone)
- `CLUSTER_SECRET` — 32 hex или успешный SSH-fetch

После установки: `cluster_register_self_node` (локальная запись). IP ноды должен быть добавлен в inventory на master (при установке master или через меню 12).

### 3) Master + LB

Порядок вопросов:

1. **Кластерный домен** — A-запись на **этот** сервер (проверка DNS)
2. **Добавить ноды сейчас?** `y/N`
   - Да: цикл `имя → IP → порт [443]` до пустой строки
   - Нет: пустой inventory
3. Сводка: домен, список нод, сгенерированный SECRET (для копирования на ноды)
4. Подтверждение

Вызывает: `run_cluster_master_lb_install()` (новая функция).

Поведение HAProxy:

- **≥1 нода:** `haproxy_deploy`, firewall, показать единую ссылку
- **0 нод:** сохранить master config + SECRET; HAProxy **не** стартовать; сообщение «добавьте ноды через меню → 12) Кластер»

## Модуль `lib/role_wizard.sh`

| Функция | Назначение |
|---------|------------|
| `role_wizard_run` | Главный диспетчер |
| `prompt_install_role` | Экран выбора 1/2/3 |
| `wizard_standalone` | Одиночный прокси |
| `wizard_cluster_node` | Сбор параметров ноды |
| `wizard_master_lb` | Сбор параметров master+lb |
| `prompt_cluster_secret` | Ручной ввод или SSH с master |
| `prompt_cluster_nodes` | Цикл добавления нод |
| `print_role_summary` | Сводка перед установкой |

`ROLE_WIZARD_SH_VERSION="1.0"`

## Изменения в `lib/cluster.sh`

- `cluster_fetch_secret_ssh(master_ip, ssh_user)` — скачать `/root/telemt-secret.txt` с master
- `run_cluster_master_lb_install()` — `cluster_init_master` + nodes + conditional `haproxy_deploy`
- `cluster_load` / `cluster_save` — роль `master_lb`
- `case` валидации ролей: `master_lb|master|lb|node|standalone`

## Изменения в `lib/prereq.sh`

- `prereq_install_minimal` — пакеты для master_lb: `haproxy`, `curl`, `ufw`, `openssl` (без nginx/certbot)

## Изменения в `install.sh`

- `source role_wizard.sh`
- `require_lib_bundle` — проверка `ROLE_WIZARD_SH_VERSION`
- `--role=master-lb` → `CLUSTER_ROLE=master_lb`
- Интерактивный путь установки → `role_wizard_run` (вместо прямого `prepare_install_domain`)

## Изменения в `lib/menu.sh`

- `menu_install` → `role_wizard_run` (после `handle_existing_env`)

## Меню «12) Кластер»

- Отображать роль `master_lb` в статусе
- Скрыть «Установить HAProxy», если роль уже `master_lb` и HAProxy active

## Флаги `--yes`

- Пропускает подтверждения `y/N`
- **Не** пропускает выбор роли и обязательные поля
- При нехватке параметров — `die` с примером CLI-команды

## Краевые случаи

| Ситуация | Поведение |
|----------|-----------|
| Master+LB, 0 нод | Config + SECRET; HAProxy не стартует |
| SSH за SECRET failed | Предложить ручной ввод |
| Порт 443 занят | `die` + hint `ss -tlnp` |
| Смена роли при установке | Предупреждение; нужен `--fresh` или подтверждение переустановки |
| Нода: нет SECRET | Блокировка до ввода или успешного SSH |

## Тестирование

| Файл | Покрытие |
|------|----------|
| `tests/role_wizard_smoke.sh` | Выбор роли, валидация SECRET, summary render (моки) |
| `tests/cluster_smoke.sh` | `master_lb` init, HAProxy с нодами |
| `tests/smoke.sh` | Синтаксис `role_wizard.sh` |

## Поток данных (без изменений)

```
Клиент → tg://proxy?server=CLUSTER_DOMAIN
      → DNS → Master+LB (HAProxy :443)
      → balance source → Node N :443
      → Telegram DC
```

## Риски

| Риск | Митигация |
|------|-----------|
| Пользователь выбрал неверную роль | Показ текущей роли при переустановке; doctor |
| Master+LB без нод | Явное предупреждение; HAProxy не стартует |
| SECRET по SSH без ключа | Fallback на ручной ввод |
