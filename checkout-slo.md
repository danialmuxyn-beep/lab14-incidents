# Runbook: CheckoutErrorBudgetFastBurn / CheckoutErrorBudgetSlowBurn

SLO: 99.5 % of checkouts succeed over 30 days (error budget 216 minutes). Burn rate = error ratio / 0.005.

| alert | meaning | severity |
|---|---|---|
| FastBurn | burn rate > 14.4x over 1 h and 5 m: 2 % of the monthly budget is gone in an hour | page |
| SlowBurn | burn rate > 6x over 6 h and 30 m: 5 % of the budget is gone in 6 hours | ticket |

## What to check
1. Prometheus: `checkout:burn_rate:rate5m` and `checkout:error_ratio:rate5m` - is it still burning?
2. Which service returns the errors: `sum by (job, route, status) (rate(http_requests_total{status=~"5.."}[5m]))`.
   `shop` 502 with `payments` 500 means the cause is in payments.
3. Logs: `{service="payments"} | json | level="ERROR" | msg != "request"` and
   `sum by (card) (count_over_time({service="payments"} | json | status >= 500 [10m]))`.
4. Follow one failing request: `{service=~"shop|payments"} |= "<request_id>"`.

## Fix
- Was there a deploy in the last hour? Roll back: `docker compose up -d payments` (payments 1.0.0).
- If payments is down (`TargetDown`): start it, `docker compose start payments`.
- After the rollback the 5 m window drops first and the alert resolves; the 1 h and 6 h windows follow later.
