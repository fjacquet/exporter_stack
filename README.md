# exporter_stack

One `docker compose` that runs the whole family of Prometheus exporters behind a single
Prometheus + Grafana. Exporter images are pulled from GitHub Container Registry; Grafana
dashboards are fetched **fresh from each exporter's own GitHub repo** at startup — never
vendored here, so they never go stale.

## Quick start

```bash
cp .env.example .env        # optional: set credentials to reach real targets
docker compose up -d
```

- **Grafana** → http://localhost:3000 (`admin`/`admin`) — one dashboard folder per exporter
- **Prometheus** → http://localhost:9090 → *Status → Targets*

Everything starts with no configuration: all 10 exporter images are pulled, the dashboards
are fetched from upstream, and Prometheus + Grafana come up. Without real credentials the
exporters still run but report no live data (see [Targets without real hardware](#targets-without-real-hardware)).

Tear down with `docker compose down`.

## Exporters

| Exporter | Image (`ghcr.io/fjacquet/…`) | Port | Backend |
|---|---|---|---|
| idrac  | `idrac_exporter`  | 9348 | iDRAC / BMC (Redfish) |
| obs    | `obs_exporter`    | 9438 | Dell ObjectScale / ECS |
| nbu    | `nbu_exporter`    | 9440 | Veritas/Cohesity NetBackup |
| ppdd   | `ppdd_exporter`   | 9441 | Dell PowerProtect DD |
| ppdm   | `ppdm_exporter`   | 9442 | Dell PowerProtect DM |
| pmax   | `pmax_exporter`   | 9443 | Dell PowerMax (Unisphere) |
| pscale | `pscale_exporter` | 9444 | Dell PowerScale (OneFS) |
| pflex  | `pflex_exporter`  | 9445 | Dell PowerFlex |
| pstore | `pstore_exporter` | 9446 | Dell PowerStore |
| nsr    | `nsr_exporter`    | 9447 | Dell NetWorker |
| pve    | `pve_exporter`    | 9221 | Proxmox Virtual Environment |
| vmware | `vmware_licenses_exporter` | 9106 | VMware vSphere licenses |
| m365   | `m365_licenses_exporter`   | 9105 | Microsoft 365 licenses |
| veeam  | `veeam_licenses_exporter`  | 9107 | Veeam Backup Enterprise Manager licenses |
| node   | `quay.io/prometheus/node-exporter` | 9100 | Linux/host metrics (live) |
| postgres | `quay.io/prometheuscommunity/postgres-exporter` | 9187 | PostgreSQL (idle — `pg_up 0`) |
| mysqld | `quay.io/prometheus/mysqld-exporter` | 9104 | MySQL/MariaDB (idle — `mysql_up 0`) |
| mongodb | `percona/mongodb_exporter` | 9216 | MongoDB (idle — `mongodb_up 0`) |
| mssql | `awaragi/prometheus-mssql-exporter` | 4000 | Microsoft SQL Server (idle — `mssql_up 0`) |
| redis | `oliver006/redis_exporter` | 9121 | Redis (idle — `redis_up 0`) |
| nginx | `nginx/nginx-prometheus-exporter` | 9113 | nginx (idle — no backend) |
| apache | `quay.io/lusitaniae/apache-exporter` | 9117 | Apache HTTP Server (idle — no backend) |
| haproxy | `quay.io/prometheus/haproxy-exporter` | 9101 | HAProxy (idle — no backend) |
| rabbitmq | `kbudde/rabbitmq-exporter` | 9419 | RabbitMQ (idle — no backend) |
| kafka | `danielqsj/kafka-exporter` | 9308 | Kafka (fatal-exits on unreachable broker; container restart-loops) |
| stackdriver | `quay.io/prometheuscommunity/stackdriver-exporter` | 9255 | GCP Cloud Monitoring (fails fast/restart-loops on placeholder creds — needs valid Application Default Credentials) |
| azure | `quay.io/webdevops/azure-metrics-exporter` | 8080 | Azure Monitor probe exporter (fails fast/restart-loops on placeholder creds — needs a real tenant/client/secret; with valid creds `/metrics` serves exporter self-metrics only, real Azure metrics need probe-style scrape config, out of scope here) |
| ceph | `digitalocean/ceph_exporter` | 9128 | Ceph cluster (librados) — fatal-exits and restart-loops on an unreachable mon (`error connecting to rados: timeout`, ~30s); target flaps `down`/connection-refused between restarts. amd64-only image, pinned `platform: linux/amd64` |
| radosgw | `ghcr.io/pando85/radosgw_usage_exporter` | 9242 | Ceph RADOS Gateway usage — starts and serves `/metrics` even with placeholder creds, target `up 1` (self-metrics only; real usage stats need a reachable radosgw) |
| gluster | `kurzdigital/gluster-prometheus` (substituted — see note below) | 9713 | GlusterFS — needs a local `glusterd`; restart-loops without one. Legacy entry (Task 12) |
| windows | — (doc-only, Windows host) | 9182 | Windows Exporter — no Linux container, nothing runs in this stack |

Fred's own exporters (idrac…veeam above) use the `ghcr.io/fjacquet/…` shorthand in the Image
column. Community/third-party exporters (node, postgres, mysqld, mongodb, mssql, redis above,
and more to come) pull from their own upstream registries, so their Image column shows the
full image reference verbatim instead.

Windows Exporter has no Linux container; its scrape job in `prometheus.yml` is commented —
uncomment and point it at a Windows host running windows_exporter on :9182. Its Grafana
dashboard is still provisioned.

**Image substitution — gluster:** `gluster/gluster-prometheus:latest` is not published on
Docker Hub (`denied: requested access to the resource is denied`). Substituted
`kurzdigital/gluster-prometheus:latest`, an amd64-only community build of the same
upstream `gluster/gluster-prometheus` source (last pushed 2018). Its default `CMD` is a bare
`/bin/sh`, so `docker-compose.yml` sets `command: ["/gluster-exporter"]` explicitly.

## Configuring real targets

Each exporter reads `configs/<exporter>.yaml`, which references environment variables for
hosts and credentials. Set those in `.env` (gitignored) — see `.env.example` for the full
list. Pin an image version per exporter with its `*_TAG` variable (e.g. `PFLEX_TAG=0.2.1`).

Credentials left unset fall back to a non-functional `changeme` placeholder so every
exporter still boots. Replace them with real values for live data. For multi-instance
monitoring, edit the relevant `configs/<exporter>.yaml` directly.

## Targets without real hardware

With placeholder credentials and unreachable example hosts:

- **Most exporters** (obs, ppdd, ppdm, pmax, pscale, pflex, pstore, nsr) collect in the
  background, so Prometheus scrapes them successfully and per-target health shows in an
  `<exporter>_up 0` gauge.
- **idrac and nbu** collect on demand — they query the backend during each scrape — so
  their Prometheus target stays `down` until they can reach a real BMC / NetBackup master.
- **kafka** fatally exits (and restart-loops under `restart: unless-stopped`) if it cannot
  connect to a broker at startup, so its Prometheus target stays `down` until `KAFKA_SERVER`
  points at a reachable broker.
- **stackdriver and azure** both fatally exit at startup (and restart-loop) if credentials
  are missing/placeholder — stackdriver on "could not find default credentials", azure on
  `DefaultAzureCredential: failed to acquire a token`. Their Prometheus targets stay `down`
  (`up 0`) until `GOOGLE_APPLICATION_CREDENTIALS`/`GCP_PROJECT_ID` and
  `AZURE_TENANT_ID`/`AZURE_CLIENT_ID`/`AZURE_CLIENT_SECRET` point at real, valid credentials.
- **ceph** fatally exits (`unable to create rados connection for cluster ... timeout`,
  ~30s) and restart-loops against the placeholder `mon_host` in `configs/ceph.conf`, so its
  target flaps between `down`/`connection refused` — set a real `mon_host` and keyring for
  live data.
- **radosgw** starts and answers `/metrics` even with placeholder creds — its target reports
  `up 1`, but the exposed series are self-metrics only until `RADOSGW_SERVER`/
  `RADOSGW_ACCESS_KEY`/`RADOSGW_SECRET_KEY` point at a real gateway.
- **gluster** requires a local `glusterd` peer; without one it restart-loops (observed
  locally as a Rosetta/amd64-emulation crash on Apple Silicon — on a genuine amd64 Linux
  host it would instead fail to connect to glusterd). Documented as a legacy/best-effort
  entry (Task 12).

This is expected. Point `configs/` and `.env` at real, reachable targets to get live data.

## How dashboards stay evergreen

On every `up`, the one-shot `dashboard-fetcher` reads `dashboards.manifest.txt` and downloads
each dashboard JSON from the repo's default branch into a shared volume that Grafana
provisions, one folder per exporter. Override the ref globally with `DASHBOARD_REF`, or
per-exporter in the manifest. Set `GITHUB_TOKEN` in `.env` if you hit GitHub's
unauthenticated API rate limit.

Inspect a run: `docker compose logs dashboard-fetcher`.

## License

MIT — see [LICENSE](LICENSE).
