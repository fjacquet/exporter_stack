# Evergreen, public `exporter_stack` — Design

**Date:** 2026-06-16
**Status:** Approved (design); pending implementation plan
**Author:** Fred Jacquet (with Claude Code)

## 1. Goal & scope

Convert `exporter_stack` from a local, build-from-source **test/demo** harness (with bundled
mock backends) into a **public, self-contained deployment stack** that:

- runs **all 10 exporters** (adds `idrac`) from **public GHCR images** — no sibling repo checkouts required,
- pulls every **Grafana dashboard fresh from its authoritative GitHub repo** on each `docker compose up` (dashboards are never copied/vendored into this repo),
- ships **generic, env-referencing configs + `.env`** so the stack runs out-of-the-box (each target reports `up=0` until pointed at a real array),
- carries **public-grade documentation**: README, CHANGELOG, LICENSE.

### Explicitly removed
- The 4 mock backends: `mocknw`, `mockdd`, `mockppdm`, `mockecs`.
- All `build:` contexts (`../<repo>`), `pull_policy: build`, and `config.demo.yaml` usage.
- Host-port remapping (`2113`/`2114`) — no longer needed (see §2).
- The internal project alias `all_exporter` and the `cd all_exporter` instruction.

### Decisions locked during brainstorming
1. **Exporter sourcing:** pull prebuilt `ghcr.io/fjacquet/<repo>` images (standalone/public).
2. **No mock systems** — every exporter points at real hardware via config + `.env`.
3. **Dashboard delivery:** a one-shot **init container** fetches dashboards on every `up`.
4. **Ref policy:** track each repo's **default branch (`main`)** — evergreen — with a per-exporter override.
5. **Configs:** committed **generic** `configs/<exporter>.yaml` referencing `${VAR}`; real values only in `.env`.
6. **Container prefix:** `au_` → **`es_`**.
7. **Docs:** README + CHANGELOG + MIT LICENSE now; `CONTRIBUTING.md` deferred.

## 2. The exporter fleet (canonical table)

Each exporter's own default listen port is already unique, so there is **no host-port remapping** —
host port = container port, 1:1. Internal port collisions cannot occur (each exporter is its own
container / network namespace).

| Service | GHCR image | Port | Backend | Live data without creds? |
|---|---|---|---|---|
| `idrac_exporter`  | `ghcr.io/fjacquet/idrac_exporter`  | 9348 | iDRAC/BMC (Redfish) | ⚠️ `up=0` |
| `obs_exporter`    | `ghcr.io/fjacquet/obs_exporter`    | 9438 | Dell ObjectScale / ECS | ⚠️ `up=0` |
| `nbu_exporter`    | `ghcr.io/fjacquet/nbu_exporter`    | 9440 | NetBackup | ⚠️ `up=0` |
| `ppdd_exporter`   | `ghcr.io/fjacquet/ppdd_exporter`   | 9441 | PowerProtect DD | ⚠️ `up=0` |
| `ppdm_exporter`   | `ghcr.io/fjacquet/ppdm_exporter`   | 9442 | PowerProtect DM | ⚠️ `up=0` |
| `pmax_exporter`   | `ghcr.io/fjacquet/pmax_exporter`   | 9443 | PowerMax (Unisphere) | ⚠️ `up=0` |
| `pscale_exporter` | `ghcr.io/fjacquet/pscale_exporter` | 9444 | PowerScale (OneFS) | ⚠️ `up=0` |
| `pflex_exporter`  | `ghcr.io/fjacquet/pflex_exporter`  | 9445 | PowerFlex | ⚠️ `up=0` |
| `pstore_exporter` | `ghcr.io/fjacquet/pstore_exporter` | 9446 | PowerStore | ⚠️ `up=0` |
| `nsr_exporter`    | `ghcr.io/fjacquet/nsr_exporter`    | 9447 | NetWorker | ⚠️ `up=0` |

Notes:
- **`obs` pulls from the `obs_exporter` GitHub repo** (`ghcr.io/fjacquet/obs_exporter`). The old
  local `ecs_exporter` directory is no longer referenced.
- Image tag is pinned per exporter via env var (`IDRAC_TAG`, `PMAX_TAG`, … default `latest`).
- All images are published by each repo's `release.yml` to `ghcr.io/${github.repository}` on `v*` tags.

## 3. Architecture & data flow

```
                 ┌──────────────────────┐
  (on `up`)      │ dashboard-fetcher     │  reads dashboards.manifest.yaml,
                 │ (alpine + curl/jq,    │  GETs raw.githubusercontent.com/<repo>/<ref>/<path>
                 │  runs once → exit 0)  │  ───────────►  [ dashboards ] (named volume)
                 └─────────┬────────────┘                       │
                           │ service_completed_successfully     │ file provider, foldersFromFilesStructure
                           ▼                                     ▼
  10 exporters  ──scrape──►  Prometheus  ──datasource (uid:prometheus)──►  Grafana
   (GHCR images)             (:9090)                                       (:3000, folder per exporter)
   configs/*.yaml + .env
```

- **`dashboard-fetcher`** — one-shot init service. Reads the manifest, downloads each dashboard
  JSON into the shared named volume `dashboards`, one subfolder per exporter, then exits 0.
- **Grafana** waits via `depends_on: { dashboard-fetcher: { condition: service_completed_successfully } }`,
  then provisions from the `dashboards` volume. Datasource `uid: prometheus` and the dashboard
  provider (`foldersFromFilesStructure: true`) are unchanged from today.
- **Prometheus** scrapes each exporter by Docker service name at its canonical port.

## 4. The dashboards manifest

`dashboards.manifest.yaml` (committed) is the single source of truth for what to fetch — replacing
the brittle bind-mounts and fixing the already-broken `pstore` paths (`grafana/block`, `grafana/file`
no longer exist upstream; it is now `grafana/dashboards/`).

```yaml
# ref defaults to the repo default branch (main); override per exporter when needed.
# A path ending in "/" means "every *.json in that directory" (resolved via GitHub contents API).
exporters:
  idrac:  { repo: fjacquet/idrac_exporter,  paths: [grafana/idrac.json, grafana/idrac_overview.json, grafana/pdu.json, grafana/status-alternative.json] }
  obs:    { repo: fjacquet/obs_exporter,    paths: [grafana/dashboards/] }
  nbu:    { repo: fjacquet/nbu_exporter,    paths: [grafana/] }
  ppdd:   { repo: fjacquet/ppdd_exporter,   paths: [grafana/dashboards/] }
  ppdm:   { repo: fjacquet/ppdm_exporter,   paths: [grafana/dashboards/] }
  pmax:   { repo: fjacquet/pmax_exporter,   paths: [grafana/dashboards/] }
  pscale: { repo: fjacquet/pscale_exporter, paths: [grafana/dashboards/] }
  pflex:  { repo: fjacquet/pflex_exporter,  paths: [grafana/gen1/, grafana/gen2/] }
  pstore: { repo: fjacquet/pstore_exporter, paths: [grafana/dashboards/] }
  nsr:    { repo: fjacquet/nsr_exporter,    paths: [grafana/dashboards/] }
```

> The exact `paths` per repo are finalized during implementation by inspecting each repo's
> default branch (the values above reflect current layout; `nbu` keeps dashboards at `grafana/`).

**Fetch script** (`scripts/fetch-dashboards.sh`, run inside the fetcher container):
- For each exporter, for each path: if it ends in `/`, list it via `GET /repos/<repo>/contents/<path>?ref=<ref>`
  and download each `.json`; otherwise download the single file from `raw.githubusercontent.com`.
- Writes to `/dashboards/<exporter>/<file>.json` in the shared volume.
- Optional `GITHUB_TOKEN` env (from `.env`) is sent as a bearer token to lift the unauthenticated
  GitHub API rate limit; works without it for public repos.

**Failure handling (deliberate):** a single failed file/repo logs a **warning and continues** — a
missing dashboard must never block the stack from coming up. The script exits non-zero only if
**every** fetch failed (e.g. no network), which fails the `dashboard-fetcher` and surfaces clearly.
This trade-off favors "stack always starts" over all-or-nothing strictness.

## 5. Configs & secrets

- `configs/<exporter>.yaml` — **committed, generic**. Every exporter already supports `${VAR}`
  expansion at load time, so these contain no secrets — only env references and the canonical
  `server.port` from §2. (10 files.)
- `.env.example` — committed. Contains, per exporter, the `*_HOSTNAME`/`*_GATEWAY`/`*_USERNAME`/
  `*_PASSWORD`/`*_APIKEY` placeholders, the image `*_TAG` overrides, Grafana admin creds, an optional
  `DASHBOARD_REF` global override, and an optional `GITHUB_TOKEN`.
- `.env` — **gitignored**, holds real values.
- `.gitignore` — adds `.env`, `.DS_Store`.

## 6. Naming & cleanup

- The project is **`exporter_stack`** everywhere; the `all_exporter` alias and `cd all_exporter`
  instruction are removed.
- Container names use the **`es_`** prefix (e.g. `es_prometheus`, `es_pmax_exporter`), replacing `au_`.
- `CLAUDE.md` is updated to reflect the new GHCR-based, mock-free, dashboards-from-GitHub model
  (the current CLAUDE.md describes the old build-from-source stack and must not go stale).

## 7. Public documentation

- **README.md** — rewritten for a public audience: what the stack is (one-command Prometheus +
  Grafana observability for the Dell/Veritas exporter family), quick start
  (`cp .env.example .env` → `docker compose up -d`), the fleet table (§2), the "dashboards are always
  pulled fresh from upstream, never vendored" model, how to point at real targets, the ports, the
  `up=0`-until-configured expectation, and troubleshooting (`docker compose logs dashboard-fetcher`).
- **CHANGELOG.md** — [Keep a Changelog] + SemVer, starting at **`0.1.0`** describing this first public
  release: GHCR-based images, `idrac` added, dashboards-from-GitHub, mock backends removed,
  `es_` prefix, MIT license.
- **LICENSE** — **MIT** (matches the exporter family).
- `CONTRIBUTING.md` — deferred (out of scope for this iteration).

## 8. Final repository layout

```
exporter_stack/
├── docker-compose.yml          # 10 GHCR exporters + dashboard-fetcher + prometheus + grafana
├── dashboards.manifest.yaml    # what dashboards to fetch, from where
├── scripts/
│   └── fetch-dashboards.sh     # run by the dashboard-fetcher container
├── configs/
│   └── <exporter>.yaml         # 10 generic, ${VAR}-referencing configs
├── prometheus.yml              # 10 scrape jobs (service:port)
├── grafana/
│   └── provisioning/
│       ├── datasources/datasource.yml   # unchanged (uid: prometheus)
│       └── dashboards/dashboards.yml     # unchanged (foldersFromFilesStructure)
├── .env.example
├── .gitignore
├── CLAUDE.md                   # updated
├── README.md                   # rewritten (public)
├── CHANGELOG.md                # new (Keep a Changelog, 0.1.0)
└── LICENSE                     # new (MIT)
```

## 9. Validation

`docker compose up -d`:
- `dashboard-fetcher` runs, logs each dashboard fetched, exits 0.
- All 10 exporters pull and serve `/metrics`.
- Prometheus → *Status → Targets* shows 10 jobs (green where real creds are set, otherwise `up=0`).
- Grafana → one populated dashboard folder per exporter, sourced live from GitHub.

Smoke checks:
- `docker compose logs dashboard-fetcher` lists every JSON fetched (and any warnings).
- `docker compose config` validates compose syntax.
- `docker compose ps` shows all exporters + prometheus + grafana running; `dashboard-fetcher` exited 0.

## 10. Out of scope (YAGNI)

No mock data; no per-repo source builds; no OTLP collector; no alerting rules; no stack-level CI or
release pipeline (this is a compose repo, not a built artifact); the ppdm report extras
(postgres/report/mailpit) remain out of this stack.

## 11. Risks & mitigations

- **Default-branch dashboard drift** (a half-merged/renamed dashboard 404s): the fetcher warns and
  continues; `DASHBOARD_REF` / per-exporter `ref` lets you pin to a known-good tag if needed.
- **GHCR `:latest` availability**: images publish on `v*` tags; if `:latest` is not pushed for a repo,
  pin its `*_TAG` to a released version in `.env`. To be confirmed per repo during implementation.
- **GitHub API rate limits** for directory listing: unauthenticated is usually sufficient for one
  `up`; `GITHUB_TOKEN` lifts the limit if hit.
- **Not a git repo yet**: `exporter_stack` is not currently git-initialized; going public requires
  `git init` + first commit (handled as a follow-up, not in this design's automation).

[Keep a Changelog]: https://keepachangelog.com
