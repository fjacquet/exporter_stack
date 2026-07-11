# Design: Add third-party community exporters to the demo stack

**Date:** 2026-07-11
**Status:** Approved (design), pending spec review

## Goal

Extend the public demo stack with well-known **third-party / community Prometheus
exporters** (node, postgres, redis, nginx, kafka, …) alongside the existing 14
`ghcr.io/fjacquet/*` exporters. This adds a **second lane** to the stack: upstream
community images instead of Fred's GHCR namespace, and grafana.com-hosted dashboards
instead of GitHub-repo dashboards.

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
with existing stack ports (9090, 3000, 9105–9107, 9221, 9348, 9438–9447) or each other.

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
only; a dashboard can be a follow-up. This is consistent with the honest "coverage is
patchy for some" reality — the exporter still appears and scrapes.

## Architecture

### Manifest: single file, typed tokens (Option A)

`dashboards.manifest.txt` keeps its existing columns
(`<exporter> <repo> <ref> <path...>`). The `<path...>` field gains a new token type:

- A GitHub path token (unchanged): `grafana/dashboards/` (dir, recursive) or
  `grafana/x.json` (single file).
- A **new** grafana.com token: `gcom:<id>` — e.g. `gcom:1860`.

The `gcom:` prefix is unambiguous (a GitHub repo path never starts with `gcom:`). Exporters
that have no source GitHub repo use `-` in the `<repo>` column and list only `gcom:` tokens.

New manifest rows (illustrative):

```
node     -  default  gcom:1860
windows  -  default  gcom:14694
mysqld   -  default  gcom:7362
postgres -  default  gcom:9628
...
```

### Fetcher: add a grafana.com branch

`scripts/fetch-dashboards.sh` gains a helper that, for a `gcom:<id>` token:

1. Resolve the latest revision:
   `GET https://grafana.com/api/dashboards/<id>` → `.revision` (or use
   `/revisions/latest/download` directly if the API supports it; confirm at implementation).
2. Download:
   `GET https://grafana.com/api/dashboards/<id>/revisions/<rev>/download` → raw dashboard JSON.
3. **Normalise for file-provisioning** (grafana.com dashboards ship a `${DS_PROMETHEUS}`
   input variable that file provisioning will not auto-resolve):
   - `jq 'del(.__inputs, .__requires)'`
   - Read the prometheus datasource input's variable name from `.__inputs[]` (type
     `datasource`, pluginId `prometheus`); `sed` `${<name>}` → `prometheus` throughout.
     Fall back to replacing the common `${DS_PROMETHEUS}` if `__inputs` is absent.
4. Write to `$OUT/<exporter>/<id>.json`.

The existing GitHub path branch is untouched. The per-item **warn-and-continue** behaviour
and the "fail only if nothing fetched" exit rule are preserved. Because the datasource
`uid: prometheus` is already provisioned and marked default, the rewritten dashboards bind
correctly with no per-dashboard datasource variable.

### Per-exporter wiring (YAGNI — config files only where required)

- **Env / flag exporters** (postgres, mongodb, apache, nginx, redis, rabbitmq, kafka,
  haproxy, mssql, stackdriver, azure, radosgw): placeholder target via env var or CLI flag
  with a non-functional default → `up=0`. No config file.
- **Config-file exporters** (require a mounted file):
  - `mysqld` → `configs/mysqld.cnf` (a `[client]` my.cnf with placeholder user/password;
    host via `--mysqld.address`).
  - `ceph` → `configs/ceph.conf` + placeholder keyring mounted at `/etc/ceph`.
  - `gluster` → `configs/gluster-exporter.toml`.
- **node_exporter**: no target; mounts host `/proc`, `/sys`, `/` read-only with
  `--path.rootfs=/host` (standard host-metrics pattern) so it shows real data.

### Naming, network, ports

- Service names: `<exporter>_exporter` (e.g. `node_exporter`); container names `es_<name>`
  matching the existing `es_` prefix convention.
- Same `exporters` bridge network; `restart: unless-stopped`; image tag overridable via
  `${<NAME>_TAG:-latest}` env like the existing services.
- Host port == container default port (matches upstream docs). All unique.

### Prometheus scrape config

One `job_name` per new exporter in `prometheus.yml`, targeting `<service>:<port>` on the
shared network — same pattern as the existing 14. Windows is a **commented** example job
(port 9182) pointing at an example external host.

## Touch-points (the existing "edit in N places" rule, extended)

A new exporter is added in up to **five** places:

1. `docker-compose.yml` — service definition.
2. `prometheus.yml` — scrape job.
3. `dashboards.manifest.txt` — dashboard row (`gcom:` and/or GitHub).
4. `README` — the ports/exporters table.
5. `.env.example` — image tag var + any credential placeholders (for credentialed exporters).

Plus, one-time: `scripts/fetch-dashboards.sh` gains the grafana.com branch, and any
`configs/*.{cnf,conf,toml}` files are added for the config-file exporters.

## Error handling & gotchas

- **Fail-fast on empty creds / unreachable backend.** Some community exporters may exit
  (restart-loop) rather than serve `up=0` when they cannot reach their backend at startup —
  `mongodb_exporter` (Percona) and `mssql_exporter` are the likely candidates. Mitigation to
  validate at implementation: prefer a lazy-connect flag, or accept a benign restart loop, or
  (last resort) omit that exporter. Document whichever applies in CLAUDE.md gotchas, mirroring
  the existing idrac/nbu fail-fast note.
- **MySQL `DATA_SOURCE_NAME` is gone** (removed v0.15.0). Must use `--config.my-cnf` +
  `--mysqld.address`. This is why mysqld is a config-file exporter, not env-based.
- **HAProxy scrape URI** must end in `;csv` for the CSV stats endpoint.
- **Gluster is legacy.** `gluster/gluster-prometheus` is low-activity and the ecosystem is
  shrinking (RHGS EOL, Proxmox 9 dropped GlusterFS). Included as a legacy catalog entry.
- **grafana.com API shape** for latest-revision download to be confirmed against a live call
  during implementation (the `/revisions/latest/download` vs explicit-revision path).

## Out of scope

- Backing services / live data for anything except node_exporter.
- CloudWatch Exporter.
- Dashboards for azure and radosgw (no canonical grafana.com source; follow-up).
- Republishing any of these under the `ghcr.io/fjacquet` namespace — upstream images are used
  directly.

## Verification

- `docker compose config` parses; `docker compose up -d` starts every new container without a
  restart loop (except any documented fail-fast exception).
- `docker compose logs dashboard-fetcher` shows each `gcom:<id>` dashboard fetched `ok`, and
  the run still exits 0.
- Prometheus → Status > Targets lists every new job; node is `up`, the rest `up=0`.
- Grafana shows a folder per new exporter with its dashboard; node's dashboard renders live
  data; the datasource binds with no "datasource not found" errors.
