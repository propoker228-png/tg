# telemt-deploy Interactive Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить главное интерактивное меню в `install.sh` (п. 1–11 + выход) с разовой статистикой и live-мониторингом, сохранив CLI-флаги для автоматизации.

**Architecture:** `install.sh` становится роутером; новые модули `lib/menu.sh`, `lib/monitor.sh`, `lib/dialog.sh` оркестрируют существующие `lib/*.sh`. Меню — текст + `dialog` для опасных действий. Шапка переиспользует `lib/stats.sh` (MEKO-подсчёт).

**Tech Stack:** Bash 5.x, Ubuntu 22.04/24.04, telemt API :9091, optional `dialog`, python3, curl, systemctl.

**Spec:** `docs/superpowers/specs/2026-07-14-telemt-deploy-interactive-menu-design.md`

---

### Task 1: Dialog wrapper + prereq

**Files:**
- Create: `lib/dialog.sh`
- Modify: `lib/prereq.sh`
- Modify: `install.sh` (source dialog in mod list)

- [ ] **Step 1: Create `lib/dialog.sh`**

```bash
#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DIALOG_SH_VERSION="1.0"

has_dialog() {
  command -v dialog >/dev/null 2>&1
}

confirm_dialog() {
  local prompt="${1:-Продолжить?}"
  if has_dialog; then
    dialog --yesno "$prompt" 10 70
    return $?
  fi
  confirm_yes "$prompt"
}
```

- [ ] **Step 2: Add optional dialog to prereq**

In `lib/prereq.sh` `install_packages()`, add `dialog` to apt-get list (after `gettext-base`).

- [ ] **Step 3: Source dialog in install.sh mod loop**

Add `dialog` before `menu` in: `for mod in ... dialog stats ... menu`

- [ ] **Step 4: Syntax check**

Run: `bash -n lib/dialog.sh && bash tests/smoke.sh`  
Expected: `ALL SYNTAX OK`

---

### Task 2: Extend stats for menu header

**Files:**
- Modify: `lib/stats.sh`

- [ ] **Step 1: Add `render_menu_header()`**

Функция выводит блок:
- installer version (arg `$1`)
- domain:443
- telemt version
- `${YELLOW}${people}${NC} человек`
- TCP count
- telemt/nginx/mtpr-synfix OK or FAIL

Использует `fetch_proxy_online_people`, `fetch_proxy_connections_total`, `env_load_settings`.

- [ ] **Step 2: Add `show_stats_snapshot()`**

Разовый экран: header + список IP из `active-ips` JSON (python3 или grep), ссылка из `fetch_proxy_link`, `read -r _ </dev/tty` пауза.

- [ ] **Step 3: Bump `STATS_SH_VERSION` to `2.4.0`**

- [ ] **Step 4: Manual test on server**

Run: `sudo bash install.sh --status`  
Expected: header format with yellow people count

---

### Task 3: Live monitor module

**Files:**
- Create: `lib/monitor.sh`

- [ ] **Step 1: Create `lib/monitor.sh`**

```bash
#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MONITOR_SH_VERSION="1.0"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-4}"

run_live_monitor() {
  local key=""
  while true; do
    clear
    render_menu_header "${INSTALLER_VERSION:-2.4}"
    echo "  Обновление каждые ${MONITOR_INTERVAL}s | q или 0 = выход"
    echo ""
    if read -rsn1 -t "$MONITOR_INTERVAL" key </dev/tty 2>/dev/null; then
      case "$key" in
        q|Q|0) break ;;
      esac
    fi
  done
  clear
}
```

- [ ] **Step 2: Handle Ctrl+C**

Wrap loop: `trap 'clear; break' INT` or restore on exit.

- [ ] **Step 3: Syntax check**

Run: `bash -n lib/monitor.sh`

---

### Task 4: Extract install flow from install.sh

**Files:**
- Modify: `install.sh`
- Create: `lib/install_flow.sh` (or add to `lib/menu.sh` — предпочтительно отдельный файл)

- [ ] **Step 1: Create `lib/install_flow.sh` with `run_install_flow()`**

Перенести из `install.sh` строки после `validate_domain_dns` до `save_state` + `show_proxy_online_stats` + `log_ok` в функцию `run_install_flow()` без дублирования.

- [ ] **Step 2: install.sh flags path calls `run_install_flow`**

Интерактивный п.1 меню тоже вызывает `run_install_flow`.

- [ ] **Step 3: Verify `--domain X --yes` still works**

---

### Task 5: Main menu module

**Files:**
- Create: `lib/menu.sh`
- Modify: `install.sh`

- [ ] **Step 1: Create `main_menu()` loop in `lib/menu.sh`**

```bash
MENU_SH_VERSION="1.0"

main_menu() {
  local choice=""
  while true; do
    clear
    render_menu_header "${INSTALLER_VERSION:-2.4}"
    echo "  1) Установка / переустановка"
  # ... 2-11, 0
    prompt_line choice "Выбор" ""
    case "$choice" in
      1) menu_install ;;
      2) menu_stats_snapshot ;;
      3) run_live_monitor ;;
      4) menu_services ;;
      5) menu_proxy_settings ;;
      6) menu_ssl ;;
      7) menu_meko ;;
      8) menu_firewall ;;
      9) menu_verify ;;
      10) menu_upgrade_telemt ;;
      11) menu_uninstall ;;
      0|q|Q) break ;;
      *) log_warn "Неверный выбор" ; sleep 1 ;;
    esac
  done
}
```

- [ ] **Step 2: Implement stub submenus calling existing libs**

| Функция | Делегирует |
|---------|------------|
| `menu_install` | `handle_existing_env` + `run_install_flow` |
| `menu_stats_snapshot` | `show_stats_snapshot` |
| `menu_services` | systemctl + journalctl |
| `menu_proxy_settings` | handoff + `prompt_ad_tag` + `telemt_write_config` |
| `menu_ssl` | `ssl_obtain_cert` info / certbot renew |
| `menu_meko` | `meko_install_inline` status |
| `menu_firewall` | `firewall_setup` + ufw status |
| `menu_verify` | `verify_install` |
| `menu_upgrade_telemt` | `telemt_install_binary` |
| `menu_uninstall` | `confirm_dialog` + `uninstall_all` |

- [ ] **Step 3: `require_installed()` guard**

Для п.2–10: если нет `/bin/telemt`, показать предупреждение и return.

- [ ] **Step 4: Wire install.sh**

После `require_ubuntu`, если нет action-флагов и `[ -t 0 ]`:
```bash
set +e
main_menu
exit 0
```

---

### Task 6: Routing and version bump

**Files:**
- Modify: `install.sh`
- Modify: `lib/common.sh` (optional `is_interactive_menu()` helper)

- [ ] **Step 1: Add `has_action_flags()` helper in install.sh**

Returns true if any of: UNINSTALL, STATUS, FRESH, KEEP, DOMAIN set, AD_TAG set, TELEMT_VERSION, MEKO_FULL, YES (only YES alone does NOT bypass menu — YES without other flags stays in menu).

- [ ] **Step 2: Non-TTY guard**

If no action flags and not `[ -t 0 ]`: die with help text.

- [ ] **Step 3: Bump `INSTALLER_VERSION` to `2.4`**

Update `require_lib_bundle` checks for MENU_SH_VERSION, MONITOR_SH_VERSION, STATS 2.4.0.

- [ ] **Step 4: Update help text in install.sh header**

Document: без флагов → меню.

---

### Task 7: Tests and docs

**Files:**
- Modify: `tests/smoke.sh`
- Modify: `README.md` (краткая секция «Интерактивное меню»)

- [ ] **Step 1: smoke.sh includes new libs**

- [ ] **Step 2: README — пример `sudo bash install.sh`**

- [ ] **Step 3: Full manual checklist**

- [ ] `install.sh` → menu appears  
- [ ] п.2 stats, п.3 live exit with q  
- [ ] п.11 uninstall with confirm  
- [ ] `install.sh --status` bypasses menu  
- [ ] `install.sh --domain x --yes` bypasses menu  

---

## Spec Coverage Checklist

| Spec requirement | Task |
|------------------|------|
| install.sh без флагов → меню | Task 5, 6 |
| Флаги обходят меню | Task 6 |
| Пункты 1–11 + 0 | Task 5 |
| Статистика разово + live | Task 2, 3 |
| MEKO подсчёт + жёлтый | Task 2 |
| dialog hybrid | Task 1 |
| Переиспользование lib/*.sh | Task 4, 5 |
| Guards без установки | Task 5 |
| INSTALLER 2.4 | Task 6 |

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-14-telemt-deploy-interactive-menu.md`.

**Two execution options:**

1. **Subagent-Driven** — отдельный subagent на каждый Task, ревью между задачами  
2. **Inline Execution** — реализация в этой сессии по Task 1→7 с чекпоинтами  

Какой вариант выбираете?
