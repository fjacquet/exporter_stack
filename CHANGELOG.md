# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
