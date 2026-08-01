# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Persistent storage for the shared observability services: named volumes
  `prometheus_data` (`/prometheus`), `grafana_data` (`/var/lib/grafana`) and
  `alertmanager_data` (`/alertmanager`). Metric history, Grafana users / API keys /
  dashboard edits and Alertmanager silences now survive a reboot or a plain
  `docker compose down`. Each mount path is the upstream image's own default, and
  `GF_PATHS_DATA` is stated explicitly so Grafana's SQLite path cannot drift from its volume.
- Bounded Prometheus retention, overridable in `.env`: `PROMETHEUS_RETENTION_TIME` (`30d`)
  and `PROMETHEUS_RETENTION_SIZE` (`10GB`), whichever limit is reached first. Prometheus now
  sets an explicit `command:` that reproduces the image's default `--config.file` and
  `--storage.tsdb.path` flags alongside the two retention flags.
- `pve_exporter` to the stack (11 exporters total): Proxmox VE metrics on port 9221,
  with token-based API auth (`PVE1_HOST`, `PVE1_TOKEN_ID`, `PVE1_TOKEN_SECRET`).
- Six Proxmox dashboards fetched from `fjacquet/pve_exporter` at startup
  (pve-cluster-overview, pve-node, pve-guest, pve-storage, pve-backup-dr, pve-ha-quorum).

## [0.1.0] - 2026-06-16

First public release.

### Added
- `idrac_exporter` to the stack (10 exporters total).
- `dashboard-fetcher`: dashboards are fetched fresh from each exporter's authoritative
  GitHub repo at startup via `dashboards.manifest.txt` (no vendored copies), matched
  recursively so nested dashboard subdirectories are included.
- Committed generic `configs/<exporter>.yaml` referencing environment variables; real
  values supplied via `.env`. Unset credentials fall back to a non-functional placeholder
  so every exporter still boots.
- Public docs: README, this CHANGELOG, and an MIT LICENSE.

### Changed
- Exporters now run from published GHCR images (`ghcr.io/fjacquet/<repo>`) instead of
  building from sibling source repos. No sibling checkouts required.
- Container names use the `es_` prefix.

### Removed
- Mock backends (`mocknw`, `mockdd`, `mockppdm`, `mockecs`) and all build-from-source
  contexts. Every exporter targets real hardware.
- Host-port remapping — each exporter now listens on a unique port (9348, 9438, 9440–9447).
