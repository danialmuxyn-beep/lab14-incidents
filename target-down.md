# Runbook: TargetDown

Fires when `up == 0` for 30 seconds: Prometheus cannot scrape a service. Severity: page.

## What to check
1. Which target: `up == 0` (labels `job` and `instance`).
2. Is the container running: `docker compose ps`; why did it stop: `docker compose logs --tail 50 <service>`.

## Fix
- Start it: `docker compose start <service>` (or `docker compose up -d <service>`).
- If it crashes again after a new release, roll back the release.
- While it is down, checkouts fail with 502 "payments unreachable", so also expect the checkout burn-rate alerts.
