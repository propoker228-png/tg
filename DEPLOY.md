# Развёртывание сервера из Git

Пошаговая инструкция: от чистого Ubuntu-сервера до работающего MTProxy-стека через репозиторий [propoker228-png/tg](https://github.com/propoker228-png/tg).

Скрипт устанавливает:

- **telemt** на порту `443`
- **nginx** self-mask на `127.0.0.1:8444`
- **Let's Encrypt** SSL-сертификат
- **MEKO SYN FIX** (inline iptables)
- команду **`tg`** для управления после установки

Установщик **v2.9** поддерживает универсальный **мастер ролей** при интерактивной установке (пункт меню **1**).

---

## 1. Что нужно заранее

| Требование | Описание |
|------------|----------|
| ОС | Ubuntu **22.04** или **24.04** |
| Доступ | `root` или пользователь с `sudo` |
| IP | Публичный IPv4-адрес сервера |
| Домен | `A`-запись указывает на IP сервера |
| Порты | Свободны **80** и **443** |
| Git | Доступ к GitHub (SSH или HTTPS) |

Проверка DNS **до** установки (с вашего ПК или с сервера):

```bash
dig +short A your-domain.example
```

IP в ответе должен совпадать с публичным IP VPS.

На сервере:

```bash
curl -fsS --max-time 10 ifconfig.me
```

---

## 2. Подготовка сервера

Подключитесь по SSH:

```bash
ssh root@YOUR_SERVER_IP
```

Обновите систему и установите git:

```bash
apt update
apt install -y git curl
```

Убедитесь, что порт 443 свободен:

```bash
ss -tlnp | grep ':443 ' || echo "порт 443 свободен"
```

Если порт занят — остановите конфликтующий сервис или используйте другой сервер.

---

## 3. Клонирование репозитория

Репозиторий: **https://github.com/propoker228-png/tg**

### Вариант A — SSH (рекомендуется)

На сервере должен быть SSH-ключ, добавленный в GitHub  
([настройка ключей](https://github.com/settings/keys)).

```bash
cd /root
git clone git@github.com:propoker228-png/tg.git
cd tg
```

### Вариант B — HTTPS

```bash
cd /root
git clone https://github.com/propoker228-png/tg.git
cd tg
```

При запросе логина GitHub используйте **Personal Access Token** вместо пароля.

### Проверка содержимого

```bash
ls -la
# install.sh  lib/  templates/  tests/  README.md
```

---

## 4. Проверка скрипта перед установкой

Безопасные проверки — **не меняют** систему:

```bash
bash tests/smoke.sh
bash tests/role_wizard_smoke.sh
bash install.sh --help
```

Ожидаемый результат:

```text
ALL SYNTAX OK
ALL ROLE WIZARD SMOKE OK
```

---

## 5. Установка

### 5.1 Интерактивно (через меню)

```bash
sudo bash install.sh
```

1. Выберите пункт **`1`** — Установка / переустановка  
2. Если найдена старая установка — выберите **удалить и поставить с нуля** или **оставить**  
3. **Мастер ролей** (v2.9) — выберите роль сервера:

   | # | Роль | Что будет установлено |
   |---|------|------------------------|
   | 1 | Одиночный прокси | telemt + nginx + MEKO (один VPS, одна ссылка) |
   | 2 | Нода кластера | telemt + nginx + MEKO, общий SECRET с кластером |
   | 3 | Master + балансировщик | HAProxy + управление кластером (без telemt) |

4. Ответьте на вопросы мастера (домен, SECRET, ноды — в зависимости от роли)  
5. Подтвердите сводку параметров  
6. При запросе новой версии telemt — ответьте **`y`**  
7. После установки скопируйте **сервер** и **секрет** для @MTProxybot (для standalone и node)

**Одиночный прокси** (роль 1): домен → version picker → подтверждение.

**Нода кластера** (роль 2): кластерный домен → домен/IP маски → SECRET (вручную или по SSH с master) → version picker → подтверждение.

**Master + LB** (роль 3): кластерный домен (A-запись на этот сервер) → добавить ноды сейчас или позже → подтверждение.

Открыть меню позже:

```bash
sudo tg
```

### 5.2 Автоматически (одной командой)

Минимум — только домен:

```bash
sudo bash install.sh --domain proxy.example.com --yes
```

С `ad_tag` из @MTProxybot:

```bash
sudo bash install.sh \
  --domain proxy.example.com \
  --ad-tag 13ea0123456789abcdef0123456789ab \
  --yes
```

С фиксированной версией telemt:

```bash
sudo bash install.sh \
  --domain proxy.example.com \
  --telemt-version 3.4.23 \
  --yes
```

Полная переустановка поверх существующей:

```bash
sudo bash install.sh --domain proxy.example.com --fresh --yes
```

### 5.3 Кластер / мульти-прокси (CLI)

Несколько telemt-нод за одним доменом и **одной** `tg://proxy`-ссылкой. HAProxy балансирует нагрузку.

**Master + LB** (рекомендуется в v2.9 — один VPS для HAProxy и управления):

```bash
sudo bash install.sh --role=master-lb --cluster-domain proxy.example.com \
  --node node1:203.0.113.10:443 --node node2:203.0.113.11:443 --yes
```

**Нода** на каждом backend-VPS:

```bash
sudo bash install.sh --role=node --domain mask1.example.com \
  --cluster-domain proxy.example.com --cluster-secret HEX --fresh --yes
```

Legacy-роли `--role=master` и `--role=lb` сохранены для обратной совместимости.

Интерактивно: меню **1)** → роль **2)** или **3)**. Управление кластером: меню **12)**.

---

## 6. Настройка @MTProxybot

После установки скрипт покажет:

- **Сервер:** `ваш-домен:443`
- **Секрет:** 32-символьный hex
- **Ссылку** (если API telemt уже отвечает)

В Telegram:

1. Откройте [@MTProxybot](https://t.me/MTProxybot)  
2. `/newproxy` → отправьте **сервер** и **секрет** (не ссылку от бота)  
3. `/myproxies` → Set promotion → укажите публичный канал  
4. Скопируйте `ad_tag` и примените:

```bash
sudo tg
# пункт 5 — Настройки прокси
```

или при установке:

```bash
sudo bash install.sh --domain proxy.example.com --ad-tag ВАШ_AD_TAG --yes
```

---

## 7. Проверка после установки

Статус:

```bash
sudo tg
# или
sudo bash install.sh --status
```

Ручная диагностика:

```bash
systemctl is-active telemt nginx mtpr-synfix
ss -tlnp | grep ':443 '
curl -fsS http://127.0.0.1:9091/v1/users | jq .
curl -sk "https://proxy.example.com/" \
  --resolve "proxy.example.com:443:127.0.0.1" \
  -o /dev/null -w 'HTTP %{http_code}\n'
sudo iptables -L MTPR_SYNFIX -n -v
sudo ufw status verbose
```

Ожидается:

- `telemt`, `nginx`, `mtpr-synfix` — **active**
- telemt слушает **443**
- mask-site отвечает **HTTP 200**
- цепочка **MTPR_SYNFIX** в iptables присутствует

---

## 8. Управление после установки

| Действие | Команда |
|----------|---------|
| Меню управления | `sudo tg` |
| Статус | `sudo bash install.sh --status` |
| Обновить telemt | `sudo tg` → пункт **10** |
| Обновить MEKO fix | `sudo bash install.sh --meko-upgrade` |
| Проверки | `sudo tg` → пункт **9** |
| Удалить стек | `sudo bash install.sh --uninstall` |

---

## 9. Обновление скрипта из Git

Если репозиторий уже клонирован:

```bash
cd /root/tg
git pull origin main
```

Затем при необходимости:

```bash
# обновить MEKO SYN FIX до версии из репозитория
sudo bash install.sh --meko-upgrade

# поставить команду tg, если её ещё нет
sudo bash install.sh --keep
```

Проверка после обновления файлов:

```bash
bash tests/smoke.sh
bash tests/role_wizard_smoke.sh
```

---

## 10. Файлы на сервере

| Путь | Назначение |
|------|------------|
| `/root/tg/` | Клон репозитория со скриптами |
| `/usr/local/bin/tg` | Команда меню управления |
| `/etc/telemt-deploy.conf` | Путь к репозиторию для `tg` |
| `/root/telemt-secret.txt` | Секрет MTProxy (сохраняется при переустановке) |
| `/root/telemt-deploy.state` | Состояние установки (домен, ad_tag) |
| `/etc/telemt/telemt.toml` | Конфигурация telemt |
| `/opt/mtpr-simple/version` | Версия MEKO SYN FIX |
| `/etc/letsencrypt/live/DOMAIN/` | SSL-сертификат |

---

## 11. Типовые проблемы

### DNS не совпадает с IP сервера

```bash
dig +short A your-domain.example
curl -fsS ifconfig.me
```

Исправьте `A`-запись у регистратора и подождите распространения DNS (до 24 ч, обычно 5–30 мин).

### Certbot не выдал сертификат

- порт **80** должен быть открыт снаружи;
- DNS должен указывать на этот сервер;
- проверьте: `sudo nginx -t`, `sudo systemctl status nginx`.

### telemt не стартует

```bash
journalctl -u telemt -n 50 --no-pager
sudo ss -tlnp | grep ':443 '
```

### Ошибка «Некорректный домен»

Используйте FQDN без пробелов, например: `sub.domain.example.com`  
Допустимы дефисы в метках: `my-proxy.example.com`.

### Git: Permission denied (publickey)

Добавьте SSH-ключ сервера в GitHub или клонируйте через HTTPS.

---

## 12. Быстрая шпаргалка (copy-paste)

```bash
# 1. Подготовка
apt update && apt install -y git curl

# 2. Клонирование
cd /root
git clone git@github.com:propoker228-png/tg.git
cd tg

# 3. Проверка
bash tests/smoke.sh

# 4. Установка (замените домен)
sudo bash install.sh --domain YOUR_DOMAIN --yes

# 5. Управление
sudo tg
sudo bash install.sh --status
```

---

## Ссылки

- Репозиторий: https://github.com/propoker228-png/tg  
- Подробная документация: [INSTALL_INSTRUCTIONS.md](INSTALL_INSTRUCTIONS.md)  
- Краткий обзор: [README.md](README.md)
