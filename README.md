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

Fred's own exporters (idrac…veeam above) use the `ghcr.io/fjacquet/…` shorthand in the Image
column. Community/third-party exporters (node, postgres, mysqld, mongodb, mssql, redis above,
and more to come) pull from their own upstream registries, so their Image column shows the
full image reference verbatim instead.

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
