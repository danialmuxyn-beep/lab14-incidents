# Lab 14 - Observability: incidents, alerts, SLOs and logs

Variant A. Stack: ShopLab (shop, payments, traffic, Prometheus, Alertmanager, Loki, Alloy, Grafana), run with
`docker compose` on an AWS EC2 instance (Ubuntu 24.04, t3.medium). CloudShell could not be used: its Docker uses
the `vfs` storage driver, which copies every image layer in full, and the 16 GB disk ran out.

Stack started: 2026-11-26 23:11:10 UTC (payments 1.0.0). All times below are UTC.

Screenshots are in `screenshots/` (Prometheus tables and graphs, Grafana Explore, terminal output of the webhook log).

---

## Task 1 - "Search is slow"

### PromQL

p50 per route:

```
histogram_quantile(0.5, sum by (route, le) (rate(http_request_duration_seconds_bucket{job="shop"}[5m])))
```

p95 per route:

```
histogram_quantile(0.95, sum by (route, le) (rate(http_request_duration_seconds_bucket{job="shop"}[5m])))
```

Average per route:

```
sum by (route) (rate(http_request_duration_seconds_sum{job="shop"}[5m]))
/ sum by (route) (rate(http_request_duration_seconds_count{job="shop"}[5m]))
```

Share of `/api/search` slower than 0.5 s (uses the `le="0.5"` bucket):

```
1 - (sum(rate(http_request_duration_seconds_bucket{job="shop",route="/api/search",le="0.5"}[5m]))
/ sum(rate(http_request_duration_seconds_count{job="shop",route="/api/search"}[5m])))
```

| route | p50 | average | p95 |
|---|---|---|---|
| /api/search | 0.041 s | 0.162 s | **1.74 s** |
| /api/checkout | 0.064 s | 0.059 s | 0.096 s |

Share of `/api/search` slower than 0.5 s: **0.110 (about 11 %)**.

The slow route is `/api/search`. Its p50 and average look healthy, but its p95 is 1.74 s.

### LogQL

```
{service="shop"} | json | path="/api/search" and duration_ms > 500
```

```
{service="shop"} | json | path="/api/search" | duration_ms > 500 | line_format "{{.duration_ms}}ms q={{.query}}"
```

Bonus - one LogQL metric query that proves the pattern:

```
avg by (long) (avg_over_time({service="shop"} | json | path="/api/search"
  | label_format long=`{{ if gt (len .query) 20 }}yes{{ else }}no{{ end }}`
  | unwrap duration_ms [5m]))
```

In 15 minutes Loki returned 203 slow searches (1000-1400 ms). All of them have a query of 5-6 words
(for example `chair tea chair tea phone kazakh`), i.e. longer than 20 characters. The bonus query gives two clearly
separated lines: `long="yes"` stays at about 1.2 s, `long="no"` stays near zero.

**Pattern: a search is slow if and only if its query text is longer than 20 characters.** Only after finding this
with metrics and logs I opened `app.py` and confirmed it (`if len(q) > 20: time.sleep(random.uniform(0.9, 1.4))`).

### Explain

**Why does the average look fine while some users wait more than a second?** The average mixes all requests. About
89 % of searches take 20-60 ms and about 11 % take over a second, so the fast majority dominates the average (162 ms).
The p50 only looks at the middle request. A tail percentile (p95) shows what the slowest users see (1.74 s).

**Why do you need both metrics and logs to answer "why"?** Metrics are cheap and aggregated: they say *where* (which
route), *when* and *how bad* (p95, 11 %), but have no per-request detail. Logs keep every request with its fields
(`duration_ms`, `query`), so they say *what* the slow requests have in common. Metrics point to the problem, logs
explain it, and only then is it worth reading the code.

---

## Task 2 - An SLO for checkout, and a burn-rate alert

SLO: 99.5 % of checkouts succeed over 30 days.

**Error budget:** 30 days x 24 h x 60 min = 43,200 min. 0.5 % of 43,200 = **216 minutes** of "fully down".

Recording rules (`monitoring/rules.yml`): `checkout:error_ratio:rate5m / rate30m / rate1h / rate6h`, for example

```
(sum(rate(http_requests_total{job="shop",route="/api/checkout",status=~"5.."}[1h])) or vector(0))
/ sum(rate(http_requests_total{job="shop",route="/api/checkout"}[1h]))
```

and `checkout:burn_rate:rate*` = error ratio / 0.005.

Alerts:

| alert | condition | severity |
|---|---|---|
| CheckoutErrorBudgetFastBurn | burn rate 1h > 14.4 **and** 5m > 14.4, for 1m | page |
| CheckoutErrorBudgetSlowBurn | burn rate 6h > 6 **and** 30m > 6, for 5m | ticket |

Both have a summary with the burn rate and a `runbook_url` (`runbooks/checkout-slo.md`).

Query used to look at the state:

```
sum(rate(http_requests_total{job="shop",route="/api/checkout",status=~"5.."}[1h]))
/ sum(rate(http_requests_total{job="shop",route="/api/checkout"}[1h]))
```

```
ALERTS{alertname=~"Checkout.*"}
```

**Result.** payments 1.1.0 was deployed at 23:32:20 and left running. From the webhook log (`docker compose logs -t webhook`):

| time | alert | value | sent to |
|---|---|---|---|
| 00:05:03 | CheckoutErrorBudgetSlowBurn FIRING | burn rate 11.8x | /tickets |
| **00:16:00** | **CheckoutErrorBudgetFastBurn FIRING** | **burn rate 14.7x** | **/pager** |

`checkout:burn_rate:rate1h` read 15.06 at one later check. The fast-burn alert fired 43 min 40 s after the deploy.

### Explain

**Why alert on the burn rate instead of "error ratio > 0.5 %"?** A ratio above 0.5 % for one minute spends almost nothing
of a 30-day budget, but it would still page; and a ratio of 0.6 % for a whole month is a breach, but it is not urgent
at any given moment. The burn rate says how fast the budget is being used: 14.4x means 2 % of the monthly budget is gone
in one hour (the budget would last about 2 days), 6x means 5 % in six hours. It ties the page to the business impact
and to urgency.

**Why two windows per alert?** The long window (1 h / 6 h) makes sure that a significant part of the budget is really
spent, so short blips do not page. The short window (5 m / 30 m) makes sure the problem is still happening, so the
alert resets quickly after a fix instead of staying red for an hour.

**Why did the fast-burn alert not fire right after the deploy, although the error ratio jumped at once?** After the
deploy about 10 % of checkouts failed (all `unionpay` payments), a burn rate of about 20x. But the 1-hour window averages the
new bad minutes with the healthy past. To pull a 1-hour average above 7.2 % (= 14.4 x 0.5 %) with 10 % errors takes
about 0.072 / 0.10 x 60 = 43 minutes. This is what we saw: 43 min 40 s. The 5-minute window reacts within minutes, but
both conditions must be true. The slow-burn alert fired earlier (00:05) only because Prometheus had less than 6 h of
history in this lab, so its "6 h" window was in fact shorter.

---

## Task 3 - The noisy alert

### Before (starter config)

Count of `[FIRING]` notifications in the webhook log (`docker compose logs --no-log-prefix -t webhook`, then
`awk` by time window and `grep -c FIRING`):

| window | payments | notifications |
|---|---|---|
| 23:17:20 - 23:32:20 | 1.0.0 | **14** |
| 23:32:20 - 23:47:20 | 1.1.0 | **41** (15 for `/api/checkout`, 15 for `/api/pay`, 11 for `/api/search`) |

All of them were `ErrorsDetected` with `severity: page`, repeated every minute. At 1.0.0 nothing needed a human: they are
the random 0.5 % `500` errors of the search. At 1.1.0 only one thing needed a human (the unionpay failures), but it
arrived as 41 identical pages, with the 11 search ones being pure noise.

### The fix

`ErrorsDetected` was replaced with `HighErrorRatio` (`monitoring/rules.yml`):

```
(sum by (job) (rate(http_requests_total{status=~"5.."}[5m])) / sum by (job) (rate(http_requests_total[5m]))) > 0.05
and
sum by (job) (rate(http_requests_total[5m])) > 0.2
```

`for: 2m`, per service (`job`), summary with the number (`payments: 9.635% of requests return 5xx ...`), `runbook_url`
(`runbooks/high-error-ratio.md`), `severity: ticket`. The page now comes only from the burn-rate and TargetDown alerts.

`monitoring/alertmanager.yml`: `group_by: [alertname, job]`, `group_wait: 30s`, `group_interval: 5m`,
`repeat_interval: 4h` (1h for pages), two receivers (`/pager` for `severity=page`, `/tickets` for everything else).

### After

Same scenario (15 min on 1.0.0 starting 00:26:14, then 15 min on 1.1.0 starting 00:41:24):

| window | payments | notifications |
|---|---|---|
| 00:26:14 - 00:41:24 | 1.0.0 | **0** |
| 00:41:24 - 00:56:35 | 1.1.0 | **2** (`HighErrorRatio` payments 00:47:13 -> /tickets, `CheckoutErrorBudgetFastBurn` 00:47:18 -> /pager) |

| | before | after |
|---|---|---|
| notifications at 1.0.0 (15 min) | 14 | 0 |
| notifications at 1.1.0 (15 min) | 41 | 2 |
| pages for the real incident | 41 (all pages) | 1 |

### Explain

**What is alert fatigue and why is it dangerous?** When people get many alerts that need no action, they start to
ignore or mute them, as the on-call engineer did here. Then the one real page is missed or read late, so the incident
lasts longer.

**What makes an alert actionable?** It fires on user-visible impact (not on every error), names the service and the
number, fires only when it persists (`for:`) and when there is enough traffic, goes to the right channel by severity,
and links to a runbook that says what to check first.

**Why does a single 500 on `/api/search` not deserve a page?** The service is allowed some errors (here a random 0.5 %);
one error says nothing about the users or the SLO, and nobody can do anything about it. Only a sustained ratio matters.

---

## Task 4 - Follow one checkout across two services

Failing checkouts in the shop log:

```
{service="shop"} | json | status=502
```

(64 lines in 15 minutes after the 1.1.0 deploy). One of them has `request_id` = `962e6c8a34964aa4`. All lines of this request
from both services with one query:

```
{service=~"shop|payments"} |= "962e6c8a34964aa4"
```

It returns 3 lines: the `payments` error `currency KZT not supported by the new unionpay client`, the `payments`
request line (`/api/pay`, status 500) and the `shop` request line (`/api/checkout`, status 502, `upstream_status: 500`).

My own request with a chosen ID:

```
curl -si -X POST localhost:8000/api/checkout -H 'X-Request-ID: lab-danial-1' -H 'Content-Type: application/json' \
  -d '{"card":"unionpay","amount":1000,"card_number":"4000000000000000"}'
```

The answer has `HTTP/1.1 502` and `X-Request-ID: lab-danial-1`, and
`{service=~"shop|payments"} |= "lab-danial-1"` finds the same 3 lines.

**Where the ID is passed on in `app.py`** (in `checkout()`, the call to payments):

```python
headers={"Content-Type": "application/json",
         "X-Request-ID": g.request_id}  # pass it on!
```

If this line were missing, `payments` would not receive the header and would create its own random ID
(`uuid.uuid4().hex[:16]` in `before_request`). Both services would still log, but with different IDs, and
there would be no way to connect the shop's 502 with the payments' 500.

### Explain

**Why is `service` a Loki label but `request_id` is not?** Loki indexes only labels, and every unique combination of label
values makes a separate stream. `service` has a few values (low cardinality). `request_id` is unique for every request, so as a
label it would create millions of tiny streams and ruin the index and performance. It stays in the log line and is found
by a filter (`|= "..."` or `| json | request_id="..."`).

**How does a `request_id` turn logs from two services into one story?** It is the same value in every line that belongs to one
user request, so one query returns the whole chain in time order: what the shop received, what it asked payments, what
payments answered and why it failed. **What would a trace add?** Timing and structure: spans with durations and the parent-child
tree of calls, so you see not just that the request failed, but where the time went and which call caused which.

---

## Task 5 - The dashboard, as code

`dashboards/shoplab.json` is the dashboard "ShopLab — RED" (UID `shoplab-red`). It is loaded automatically by the file
provider `monitoring/grafana/dashboards/provider.yml` from the mounted `dashboards/` directory, so it does not depend on
clicks in the Grafana UI. The datasources have fixed UIDs (`prometheus`, `loki`) in `datasources.yml`.

Panels (5):

| panel | query | unit |
|---|---|---|
| Rate by service/route | `sum by (job, route) (rate(http_requests_total[5m]))` | req/s |
| 5xx ratio by service | `sum by (job) (rate(http_requests_total{status=~"5.."}[5m])) / sum by (job) (rate(http_requests_total[5m]))` | percentunit |
| p95 latency by route | `histogram_quantile(0.95, sum by (route, le) (rate(http_request_duration_seconds_bucket{job="shop"}[5m])))` | s |
| Checkout burn rate | `checkout:burn_rate:rate1h`, `rate5m`, `rate6h`; threshold lines at 6 and 14.4 | none |
| Errors in logs (Loki) | `{service=~"shop\|payments"} \| json \| level="ERROR"` | logs |

All graphs have a Y axis from 0.

### Explain

**Why keep dashboards in git instead of only in Grafana?** The dashboard becomes reviewable, versioned and reproducible:
every change has an author and a diff, it can be rolled back, and after `docker compose down && up` (or on a new machine)
it appears by itself instead of being lost with the Grafana database.

**Who is each row of the dashboard for?** The top row (rate, 5xx ratio, p95) is the RED view for the on-call engineer and
developers: is the service healthy right now. The bottom row is for the SLO and incident work: the burn rate with the 6x and
14.4x lines is for the owner of the SLO and for deciding whether to page, and the error logs are for the engineer who
investigates, to go straight from a symptom to the cause.

---

## Final Challenge

See `POSTMORTEM.md`. The reproduction was run in this order (times from `final-run-times.log`):

| time | step |
|---|---|
| 00:26:14 | rollback to 1.0.0 (15 min baseline) |
| 00:41:24 | deploy payments 1.1.0 (15 min) |
| 00:56:35 | `docker compose stop payments` (2 min outage) |
| 00:58:45 | start payments (1.1.0 again, 5 min) |
| 01:03:46 | rollback to 1.0.0 |
| 01:05:56 | done |

## Not done / limits

- The check `docker compose down && docker compose up -d` for the dashboard and `docker image rm shoplab-app:1` was not
  run, because the lab session ended and the server was powered off.
