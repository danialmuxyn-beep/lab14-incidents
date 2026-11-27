# Postmortem - payments 1.1.0: unionpay failures and a short outage

Blameless: this document explains how the system allowed the problem, not who caused it. All times are UTC, 2026-11-27.

## Summary

Release 1.1.0 of the payments service started to answer HTTP 500 to every `unionpay` payment (new client does not support
the currency KZT), so about 10 % of checkouts failed with 502 in the shop for about 22 minutes until the rollback.
During this time `payments` was also stopped for about 2 minutes (a full outage of checkout). The alerts worked, but the old
alert (`ErrorsDetected`) was noise and the new burn-rate alert needed a long window to react.

## Impact

- **Who:** customers paying with `unionpay` (about 10 % of checkouts) from 00:41:24 to 01:03:46; all customers who checked out
  between 00:56:35 and 00:58:45 (payments stopped, shop answered "payments unreachable").
- **Duration:** 22 min 22 s of unionpay failures; 2 min 10 s of full checkout outage.
- **Failed checkouts** (PromQL, evaluated for the 25 minutes around the run):

  ```
  sum(increase(http_requests_total{job="shop",route="/api/checkout",status=~"5.."}[25m]))
  ```

  The exact count was not collected before the lab session ended (the server was powered off).
- **Error budget (99.5 % over 30 days = 216 min):** the burn rate was 15.3x at 00:47 and at least 22.4x at 01:07
  (values from the alert summaries). One hour at burn rate b uses b / 720 of the 30-day budget, so one hour at 15-22x
  uses about **2-3 %** of the monthly error budget. This comes on top of the first 1.1.0 period (23:32:20 - 00:26:14),
  where the burn rate was about 15-18x for over 50 minutes.

## Timeline (UTC)

| time | event | evidence |
|---|---|---|
| 00:41:24 | deploy payments 1.1.0 | `final-run-times.log` |
| 00:41:24+ | first errors: every `unionpay` payment returns 500, the shop returns 502 | LogQL `{service="shop"} \| json \| status=502` |
| **00:47:13** | **first alert:** `HighErrorRatio` payments, 10.4 % of requests are 5xx -> `/tickets` | webhook log |
| **00:47:18** | **first useful alert / page:** `CheckoutErrorBudgetFastBurn`, burn rate 15.3x -> `/pager` | webhook log, `ALERTS` in Prometheus |
| 00:56:35 | payments stopped (outage starts) | `final-run-times.log` |
| 00:57:53 | `TargetDown` payments -> `/pager` (78 s after the stop) | webhook log |
| 00:58:45 | payments started again (still 1.1.0) | `final-run-times.log` |
| 00:59:28 | `HighErrorRatio` for `shop`, 17.09 % of requests are 5xx | webhook log |
| 01:02:53 | `TargetDown` RESOLVED | webhook log |
| 01:03:46 | rollback to 1.0.0 | `final-run-times.log` |
| 01:04:28 | `HighErrorRatio` shop RESOLVED | webhook log |
| 01:07:13 / 01:07:18 | `HighErrorRatio` payments and `CheckoutErrorBudgetFastBurn` RESOLVED | webhook log |
| 01:31:53 | `CheckoutErrorBudgetSlowBurn` RESOLVED (6 h window) | webhook log |

A restart of payments is also visible in `changes(process_start_time_seconds{job="payments"}[1h])`.

Note: the fast-burn alert fired only 5 s after the first ticket because the 1-hour window still contained the errors of the
first 1.1.0 period (23:32 - 00:26). With a clean history it needs about 43 minutes to fire (see Task 2 in `REPORT.md`:
in the first run it fired 43 min 40 s after the deploy, at 00:16:00).

## Detection

- **Told us first:** `HighErrorRatio` for `payments` (ticket) and `CheckoutErrorBudgetFastBurn` (page) within 6 seconds of each
  other, about 5 minutes after the deploy.
- **First useful alert:** `HighErrorRatio` names the service and the number (`payments: 10.4 %`), the burn-rate page says that
  the checkout SLO is being burnt.
- **Noise (old config):** `ErrorsDetected` sent 41 notifications in 15 minutes for one real problem and 14 in 15 minutes when
  everything was healthy, all with `severity: page`. With the new rules the same two periods give 0 and 2 notifications.
- **Outage:** `TargetDown` paged after 78 s (30 s `for:` + scrape and group wait). That is acceptable for a service that
  is stopped, but the shop showed 502 for the whole time.

## Root cause

In `payments` 1.1.0 the new unionpay client does not support the currency KZT, so every `unionpay` payment fails:

```
{service="payments"} | json | level="ERROR" | msg != "request"
-> "currency KZT not supported by the new unionpay client"
```

```
{service=~"shop|payments"} |= "962e6c8a34964aa4"
-> payments status 500 (/api/pay)  +  shop status 502 (/api/checkout, upstream_status 500)
```

The shop answers 502 when payments answers 500 because the shop is a gateway: it reports "payment failed" for an upstream
error. The metric `sum by (job, route, status) (rate(http_requests_total{status=~"5.."}[5m]))` shows 500 on `payments`
(cause) and 502 on `shop` `/api/checkout` (what users see). The code path is `VERSION == "1.1.0" and card == "unionpay"` in `app.py`.

The system allowed it because there was no test for the `unionpay` + KZT case before release, and the new version went to 100 %
of the traffic at once, with no canary, so the first signal was real customers.

Another finding from the logs: version 1.1.0 also logs the full `card_number` (16 digits) in the payments request line.
That must never be logged (see the action items).

## What went well

- The shop passes `X-Request-ID` to payments, so one LogQL query shows a failing checkout in both services.
- The burn-rate alerts and `TargetDown` fired and were routed by severity (`/pager` and `/tickets`).
- Rollback to 1.0.0 was one command, and the alerts resolved by themselves after it.
- The new alert rules removed the repeated notifications (0 and 2 instead of 14 and 41).

## What went badly

- A bad version reached all traffic at once, with no canary and no test for the unionpay case.
- The old `ErrorsDetected` alert was muted by everybody, so a real incident would be hidden in the noise.
- The fast-burn page needs a long time (about 43 minutes from a clean state) when errors are "only" 10 %.
- Full card numbers were written to the logs by 1.1.0.

## Action items

| # | action | owner | type |
|---|---|---|---|
| 1 | Add a test for each card type and currency (unionpay + KZT) to the payments CI, so this release does not build | Danial | prevent |
| 2 | Release payments with a canary (a small share of traffic first) and promote only if the error ratio stays low | Danial | prevent |
| 3 | Remove `card_number` from the logs, keep at most the last 4 digits, and check for 16-digit numbers in CI | Danial | prevent |
| 4 | Keep `HighErrorRatio` (per service, ratio, `for:`) and add a short-window page, for example 5 m burn rate above 14.4x with a 2 m `for:`, to catch a sudden 10 % failure sooner | Danial | detect |
| 5 | Roll back automatically when the fast-burn alert fires right after a deploy | Danial | mitigate |
| 6 | Add a `TargetDown` runbook step "start the service or roll back" and a 2-minute stop test in the deploy checklist | Danial | mitigate |
