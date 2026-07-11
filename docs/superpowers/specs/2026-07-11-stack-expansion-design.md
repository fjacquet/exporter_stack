# Design: Expand the demo stack — community exporters + Alertmanager demo

**Date:** 2026-07-11
**Status:** Approved (design), pending spec review

## Goal

Two related additions to the public demo stack, shipped together:

- **Part A — community exporters.** Add well-known **third-party / community Prometheus
  exporters** (node, postgres, redis, nginx, kafka, …) alongside the existing 14
  `ghcr.io/fjacquet/*` exporters — a **second lane**: upstream community images and
  grafana.com-hosted dashboards.
- **Part B — Alertmanager demo.** Add a self-contained alerting path (Prometheus rules →
  Alertmanager → webhook receiver) so the stack demonstrates the full rule→fire→route→
  group→notify flow. It leans on Part A: the idle exporters sit at `up=0`, so an
  `ExporterDown` rule fires on startup with zero fake data.

The two parts share `prometheus.yml` and the compose file but are otherwise independent;
either could be implemented first. They are merged into one spec because they land in the
same files and tell one story ("a fuller monitoring demo").

---

# Part A — Community exporters

## Decisions (locked)

1. **Idle catalog, no backing services.** New exporters point at fictional targets and
   report `up=0` until the user supplies real creds/targets in `.env` — exactly like the
   existing 14. The one exception is **node_exporter**, which takes no backend and will be
   `up=1` with real container/host metrics (the "just works" showcase).
2. **Extend the dashboard fetcher for grafana.com.** `scripts/fetch-dashboards.sh` gains a
   second source type so it can download a dashboard by its numeric grafana.com ID, in
   addition to the existing GitHub-repo path handling.
3. **Windows Exporter is document-only** (no Linux container exists). It gets a commented
   example scrape job in `prometheus.yml` and a README note — **but its grafana.com
   dashboard is still fetched and provisioned** (shows no data until an external Windows
   host is scraped).
4. **CloudWatch Exporter is dropped** from this batch.

## Scope: 16 runnable containers + 1 doc-only stub

All images verified as of 2026-07. Ports are each exporter's upstream default; none collide
with existing stack ports (9090, 3000, 9093, 9105–9107, 9221, 9348, 9438–9447) or each other.

| Exporter | Image | Port | Backend wiring (idle default → `up=0`) | Dashboard |
|---|---|---|---|---|
| node | `quay.io/prometheus/node-exporter` | 9100 | none — mounts host `/proc`,`/sys`,`/`; **live `up=1`** | gcom `1860` |
| windows *(doc-only)* | — (no Linux image) | 9182 | commented scrape job → example external host | gcom `14694` |
| mysqld | `quay.io/prometheus/mysqld-exporter` | 9104 | `configs/mysqld.cnf` (my.cnf) + `--config.my-cnf` + `--mysqld.address` | gcom `7362` |
| postgres | `quay.io/prometheuscommunity/postgres-exporter` | 9187 | `DATA_SOURCE_NAME` env | gcom `9628` |
| mongodb | `percona/mongodb_exporter` | 9216 | `--mongodb.uri` flag | gcom `20867` |
| apache | `quay.io/prometheuscommunity/apache-exporter` | 9117 | `--scrape_uri` flag | gcom `3894` |
| nginx | `nginx/nginx-prometheus-exporter` | 9113 | `--nginx.scrape-uri` flag | gcom `12708` |
| rabbitmq | `kbudde/rabbitmq-exporter` | 9419 | `RABBIT_URL` env + `RABBIT_USER`/`RABBIT_PASSWORD` | gcom `4279` |
| kafka | `danielqsj/kafka-exporter` | 9308 | `--kafka.server` flag | gcom `7589` |
| stackdriver | `quay.io/prometheuscommunity/stackdriver-exporter` | 9255 | `--google.project-ids` + `GOOGLE_APPLICATION_CREDENTIALS` | gcom `16572` |
| azure | `quay.io/webdevops/azure-metrics-exporter` | 8080 | `AZURE_TENANT_ID`/`AZURE_CLIENT_ID`/`AZURE_CLIENT_SECRET` env | none (see below) |
| haproxy | `quay.io/prometheus/haproxy-exporter` | 9101 | `--haproxy.scrape-uri` flag (`;csv` suffix required) | gcom `367` |
| redis | `oliver006/redis_exporter` | 9121 | `REDIS_ADDR` env + `REDIS_PASSWORD` | gcom `763` |
| mssql | `awaragi/prometheus-mssql-exporter` | 4000 | `SERVER`/`USERNAME`/`PASSWORD`/`PORT` env | gcom `9336` |
| ceph | `digitalocean/ceph_exporter` | 9128 | `configs/ceph.conf` + keyring at `/etc/ceph` (fictional) | gcom `917` |
| radosgw | `ghcr.io/pando85/radosgw_usage_exporter` | 9242 | `RADOSGW_SERVER`/`ACCESS_KEY`/`SECRET_KEY` env | none (see below) |
| gluster | `gluster/gluster-prometheus` | 9713 | `configs/gluster-exporter.toml` (fictional peer) | gcom `8376` |

**Dashboards deliberately omitted this batch:** azure and radosgw have no canonical
grafana.com dashboard (their upstream repos ship their own JSON). They join as exporters
only; a dashboard can be a follow-up.

## Architecture

### Manifest: single file, typed tokens (Option A)

`dashboards.manifest.txt` keeps its existing columns
(`<exporter> <repo> <ref> <path...>`). The `<path...>` field gains a new token type:

- A GitHub path token (unchanged): `grafana/dashboards/` (dir, recursive) or
  `grafana/x.json` (single file).
- A **new** grafana.com token: `gcom:<id>` — e.g. `gcom:1860`.

The `gcom:` prefix is unambiguous (a GitHub repo path never starts with `gcom:`). Exporters
that have no source GitHub repo use `-` in the `<repo>` column and list only `gcom:` tokens.

### Fetcher: add a grafana.com branch

`scripts/fetch-dashboards.sh` gains a helper that, for a `gcom:<id>` token:

1. Resolve the latest revision via `GET https://grafana.com/api/dashboards/<id>` (or use
   `/revisions/latest/download` directly if supported; confirm at implementation).
2. Download `GET https://grafana.com/api/dashboards/<id>/revisions/<rev>/download` → raw JSON.
3. **Normalise for file-provisioning** (grafana.com dashboards ship a `${DS_PROMETHEUS}`
   input variable that file provisioning will not auto-resolve):
   - `jq 'del(.__inputs, .__requires)'`
   - Read the prometheus datasource input's variable name from `.__inputs[]` (type
     `datasource`, pluginId `prometheus`); `sed` `${<name>}` → `prometheus`. Fall back to the
     common `${DS_PROMETHEUS}` if `__inputs` is absent.
4. Write to `$OUT/<exporter>/<id>.json`.

The existing GitHub path branch, the per-item **warn-and-continue** behaviour, and the "fail
only if nothing fetched" exit rule are all preserved. The provisioned datasource
`uid: prometheus` (default) makes the rewritten dashboards bind with no per-dashboard var.

### Per-exporter wiring (YAGNI — config files only where required)

- **Env / flag exporters** (postgres, mongodb, apache, nginx, redis, rabbitmq, kafka,
  haproxy, mssql, stackdriver, azure, radosgw): placeholder target via env var or CLI flag
  with a non-functional default → `up=0`. No config file.
- **Config-file exporters:** `mysqld` → `configs/mysqld.cnf`; `ceph` → `configs/ceph.conf` +
  placeholder keyring at `/etc/ceph`; `gluster` → `configs/gluster-exporter.toml`.
- **node_exporter:** no target; mounts host `/proc`, `/sys`, `/` read-only with
  `--path.rootfs=/host` (standard host-metrics pattern) so it shows real data.

### Naming, network, ports

- Service names `<exporter>_exporter`; container names `es_<name>` (existing `es_` prefix).
- Same `exporters` bridge network; `restart: unless-stopped`; image tag overridable via
  `${<NAME>_TAG:-latest}`. Host port == container default port (matches upstream docs).

### Prometheus scrape config

One `job_name` per new exporter targeting `<service>:<port>` — same pattern as the existing
14. Windows is a **commented** example job (port 9182) pointing at an example external host.

---

# Part B — Alertmanager demo

## Decisions (locked)

1. **Notifications go to a webhook logger**, viewed via container logs — matching the stack's
   "watch the logs" idiom (like `dashboard-fetcher`). Shows the exact JSON payload Alertmanager
   sends, i.e. the real integration path for Slack/PagerDuty/custom later.
2. **Alerts fire on their own** from Part A's idle `up=0` targets — no fake data, no external
   accounts.
3. **Notification templates are included as reference only.** A webhook receiver always posts
   fixed JSON, so Go text templates aren't exercised by the live path; the spec ships an example
   template + a **commented-out email receiver** showing where a template plugs in.

## New services

- `alertmanager` — `prom/alertmanager`, UI on `:9093`, config `./alertmanager.yml`, network
  `exporters`, `restart: unless-stopped`, tag via `${ALERTMANAGER_TAG:-latest}`.
- `webhook-logger` — `mendhak/http-https-echo` (pretty-prints each received request as JSON to
  its log). Alertmanager POSTs to `http://webhook-logger:8080/`. A host port is mapped for
  optional `curl` access but the intended view is `docker compose logs -f webhook-logger`.
  Host port chosen to avoid the azure exporter's 8080 (e.g. host `9095` → container `8080`).

## New config files

- **`alertmanager.yml`** — a single `route` to the `webhook-logger` receiver with
  `group_by`, `group_wait`, `group_interval`, `repeat_interval` set to visible demo values so
  grouping/repeat behaviour is observable; `send_resolved: true`. Plus a **commented** email
  receiver referencing the example template, as the "here's where templates go" reference.
- **`rules/alerts.yml`** (mounted into Prometheus at `/etc/prometheus/rules/`):
  - `ExporterDown` — `up == 0` for `1m`, `severity: warning`; **fires on startup** for every
    idle exporter. Annotations explain the demo context.
  - `Heartbeat` — an always-firing alert (e.g. `vector(1)`), teaching the dead-man's-switch
    pattern (absence of this alert means the pipeline is broken).
  - one non-firing node example (e.g. `node_load1 > 100` for `5m`) showing the normal pattern.
- **`alertmanager/templates/notification.tmpl`** — example notification template used by the
  commented email receiver (reference/teaching).

## Wiring into existing files

- `prometheus.yml` gains:
  - `alerting.alertmanagers` → `static_configs` target `alertmanager:9093`
  - `rule_files: [ /etc/prometheus/rules/*.yml ]`
- The `prometheus` service in `docker-compose.yml` mounts `./rules:/etc/prometheus/rules:ro`.
- README section + short `docs/alertmanager.md` explaining the concepts (rules vs Alertmanager;
  grouping/routing/inhibition/silences/receivers) and how to watch alerts fire (Alertmanager
  UI `:9093` vs webhook logs).

## Optional / soft dependency

A grafana.com "Alertmanager" overview dashboard (ID `9578`) can be added via Part A's
grafana.com fetcher branch once it exists (`alertmanager - default gcom:9578` in the manifest).
Marked optional so Part B does not hard-depend on Part A.

---

## Touch-points (the existing "edit in N places" rule, extended)

**Per new exporter (Part A)** — up to five places:

1. `docker-compose.yml` — service definition.
2. `prometheus.yml` — scrape job.
3. `dashboards.manifest.txt` — dashboard row (`gcom:` and/or GitHub).
4. `README` — the ports/exporters table.
5. `.env.example` — image tag var + any credential placeholders.

**One-time (Part A):** `scripts/fetch-dashboards.sh` grafana.com branch; `configs/*.{cnf,conf,toml}`
for the config-file exporters.

**One-time (Part B):** `alertmanager.yml`, `rules/alerts.yml`,
`alertmanager/templates/notification.tmpl`, `docs/alertmanager.md`; `alertmanager` and
`webhook-logger` services; `prometheus.yml` `alerting`/`rule_files`; `rules` mount on the
prometheus service; README alerting section; `ALERTMANAGER_TAG` in `.env.example`.

## Error handling & gotchas

- **Fail-fast on empty creds / unreachable backend.** Some community exporters may exit
  (restart-loop) rather than serve `up=0` when they cannot reach their backend at startup —
  `mongodb_exporter` (Percona) and `mssql_exporter` are the likely candidates. Mitigation to
  validate at implementation: prefer a lazy-connect flag, accept a benign restart loop, or (last
  resort) omit that exporter. Document whichever applies in CLAUDE.md gotchas, mirroring the
  existing idrac/nbu note.
- **MySQL `DATA_SOURCE_NAME` is gone** (removed v0.15.0) — must use `--config.my-cnf` +
  `--mysqld.address`. This is why mysqld is a config-file exporter.
- **HAProxy scrape URI** must end in `;csv`.
- **Gluster is legacy** (`gluster/gluster-prometheus` low-activity; RHGS EOL; Proxmox 9 dropped
  GlusterFS). Included as a legacy catalog entry.
- **grafana.com API shape** for latest-revision download to be confirmed against a live call at
  implementation.
- **Alertmanager `repeat_interval`** kept short-ish for demo visibility, but not so short it spams
  the webhook log; balance at implementation.

## Out of scope

- Backing services / live data for anything except node_exporter.
- CloudWatch Exporter.
- Dashboards for azure and radosgw (no canonical grafana.com source; follow-up).
- Republishing any exporter under `ghcr.io/fjacquet` — upstream images used directly.
- Real notification integrations (Slack/PagerDuty/email delivery); the webhook logger stands in.
- Grafana unified alerting (this demo uses Prometheus rules + standalone Alertmanager).

## Verification

**Part A**
- `docker compose config` parses; `docker compose up -d` starts every new container without a
  restart loop (except any documented fail-fast exception).
- `docker compose logs dashboard-fetcher` shows each `gcom:<id>` dashboard fetched `ok`; run exits 0.
- Prometheus → Status > Targets lists every new job; node is `up`, the rest `up=0`.
- Grafana shows a folder per new exporter with its dashboard; node's renders live data; datasource
  binds with no "datasource not found" errors.

**Part B**
- Prometheus → Status > Rules shows `ExporterDown` and `Heartbeat` firing within ~1–2 min.
- Prometheus → Status > Runtime shows the Alertmanager discovered; Alertmanager UI `:9093` shows
  the alerts grouped by `alertname`.
- `docker compose logs webhook-logger` shows the POSTed alert JSON (firing, then resolved when a
  target recovers).
