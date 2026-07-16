# telemt-deploy focused repair

**Date:** 2026-07-15
**Status:** Approved for implementation

## Goal

Fix clear behavioral bugs in `telemt-deploy` without running a real install. The installer should keep its current bash module structure while making automation, validation, and verification results more predictable.

## Scope

- Verification failures must be visible to callers instead of always returning success.
- The install flow may continue after a post-install verification warning, but that tolerance must be explicit at the call site.
- `--yes` automation must not wait for interactive confirmation when the latest telemt version is newer than the known baseline.
- CLI flags that require values must fail early with clear errors.
- Domain and `ad_tag` input must be validated before they are used in config rendering or install flow.
- Tests must stay safe: syntax and helper behavior only, with no `apt`, `systemctl`, `ufw`, `iptables`, `certbot`, or writes into system install paths.

## Non-goals

- No real installation test on this server.
- No firewall, nginx, systemd, certbot, or package-manager changes.
- No broad refactor of the interactive menu or deployment architecture.
- No git commit, because `/root/telemt-deploy` is not a git repository.

## Verification

Run:

```bash
bash tests/smoke.sh
bash install.sh --help
```

If helper tests are added, they must be runnable without root and without touching live services.
