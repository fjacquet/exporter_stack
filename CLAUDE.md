# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **public, self-contained Docker Compose stack**, not a Go exporter. It runs Fred's 14
Prometheus exporters (**published GHCR images**) plus a second lane of 16 third-party
community exporters (upstream images) and a small Alertmanager demo, behind one
Prometheus + Grafana.
Grafana dashboards are **fetched fresh from each exporter's authoritative GitHub repo** at
startup — never vendored here. The individual exporter repos are governed by the
**`exporter-standards` skill**.

## Commands

```bash
cp .env.example .env             # optional: real creds for real targets
docker compose up -d             # pull images, fetch dashboards, start everything
docker compose logs dashboard-fetcher   # see which dashboards were fetched
docker compose ps
docker compose down
docker compose up -d --force-recreate dashboard-fetcher grafana   # re-fetch dashboards
```

- Grafana → http://localhost:3000 (`admin`/`admin`); Prometheus → http://localhost:9090.

## Architecture (spans multiple files)

- **`docker-compose.yml`** — 14 `ghcr.io/fjacquet/<repo>` exporter services plus 16
  third-party community exporters (upstream images), a one-shot `dashboard-fetcher`,
  Prometheus, Grafana, and the alerting demo (`alertmanager` + `webhook-logger`). Container
  names use the `es_` prefix.
- **`dashboard-fetcher`** — alpine + curl + jq running `scripts/fetch-dashboards.sh`, which
  reads `dashboards.manifest.txt`, resolves each repo's default branch, lists dashboard files
  RECURSIVELY via the GitHub git-trees API, downloads JSON into the `dashboards` named volume
  (filenames flattened, `/`→`__`, so files from different subdirs never collide), then exits 0.
  Grafana waits on `condition: service_completed_successfully`. Warns-and-continues per file;
  only fails if nothing was fetched.
- **`configs/<exporter>.yaml`** — committed, generic, reference `${VAR}`; real values come from
  `.env`. Each sets the exporter's canonical `server.port`; file logging is routed to stdout.
- **Ports** — unique per exporter: idrac 9348, obs 9438, nbu 9440, ppdd 9441, ppdm 9442,
  pmax 9443, pscale 9444, pflex 9445, pstore 9446, nsr 9447, pve 9221, and the licensing
  trio m365 9105, vmware 9106, veeam 9107. A port change must be edited in
  `docker-compose.yml`, `prometheus.yml`, and the README table.

## Gotchas

- **`obs` ≠ `ecs`**: the `obs_exporter` service/image comes from the GitHub repo
  `fjacquet/obs_exporter`; idrac's config mounts at `/etc/prometheus/idrac.yml` (not
  `/etc/<exporter>/config.yaml`) and idrac takes no `--config` flag.
- **Credentials**: several exporters (idrac, nbu, pflex, pscale, pstore) fail-fast on an
  empty password/API key, so compose defaults every credential to a non-functional
  `changeme` placeholder. Real values go in `.env`.
- **`${VAR}` in config comments**: nsr scans the whole config file (including comments) for
  env refs and fatals on unset ones, so commented examples use `<VAR>` (angle brackets),
  not `${VAR}`. Keep it that way when editing configs.
- **idrac & nbu collect on demand**: without a reachable backend their Prometheus target
  shows `down` (scrape times out), unlike the others which serve `<exporter>_up 0`.
- Dashboards track each repo's **default branch**; a 404 in the fetcher logs means the path
  moved upstream — fix it in `dashboards.manifest.txt`.
- `.env` and the fetched dashboards (a docker volume) are never committed.

## Gotchas — community exporters & alerting (second lane)

- **Two lanes**: Fred's 14 `ghcr.io/fjacquet/*` services plus 16 third-party community
  exporters from upstream images (`quay.io/*`, `oliver006/*`, `percona/*`, `kbudde/*`,
  `danielqsj/*`, `digitalocean/*`, `ghcr.io/pando85/*`, `kurzdigital/*`). `node_exporter`
  is the only **live** one (mounts host `/proc`,`/sys`,`/` → `up=1`).
- **`up=1` ≠ healthy for community exporters**: most serve `/metrics` without a backend, so
  Prometheus `up=1`; the idle signal is the exporter's own gauge (`pg_up`, `mysql_up`,
  `redis_up`, `mongodb_up`, `mssql_up` = 0). Only fatal-exit / collect-on-demand exporters
  show `up=0`.
- **Fail-fast / restart-loopers** (`Restarting` in `docker compose ps` without real
  creds/backends): **kafka, stackdriver, azure, gluster** always, **ceph** intermittently
  (librados connect timeout) — plus the pre-existing **vmware/m365/veeam licenses** trio.
  Documented, not a stack bug; set real values in `.env` to settle them.
- **azure_exporter** (webdevops) validates creds at startup and fatal-exits with placeholder
  values — it does NOT serve self-metrics until real Azure creds are set.
- **Community image quirks**: `percona/mongodb_exporter` has **no `:latest`** (pinned
  `0.51.0`); `quay.io/prometheuscommunity/apache-exporter` is dead → use
  `quay.io/lusitaniae/apache-exporter`; `gluster/gluster-prometheus` doesn't exist → uses
  unofficial `kurzdigital/gluster-prometheus` (legacy, 2018, amd64-only + `command:`
  override); `ceph` and `gluster` pin `platform: linux/amd64` (no arm64 image).
- **MySQL**: `mysqld_exporter` v0.15.0+ dropped `DATA_SOURCE_NAME`; wiring uses
  `configs/mysqld.cnf` + `--config.my-cnf` + `--mysqld.address`.
- **grafana.com dashboards**: `dashboards.manifest.txt` rows can use a `gcom:<id>` token
  (fetched from grafana.com, `__inputs`/`__requires` stripped, datasource rewritten to
  `prometheus`). gcom-only rows use repo `-` and log a harmless GitHub-API 404 per row
  (`resolve_ref` still runs); the fetch still succeeds. azure & radosgw have no canonical
  grafana.com dashboard (omitted).
- **Windows** has no Linux container: a commented scrape job (`:9182`) in `prometheus.yml`
  + a doc note; its dashboard (gcom 14694) is still fetched.
- **Alerting demo**: `rules/alerts.yml` → Prometheus (`rule_files`) → **alertmanager**
  (`:9093`) → **webhook-logger** (`docker compose logs webhook-logger`). Rules: `Heartbeat`
  (always), `BackendDown` (db exporters' `*_up==0`), `ExporterDown` (restart-loopers +
  idrac/nbu), `NodeHighLoad` (example). See `docs/alertmanager.md`.
- **New ports**: node 9100, mysqld 9104, haproxy 9101, apache 9117, nginx 9113, redis 9121,
  postgres 9187, mongodb 9216, kafka 9308, rabbitmq 9419, ceph 9128, radosgw 9242,
  gluster 9713, stackdriver 9255, azure 8080, mssql 4000, alertmanager 9093,
  webhook-logger 9095 (host). Full table in the README.
