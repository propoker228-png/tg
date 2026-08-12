# Obfuscated2 (`dd`) — список изменений для telemt-deploy

Документ описывает все изменения для поддержки режима **Obfuscated2** в скрипте развёртывания, включая выводы из продакшена (3–4 с с доменом vs ~20 с с IP).

**Спека:** `docs/superpowers/specs/2026-08-12-obfuscated2-proxy-mode-design.md`  
**MEKO / быстрое подключение:** `docs/superpowers/specs/2026-08-12-meko-fast-connect-design.md`

---

## Кратко

| Параметр | Fake TLS (по умолчанию) | Obfuscated2 |
|----------|-------------------------|-------------|
| `PROXY_MODE` | `tls` | `secure` |
| Префикс ссылки | `ee` | `dd` |
| telemt `secure` / `tls` | `false` / `true` | `true` / `false` |
| Domain hex в secret | да | нет |
| Кластер | да | только `standalone` |
| Рекомендуется | домен | **обязательно домен** (не IP) |

**Рабочая ссылка (пример):**

```
tg://proxy?server=ftp.fsdeath.abrdns.com&port=443&secret=ddf65d93f0d5d1f1b93bbe80232976a6aa
```

---

## 1. Новые файлы

| Файл | Назначение |
|------|------------|
| `lib/proxy_mode.sh` | `PROXY_MODE=tls\|secure`, CLI, интерактивное меню, guard для кластера |
| `lib/meko_stats.sh` | Парсинг REJECT/ACCEPT из iptables MEKO |
| `lib/meko_diag.sh` | A/B benchmark hashlimit (`--meko-benchmark`) |
| `tests/proxy_mode_smoke.sh` | Offline-тесты режима и шаблона |
| `tests/meko_diag_smoke.sh` | Offline-тесты MEKO ratio |

---

## 2. `templates/telemt.toml.tpl`

Параметризовать режимы (вместо hardcode `tls=true`):

```toml
[general.modes]
classic = false
secure = ${MODE_SECURE}
tls = ${MODE_TLS}

[censorship]
tls_domain = "${TELEMT_TLS_DOMAIN}"
mask = true
mask_host = "127.0.0.1"
mask_port = 8444
tls_emulation = ${TLS_EMULATION}
```

**Для `secure` (dd):**

- `MODE_SECURE=true`, `MODE_TLS=false`
- `TLS_EMULATION=true` (см. раздел 7)

---

## 3. `lib/common.sh`

### `render_template()`

```bash
if [ "${PROXY_MODE:-tls}" = "secure" ]; then
  MODE_TLS=false
  MODE_SECURE=true
  TLS_EMULATION=true
else
  MODE_TLS=true
  MODE_SECURE=false
  if install_is_ip_only; then
    TLS_EMULATION=true
  elif [ "${TLS_DOMAIN:-}" != "${DOMAIN:-}" ]; then
    TLS_EMULATION=true
  else
    TLS_EMULATION=false
  fi
fi
export MODE_TLS MODE_SECURE
```

Добавить `${MODE_TLS}` `${MODE_SECURE}` в `envsubst`.

### `fetch_proxy_link()`

Читать ключ API по режиму:

```bash
kind="$(proxy_mode_link_kind 2>/dev/null || echo tls)"   # "secure" | "tls"
# links.${kind}[0]
```

### `save_state()`

Добавить в state-файл:

```bash
PROXY_MODE=${PROXY_MODE:-tls}
```

---

## 4. `lib/link.sh`

`build_proxy_link_fallback()`:

```bash
if proxy_mode_is_secure; then
  printf 'tg://proxy?server=%s&port=443&secret=dd%s' "$domain" "$secret"
else
  # ee + hex домена маскировки
fi
```

---

## 5. `lib/env.sh`

- Загружать `PROXY_MODE` из `/root/telemt-deploy.state` (default `tls`)
- Если `DOMAIN` — валидный IPv4 → `INSTALL_IP_ONLY=1`

---

## 6. `lib/telemt.sh`

В `telemt_write_config()`:

```bash
PROXY_MODE="${PROXY_MODE:-tls}"
export PROXY_MODE
export PUBLIC_HOST="${DOMAIN}"
export TELEMT_TLS_DOMAIN="${TLS_DOMAIN:-$DOMAIN}"
```

---

## 7. Ключевое изменение: `tls_emulation = true` для `dd`

**Было в первой версии спеки:** `tls_emulation=false` для secure.

**После продакшена:** для Obfuscated2 всегда `TLS_EMULATION=true`.

Причина: на порту 443 без TLS-камуфляжа DPI режет MTProto-handshake → ~20 с таймаутов в telemt (`Connection timed out`). С доменом + LE + `tls_emulation=true` — **3–4 с**.

---

## 8. `install.sh`

```bash
PROXY_MODE="tls"
PROXY_MODE_CLI=""

# в цикле аргументов:
--proxy-mode) PROXY_MODE_CLI=$(require_arg_value "$1" "${2:-}"); normalize_proxy_mode "$PROXY_MODE_CLI"; shift 2 ;;

# модули (после common):
for mod in proxy_mode prereq dns nginx ...; do

# после разбора --role:
proxy_mode_force_tls_for_cluster
export PROXY_MODE
```

Help:

```
--proxy-mode MODE    tls (Fake TLS, default) | secure (Obfuscated2/dd); только standalone
```

**Пример установки:**

```bash
sudo bash install.sh \
  --domain ftp.fsdeath.abrdns.com \
  --proxy-mode=secure \
  --yes
```

**Не использовать для dd:**

```bash
# Плохо — ~20 с подключения
sudo bash install.sh --ip-only --tls-domain android.clients.google.com --proxy-mode=secure --yes
```

---

## 9. `lib/proxy_mode.sh` (новый модуль)

Функции:

| Функция | Описание |
|---------|----------|
| `normalize_proxy_mode(raw)` | `tls`/`ee`/`secure`/`dd`/`obfuscated2` |
| `proxy_mode_is_secure()` | test `PROXY_MODE=secure` |
| `proxy_mode_label()` | `Obfuscated2 (dd)` / `Fake TLS (ee)` |
| `proxy_mode_link_kind()` | `secure` / `tls` для API |
| `pick_proxy_mode()` | Меню 1/2, только standalone |
| `proxy_mode_force_tls_for_cluster()` | node/lb/master → force `tls` + warn |

Интерактивное меню:

```
=== Режим прокси ===
  1) Fake TLS (ee) — рекомендуется, маскировка под HTTPS
  2) Obfuscated2 (dd) — random padding; рекомендуется свой домен
```

---

## 10. `lib/version_picker.sh`

В `prepare_install_options()` — **до** выбора версий:

```bash
pick_proxy_mode
```

---

## 11. UI и документация

| Файл | Изменение |
|------|-----------|
| `lib/ui_highlight.sh` | Строка `Режим: Obfuscated2 (dd)` в summary |
| `lib/role_wizard.sh` | То же для standalone |
| `README.md` | `--proxy-mode`, пример secure, раздел «медленное подключение» |
| `DEPLOY.md` | Секция Obfuscated2, миграция IP→домен |

---

## 12. MEKO SYN FIX (для Obfuscated2)

Работает на уровне TCP — **режим `dd`/`ee` не важен**. Обязателен на 443.

| Файл | Изменение |
|------|-----------|
| `templates/apply-mtpr-synfix.sh` | v3.0.2, `MEKO_HASHLIMIT_RATE` / `MEKO_HASHLIMIT_BURST` |
| `templates/mtpr-synfix.service` | `EnvironmentFile=-/etc/default/mtpr-synfix` |
| `lib/meko.sh` | v1.4, bundled 3.0.2, export burst при install |
| `lib/doctor.sh` | `doctor_check_meko_syn_ratio()` |
| `lib/meko_diag.sh` | `--meko-benchmark` |
| `lib/prereq.sh` | `setup_meko_sysctl()` |

**Правила:**

- Default: `burst=1`, `54/minute`
- **Не** ставить `burst=3` без A/B теста с клиентской сети — риск блокировки DPI (~30 с)
- Откат burst: `sudo rm -f /etc/default/mtpr-synfix && sudo bash install.sh --meko-upgrade`

---

## 13. Поведение по сценариям

| Сценарий | Результат |
|----------|-----------|
| `secure` + домен + LE + MEKO | ~3–4 с (рекомендуется) |
| `secure` + IP (`--ip-only`) | ~15–20 с |
| `secure` + `burst=3` | Может стать хуже (~30 с) |
| Кластер + `--proxy-mode=secure` | Принудительно `tls` |
| Смена `ee`→`dd` без `--fresh` | Не поддерживается |
| Ссылка | `dd` + 32 hex, **без** hex домена |

---

## 14. Итоговая матрица `telemt.toml` (Obfuscated2)

| Параметр | Значение |
|----------|----------|
| `[general.modes].secure` | `true` |
| `[general.modes].tls` | `false` |
| `[general.links].public_host` | домен (не IP) |
| `[censorship].tls_domain` | домен |
| `[censorship].tls_emulation` | **`true`** |
| `[censorship].mask` | `true` |
| nginx + certbot | полный стек |
| MEKO | inline v3.0.2+, burst=1 |

---

## 15. Рекомендуемые доработки (ещё не в коде)

### 15.1 Предупреждение `--ip-only` + `secure`

В `install.sh` или `pick_proxy_mode()`:

```bash
if install_is_ip_only && [ "${PROXY_MODE}" = "secure" ]; then
  log_warn "Obfuscated2 (dd) по IP часто даёт задержку 15–20 с. Используйте свой домен."
fi
```

### 15.2 Предупреждение в `doctor`

```bash
if proxy_mode_is_secure && install_is_ip_only; then
  doctor_record "Режим dd" warn "IP-only — медленное подключение; используйте домен"
fi
```

### 15.3 Миграция IP → домен

Секрет сохраняется в `/root/telemt-secret.txt`:

```bash
sudo bash install.sh --fresh \
  --domain your.domain.com \
  --proxy-mode=secure \
  --yes
```

Или вручную (без полного uninstall):

```bash
export DOMAIN=your.domain.com TLS_DOMAIN=your.domain.com
export INSTALL_IP_ONLY=0 PROXY_MODE=secure
export SECRET=$(cat /root/telemt-secret.txt)
# nginx temp → certbot → nginx production → telemt_write_config → meko → save_state
```

---

## 16. Чеклист файлов для коммита

```
lib/proxy_mode.sh              [NEW]
lib/meko_stats.sh              [NEW]
lib/meko_diag.sh               [NEW]
lib/common.sh                  [MODIFY]  render_template, fetch_proxy_link, save_state
lib/link.sh                    [MODIFY]  build_proxy_link_fallback
lib/env.sh                     [MODIFY]  PROXY_MODE в state
lib/telemt.sh                  [MODIFY]  telemt_write_config
lib/doctor.sh                  [MODIFY]  doctor_check_meko_syn_ratio
lib/meko.sh                    [MODIFY]  v3.0.2, hashlimit env
lib/prereq.sh                  [MODIFY]  setup_meko_sysctl
lib/menu.sh                    [MODIFY]  benchmark, sysctl
lib/version_picker.sh          [MODIFY]  pick_proxy_mode
lib/ui_highlight.sh            [MODIFY]  summary line
lib/role_wizard.sh             [MODIFY]  summary line
install.sh                     [MODIFY]  --proxy-mode, meko_diag module
templates/telemt.toml.tpl      [MODIFY]  MODE_SECURE, MODE_TLS
templates/apply-mtpr-synfix.sh [MODIFY]  parameterized hashlimit
templates/mtpr-synfix.service  [MODIFY]  EnvironmentFile
tests/proxy_mode_smoke.sh      [NEW]
tests/meko_diag_smoke.sh       [NEW]
tests/smoke.sh                 [MODIFY]
README.md                      [MODIFY]
DEPLOY.md                      [MODIFY]
docs/OBFUSCATED2-CHANGELOG.md  [NEW]  ← этот файл
```

---

## 17. Команды проверки после внедрения

```bash
# Offline-тесты
bash tests/proxy_mode_smoke.sh
bash tests/meko_diag_smoke.sh
bash tests/smoke.sh

# На сервере
sudo bash install.sh --doctor
sudo bash install.sh --meko-benchmark   # опционально
sudo tg link                            # secret должен начинаться с dd
```

**Критерий успеха:** подключение с любого устройства за **< 5 с** (цель 3 с) при домене и `PROXY_MODE=secure`.

---

*Сгенерировано: 2026-08-12. Продакшен-проверка: `ftp.fsdeath.abrdns.com`, telemt 3.4.25, MEKO 3.0.2.*
