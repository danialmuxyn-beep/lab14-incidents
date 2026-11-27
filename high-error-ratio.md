# Runbook: HighErrorRatio

Fires when more than 5 % of the requests of one service (`job`) return 5xx over 5 minutes, with traffic above 0.2 req/s,
for 2 minutes. Severity: ticket.

## What to check
1. Which service and route: `sum by (job, route, status) (rate(http_requests_total{status=~"5.."}[5m]))`.
2. Why: `{service="<job>"} | json | status >= 500` and `{service="<job>"} | json | level="ERROR" | msg != "request"`.
3. Does it start at a deploy? Compare with the `version` field in the logs.

## Fix
- Roll back the last release of the failing service: `docker compose up -d payments`.
- If the cause is in a dependency, fix or roll back the dependency (the shop answers 502 when payments answers 500).
