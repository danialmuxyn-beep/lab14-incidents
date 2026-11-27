# lab14-incidents - ShopLab observability (Variant A)

Two services (`shop`, `payments`), a traffic generator, Prometheus, Alertmanager, Loki, Alloy and Grafana.

## Start

    mkdir -p dashboards runbooks
    docker compose up -d --build
    docker compose ps          # 9 services Up

- Prometheus http://localhost:9090, Alertmanager http://localhost:9093, Grafana http://localhost:3000 (dashboard "ShopLab - RED" in folder lab14).
- Deploy payments 1.1.0: `PAYMENTS_VERSION=1.1.0 docker compose up -d payments`; roll back: `docker compose up -d payments`.

## Content

- `app/` - the application and the traffic generator
- `monitoring/` - Prometheus rules (`rules.yml`), Alertmanager routing (`alertmanager.yml`), Loki, Alloy, Grafana provisioning
- `dashboards/shoplab.json` - the dashboard as code
- `runbooks/` - one runbook per alert
- `REPORT.md` - the report, `POSTMORTEM.md` - the postmortem

Variant A (no Kubernetes). The stack was run on an AWS EC2 instance because CloudShell has too little disk for the images.
