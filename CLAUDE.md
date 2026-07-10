# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **public, self-contained Docker Compose stack**, not a Go exporter. It runs all 14 of
Fred's Prometheus exporters from **published GHCR images** behind one Prometheus + Grafana.
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

- **`docker-compose.yml`** — 14 exporter services pulling `ghcr.io/fjacquet/<repo>`, plus a
  one-shot `dashboard-fetcher`, Prometheus, and Grafana. Container names use the `es_` prefix.
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
