# Evergreen, public `exporter_stack` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert `exporter_stack` into a public, self-contained Docker Compose stack that runs all 10 exporters from GHCR images, fetches every Grafana dashboard live from its authoritative GitHub repo, and ships public docs.

**Architecture:** A one-shot `dashboard-fetcher` (alpine + curl + jq) reads `dashboards.manifest.txt`, downloads each dashboard JSON into a shared named volume, then exits; Grafana waits for it (`service_completed_successfully`) and provisions from that volume. Ten exporter services pull `ghcr.io/fjacquet/<repo>` images, mount committed generic `configs/<exporter>.yaml` (env-var references), and report `up=0` until real creds are set in `.env`.

**Tech Stack:** Docker Compose, Prometheus, Grafana, POSIX `sh`, `curl`, `jq`, GitHub REST + raw URLs.

**Reference spec:** `docs/superpowers/specs/2026-06-16-evergreen-exporter-stack-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `docker-compose.yml` | 10 exporter services (GHCR) + `dashboard-fetcher` + `prometheus` + `grafana`; `es_` container prefix; `dashboards` named volume |
| `dashboards.manifest.txt` | Line-based list: `<exporter> <repo> <ref> <path...>` — what to fetch and from where |
| `scripts/fetch-dashboards.sh` | POSIX script run by the fetcher container; resolves default branch, lists dirs via GitHub API, downloads JSON, warn-and-continue |
| `configs/<exporter>.yaml` | 10 committed, generic configs referencing `${VAR}`; canonical `server.port`; logs → stdout |
| `prometheus.yml` | 10 scrape jobs (`<service>:<port>`) |
| `grafana/provisioning/datasources/datasource.yml` | Unchanged — Prometheus datasource, `uid: prometheus` |
| `grafana/provisioning/dashboards/dashboards.yml` | Unchanged — file provider, `foldersFromFilesStructure` |
| `.env.example` | Committed placeholders: creds, `*_TAG`, Grafana, `DASHBOARD_REF`, `GITHUB_TOKEN` |
| `.gitignore` | `.env`, `.DS_Store` |
| `README.md` | Rewritten, public-facing |
| `CHANGELOG.md` | New — Keep a Changelog, `0.1.0` |
| `LICENSE` | New — MIT |
| `CLAUDE.md` | Updated to the new model |

**Canonical exporter table** (used throughout):

| key | service / job | image (`ghcr.io/fjacquet/…`) | port | container config path | creds env vars |
|---|---|---|---|---|---|
| idrac | `idrac_exporter` | `idrac_exporter` | 9348 | `/etc/prometheus/idrac.yml` | `IDRAC1_HOST`,`IDRAC1_USERNAME`,`IDRAC1_PASSWORD` |
| obs | `obs_exporter` | `obs_exporter` | 9438 | `/etc/obs_exporter/config.yaml` | `OBS1_HOSTNAME`,`OBS1_USERNAME`,`OBS1_PASSWORD` |
| nbu | `nbu_exporter` | `nbu_exporter` | 9440 | `/etc/nbu_exporter/config.yaml` | `NBU1_HOSTNAME`,`NBU1_APIKEY` |
| ppdd | `ppdd_exporter` | `ppdd_exporter` | 9441 | `/etc/ppdd_exporter/config.yaml` | `PPDD1_HOSTNAME`,`PPDD1_USERNAME`,`PPDD1_PASSWORD` |
| ppdm | `ppdm_exporter` | `ppdm_exporter` | 9442 | `/etc/ppdm_exporter/config.yaml` | `PPDM1_HOSTNAME`,`PPDM1_USERNAME`,`PPDM1_PASSWORD` |
| pmax | `pmax_exporter` | `pmax_exporter` | 9443 | `/etc/pmax_exporter/config.yaml` | `PMAX1_HOSTNAME`,`PMAX1_USERNAME`,`PMAX1_PASSWORD` |
| pscale | `pscale_exporter` | `pscale_exporter` | 9444 | `/etc/pscale_exporter/config.yaml` | `PSCALE1_HOSTNAME`,`PSCALE1_USERNAME`,`PSCALE1_PASSWORD` |
| pflex | `pflex_exporter` | `pflex_exporter` | 9445 | `/etc/pflex_exporter/config.yaml` | `PFLEX1_GATEWAY`,`PFLEX1_USERNAME`,`PFLEX1_PASSWORD` |
| pstore | `pstore_exporter` | `pstore_exporter` | 9446 | `/etc/pstore_exporter/config.yaml` | `PSTORE1_HOSTNAME`,`PSTORE1_USERNAME`,`PSTORE1_PASSWORD` |
| nsr | `nsr_exporter` | `nsr_exporter` | 9447 | `/etc/nsr_exporter/config.yaml` | `NSR1_HOST`,`NSR1_USERNAME`,`NSR1_PASSWORD` |

`command` for every exporter except idrac is `["--config", "<container config path>"]`. idrac reads `/etc/prometheus/idrac.yml` by default (no command).

---

## Task 1: Initialize repo, .gitignore, LICENSE

**Files:**
- Create: `.gitignore`, `LICENSE`
- Init: git repository (currently not a git repo)

- [ ] **Step 1: Initialize git on `main`**

Run:
```bash
cd /Users/fjacquet/Projects/exporter_stack
git init -b main
```
Expected: `Initialized empty Git repository in .../exporter_stack/.git/`

- [ ] **Step 2: Create `.gitignore`**

Create `.gitignore`:
```gitignore
# Local secrets / real targets
.env

# macOS
.DS_Store
**/.DS_Store

# Dashboards are fetched at runtime, never committed
/grafana/dashboards/
```

- [ ] **Step 3: Create `LICENSE` (MIT)**

Create `LICENSE`:
```text
MIT License

Copyright (c) 2026 Fred Jacquet

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 4: Verify and commit**

Run:
```bash
git add .gitignore LICENSE && git status --short
```
Expected: both files staged (`A  .gitignore`, `A  LICENSE`).
```bash
git commit -m "chore: init repo, add MIT license and .gitignore"
```

---

## Task 2: Generic exporter configs

Copy each sibling repo's `config.yaml` (already uses `${VAR}` and the canonical port) into `configs/`, then route file logging to stdout and parameterize the NetWorker host. **Source repos must be checked out at `../<repo>`.**

**Files:**
- Create: `configs/{idrac,obs,nbu,ppdd,ppdm,pmax,pscale,pflex,pstore,nsr}.yaml`

- [ ] **Step 1: Copy configs from sibling repos**

Run:
```bash
cd /Users/fjacquet/Projects/exporter_stack
mkdir -p configs
cp ../idrac_exporter/config.yaml  configs/idrac.yaml
cp ../ecs_exporter/config.yaml    configs/obs.yaml
cp ../nbu_exporter/config.yaml    configs/nbu.yaml
cp ../ppdd_exporter/config.yaml   configs/ppdd.yaml
cp ../ppdm_exporter/config.yaml   configs/ppdm.yaml
cp ../pmax_exporter/config.yaml   configs/pmax.yaml
cp ../pscale_exporter/config.yaml configs/pscale.yaml
cp ../pflex_exporter/config.yaml  configs/pflex.yaml
cp ../pstore_exporter/config.yaml configs/pstore.yaml
cp ../nsr_exporter/config.yaml    configs/nsr.yaml
```

- [ ] **Step 2: Route file logging to stdout (pflex, pscale)**

Run:
```bash
sed -i '' 's#logName: "/var/log/pflex_exporter/pflex-exporter.log"#logName: "stdout"#' configs/pflex.yaml
sed -i '' 's#logName: "/var/log/pscale_exporter/pscale-exporter.log"#logName: "stdout"#' configs/pscale.yaml
```
(macOS BSD `sed` requires the `''` after `-i`.)

- [ ] **Step 3: Parameterize the NetWorker host**

Run:
```bash
sed -i '' 's#host: "https://networker-prod-01.local:9090"#host: "${NSR1_HOST}"#' configs/nsr.yaml
```

- [ ] **Step 4: Verify no log-file paths and no secrets remain**

Run:
```bash
grep -rn "/var/log" configs/ ; echo "exit: $?"
```
Expected: no matches, `exit: 1`.
```bash
grep -rnE 'password:|apiKey:' configs/ | grep -vE '\$\{|#'
```
Expected: no output (every credential field is a `${VAR}` reference or a comment).

- [ ] **Step 5: Verify canonical ports are present**

Run:
```bash
for f in idrac:9348 obs:9438 nbu:9440 ppdd:9441 ppdm:9442 pmax:9443 pscale:9444 pflex:9445 pstore:9446 nsr:9447; do
  k="${f%%:*}"; p="${f#*:}"; grep -q "port: \"\?$p" "configs/$k.yaml" && echo "ok $k $p" || echo "MISSING $k $p"
done
```
Expected: ten `ok` lines, no `MISSING`.

- [ ] **Step 6: Commit**

```bash
git add configs/ && git commit -m "feat: add generic per-exporter configs (env-referenced, stdout logging)"
```

---

## Task 3: `.env.example`

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Write `.env.example`**

Create `.env.example`:
```bash
# Copy to .env and fill in to point exporters at real targets.
#   cp .env.example .env && docker compose up -d
# Unset creds are fine: exporters still start and expose /metrics with up=0.
# .env is gitignored; this file is committed with placeholders only.

# --- Grafana (http://localhost:3000) ---
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=admin

# --- Dashboard fetcher ---
# Git ref to fetch dashboards from. "default" = each repo's default branch (evergreen).
# Override globally (e.g. a tag) or per-exporter in dashboards.manifest.txt.
DASHBOARD_REF=default
# Optional: a GitHub token lifts the unauthenticated API rate limit (public repos work without it).
GITHUB_TOKEN=

# --- Image tags (default: latest) ---
IDRAC_TAG=latest
OBS_TAG=latest
NBU_TAG=latest
PPDD_TAG=latest
PPDM_TAG=latest
PMAX_TAG=latest
PSCALE_TAG=latest
PFLEX_TAG=latest
PSTORE_TAG=latest
NSR_TAG=latest

# --- iDRAC / BMC (Redfish) ---
IDRAC1_HOST=192.168.1.1
IDRAC1_USERNAME=root
IDRAC1_PASSWORD=

# --- ObjectScale / ECS ---
OBS1_HOSTNAME=objectscale01.example.com
OBS1_USERNAME=obs-monitor
OBS1_PASSWORD=

# --- NetBackup ---
NBU1_HOSTNAME=master.my.domain
NBU1_APIKEY=

# --- PowerProtect DD ---
PPDD1_HOSTNAME=ppdd01.example.com
PPDD1_USERNAME=ppdd-monitor
PPDD1_PASSWORD=

# --- PowerProtect DM ---
PPDM1_HOSTNAME=ppdm01.example.com
PPDM1_USERNAME=ppdm-monitor
PPDM1_PASSWORD=

# --- PowerMax (Unisphere) ---
PMAX1_HOSTNAME=unisphere01.example.com
PMAX1_USERNAME=pmax-monitor
PMAX1_PASSWORD=

# --- PowerScale (OneFS) ---
PSCALE1_HOSTNAME=pscale-clu1.example.com
PSCALE1_USERNAME=pscale-monitor
PSCALE1_PASSWORD=

# --- PowerFlex ---
PFLEX1_GATEWAY=flex-clu1-gw01
PFLEX1_USERNAME=flex-username
PFLEX1_PASSWORD=

# --- PowerStore ---
PSTORE1_HOSTNAME=10.0.0.1
PSTORE1_USERNAME=admin
PSTORE1_PASSWORD=

# --- NetWorker ---
NSR1_HOST=https://networker-prod-01.local:9090
NSR1_USERNAME=admin
NSR1_PASSWORD=
```

- [ ] **Step 2: Commit**

```bash
git add .env.example && git commit -m "feat: add .env.example with placeholders for all exporters"
```

---

## Task 4: Dashboards manifest

**Files:**
- Create: `dashboards.manifest.txt`

- [ ] **Step 1: Write `dashboards.manifest.txt`**

Create `dashboards.manifest.txt`:
```text
# <exporter>  <repo>                     <ref>     <path...>
# ref "default" = repo default branch.  A path ending in "/" = every *.json at or below that dir (recursive).
idrac    fjacquet/idrac_exporter   default  grafana/idrac.json grafana/idrac_overview.json grafana/pdu.json grafana/status-alternative.json
obs      fjacquet/obs_exporter     default  grafana/dashboards/
nbu      fjacquet/nbu_exporter     default  grafana/
ppdd     fjacquet/ppdd_exporter    default  grafana/dashboards/
ppdm     fjacquet/ppdm_exporter    default  grafana/dashboards/
pmax     fjacquet/pmax_exporter    default  grafana/dashboards/
pscale   fjacquet/pscale_exporter  default  grafana/provisioning/dashboards/json/
pflex    fjacquet/pflex_exporter   default  grafana/gen1/ grafana/gen2/
pstore   fjacquet/pstore_exporter  default  grafana/dashboards/
nsr      fjacquet/nsr_exporter     default  grafana/dashboards/
```

> Paths verified against each repo's default branch (`main`) on 2026-06-16. pscale's dashboards live under `grafana/provisioning/dashboards/json/`; pstore nests dashboards in subdirectories (block/file/hardware/overview/protection), so the fetcher matches recursively.

- [ ] **Step 2: Commit**

```bash
git add dashboards.manifest.txt && git commit -m "feat: add dashboards manifest (authoritative GitHub sources)"
```

---

## Task 5: Dashboard fetch script (with functional test)

**Files:**
- Create: `scripts/fetch-dashboards.sh`
- Test: manual functional run against real GitHub

- [ ] **Step 1: Write `scripts/fetch-dashboards.sh`**

Create `scripts/fetch-dashboards.sh`:
```sh
#!/bin/sh
# Download Grafana dashboards from each exporter's authoritative GitHub repo into
# $OUT/<exporter>/, one flat folder per exporter. Reads $MANIFEST. Warns and
# continues on per-item failure; exits non-zero only if NOTHING was fetched.
#
# Dir paths (trailing "/") are matched RECURSIVELY via the git trees API, so nested
# dashboard subdirectories (e.g. pstore block/file/...) are included. Destination
# filenames are flattened (repo path under "grafana/", "/" -> "__") so files from
# different subdirectories never collide (e.g. pflex gen1 vs gen2 share basenames).
set -u

MANIFEST="${MANIFEST:-/manifest/dashboards.manifest.txt}"
OUT="${OUT:-/dashboards}"
API="https://api.github.com"
RAW="https://raw.githubusercontent.com"
GLOBAL_REF="${DASHBOARD_REF:-default}"

gh_get() { # url -> body on stdout
  curl -fsSL -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$1"
}

resolve_ref() { # repo ref -> concrete ref
  _repo="$1"; _ref="$2"
  if [ "$_ref" = "default" ] || [ -z "$_ref" ] || [ "$_ref" = "-" ]; then
    _db=$(gh_get "$API/repos/$_repo" | jq -r '.default_branch // empty' 2>/dev/null)
    [ -n "$_db" ] && echo "$_db" || echo "main"
  else
    echo "$_ref"
  fi
}

list_dir() { # repo ref prefix/ -> repo-relative .json paths at or below prefix (recursive)
  _repo="$1"; _ref="$2"; _prefix="$3"
  gh_get "$API/repos/$_repo/git/trees/$_ref?recursive=1" \
    | jq -r --arg p "$_prefix" '.tree[]
        | select(.type=="blob") | .path
        | select(startswith($p)) | select(endswith(".json"))' 2>/dev/null
}

flatname() { # repo-path -> filename: strip leading grafana/, replace "/" with "__"
  printf '%s' "${1#grafana/}" | sed 's#/#__#g'
}

total=0; ok=0
rm -rf "${OUT:?}/"* 2>/dev/null || true

while read -r name repo ref paths || [ -n "${name:-}" ]; do
  case "$name" in ""|\#*) continue ;; esac
  [ "$GLOBAL_REF" != "default" ] && ref="$GLOBAL_REF"
  rref=$(resolve_ref "$repo" "$ref")
  dest="$OUT/$name"; mkdir -p "$dest"
  for path in $paths; do
    case "$path" in
      */) files=$(list_dir "$repo" "$rref" "$path") ;;
      *)  files="$path" ;;
    esac
    for f in $files; do
      [ -z "$f" ] && continue
      total=$((total + 1))
      if curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
           "$RAW/$repo/$rref/$f" -o "$dest/$(flatname "$f")"; then
        ok=$((ok + 1)); echo "ok   $name  $repo@$rref  $f"
      else
        echo "WARN failed: $name  $repo@$rref  $f" >&2
      fi
    done
  done
done < "$MANIFEST"

echo "fetched $ok/$total dashboards"
[ "$ok" -gt 0 ] || { echo "ERROR: no dashboards fetched" >&2; exit 1; }
```

- [ ] **Step 2: Syntax check**

Run:
```bash
sh -n scripts/fetch-dashboards.sh && echo "syntax ok"
```
Expected: `syntax ok`

- [ ] **Step 3: Functional test against real GitHub (single file, recursion, collision)**

Requires `curl` and `jq` locally. Uses a temp manifest exercising all three behaviors: a single explicit file (idrac), a recursive nested dir (pstore subdirs), and two dirs with shared basenames (pflex gen1/gen2 — must NOT collide).

Run:
```bash
tmp=$(mktemp -d)
cat > "$tmp/m.txt" <<'EOF'
idrac  fjacquet/idrac_exporter  default  grafana/idrac.json
pstore fjacquet/pstore_exporter default  grafana/dashboards/
pflex  fjacquet/pflex_exporter  default  grafana/gen1/ grafana/gen2/
EOF
MANIFEST="$tmp/m.txt" OUT="$tmp/out" sh scripts/fetch-dashboards.sh
echo "--- idrac ---"; ls -1 "$tmp/out/idrac/"
echo "--- pstore count ---"; ls -1 "$tmp/out/pstore/" | wc -l
echo "--- pstore has subdir-flattened name? ---"; ls "$tmp/out/pstore/" | grep -c '__'
echo "--- pflex collision check (both must exist) ---"; ls "$tmp/out/pflex/gen1__01-cluster-overview.json" "$tmp/out/pflex/gen2__01-cluster-overview.json"
```
Expected: idrac shows `idrac.json`; pstore count is 11; pstore has ≥10 names containing `__` (e.g. `dashboards__block__02-appliances.json`); both pflex `gen1__01-cluster-overview.json` and `gen2__01-cluster-overview.json` exist (proves no collision).

- [ ] **Step 4: Verify a downloaded file is valid JSON**

Run:
```bash
jq -e . "$tmp/out/idrac/idrac.json" >/dev/null && echo "valid json"; rm -rf "$tmp"
```
Expected: `valid json`

- [ ] **Step 5: Commit**

```bash
git add scripts/fetch-dashboards.sh && git commit -m "feat: add dashboard fetch script (recursive trees API, flattened names, warn-and-continue)"
```

---

## Task 6: Prometheus scrape config

**Files:**
- Modify (overwrite): `prometheus.yml`

- [ ] **Step 1: Overwrite `prometheus.yml`**

Replace the entire contents of `prometheus.yml` with:
```yaml
global:
  scrape_interval: 30s
  scrape_timeout: 15s

# One Prometheus scrapes every exporter by Docker service name on the shared network.
scrape_configs:
  - job_name: idrac_exporter
    static_configs: [{ targets: ['idrac_exporter:9348'] }]
  - job_name: obs_exporter
    static_configs: [{ targets: ['obs_exporter:9438'] }]
  - job_name: nbu_exporter
    static_configs: [{ targets: ['nbu_exporter:9440'] }]
  - job_name: ppdd_exporter
    static_configs: [{ targets: ['ppdd_exporter:9441'] }]
  - job_name: ppdm_exporter
    static_configs: [{ targets: ['ppdm_exporter:9442'] }]
  - job_name: pmax_exporter
    static_configs: [{ targets: ['pmax_exporter:9443'] }]
  - job_name: pscale_exporter
    static_configs: [{ targets: ['pscale_exporter:9444'] }]
  - job_name: pflex_exporter
    static_configs: [{ targets: ['pflex_exporter:9445'] }]
  - job_name: pstore_exporter
    static_configs: [{ targets: ['pstore_exporter:9446'] }]
  - job_name: nsr_exporter
    static_configs: [{ targets: ['nsr_exporter:9447'] }]
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('prometheus.yml')); print('jobs:', len(d['scrape_configs']))"
```
Expected: `jobs: 10`

- [ ] **Step 3: Commit**

```bash
git add prometheus.yml && git commit -m "feat: prometheus scrape config for all 10 exporters"
```

---

## Task 7: docker-compose.yml (the core)

**Files:**
- Modify (overwrite): `docker-compose.yml`
- Verify (no change): `grafana/provisioning/datasources/datasource.yml`, `grafana/provisioning/dashboards/dashboards.yml`

- [ ] **Step 1: Confirm Grafana provisioning files are intact**

Run:
```bash
grep -q 'uid: prometheus' grafana/provisioning/datasources/datasource.yml && \
grep -q 'foldersFromFilesStructure' grafana/provisioning/dashboards/dashboards.yml && echo "provisioning ok"
```
Expected: `provisioning ok` (these files are reused unchanged).

- [ ] **Step 2: Overwrite `docker-compose.yml`**

Replace the entire contents of `docker-compose.yml` with:
```yaml
---
# exporter_stack — public, self-contained observability for the exporter family.
#
#   cp .env.example .env        # set creds to point at real targets (optional)
#   docker compose up -d
#
#   Grafana     http://localhost:3000   (admin/admin)
#   Prometheus  http://localhost:9090   (Status > Targets)
#
# Exporters pull published GHCR images. Dashboards are fetched fresh from each
# exporter's authoritative GitHub repo at startup (never vendored here).
# Targets report up=0 until real creds are set in .env.

services:
  # ===================== dashboard fetcher (one-shot) =====================
  dashboard-fetcher:
    image: alpine:3.20
    container_name: es_dashboard_fetcher
    command: ["sh", "-c", "apk add --no-cache curl jq >/dev/null && sh /scripts/fetch-dashboards.sh"]
    environment:
      - DASHBOARD_REF=${DASHBOARD_REF:-default}
      - GITHUB_TOKEN=${GITHUB_TOKEN:-}
    volumes:
      - ./scripts:/scripts:ro
      - ./dashboards.manifest.txt:/manifest/dashboards.manifest.txt:ro
      - dashboards:/dashboards
    networks: [exporters]
    restart: "no"

  # ===================== exporters (GHCR images) =====================
  idrac_exporter:
    image: ghcr.io/fjacquet/idrac_exporter:${IDRAC_TAG:-latest}
    container_name: es_idrac_exporter
    volumes:
      - ./configs/idrac.yaml:/etc/prometheus/idrac.yml:ro
    environment:
      - IDRAC1_HOST=${IDRAC1_HOST:-192.168.1.1}
      - IDRAC1_USERNAME=${IDRAC1_USERNAME:-root}
      - IDRAC1_PASSWORD=${IDRAC1_PASSWORD:-}
    ports: ["9348:9348"]
    networks: [exporters]
    restart: unless-stopped

  obs_exporter:
    image: ghcr.io/fjacquet/obs_exporter:${OBS_TAG:-latest}
    container_name: es_obs_exporter
    command: ["--config", "/etc/obs_exporter/config.yaml"]
    volumes:
      - ./configs/obs.yaml:/etc/obs_exporter/config.yaml:ro
    environment:
      - OBS1_HOSTNAME=${OBS1_HOSTNAME:-objectscale01.example.com}
      - OBS1_USERNAME=${OBS1_USERNAME:-obs-monitor}
      - OBS1_PASSWORD=${OBS1_PASSWORD:-}
    ports: ["9438:9438"]
    networks: [exporters]
    restart: unless-stopped

  nbu_exporter:
    image: ghcr.io/fjacquet/nbu_exporter:${NBU_TAG:-latest}
    container_name: es_nbu_exporter
    security_opt:
      - no-new-privileges:true
    command: ["--config", "/etc/nbu_exporter/config.yaml"]
    volumes:
      - ./configs/nbu.yaml:/etc/nbu_exporter/config.yaml:ro
    environment:
      - NBU1_HOSTNAME=${NBU1_HOSTNAME:-master.my.domain}
      - NBU1_APIKEY=${NBU1_APIKEY:-}
    ports: ["9440:9440"]
    networks: [exporters]
    restart: unless-stopped

  ppdd_exporter:
    image: ghcr.io/fjacquet/ppdd_exporter:${PPDD_TAG:-latest}
    container_name: es_ppdd_exporter
    command: ["--config", "/etc/ppdd_exporter/config.yaml"]
    volumes:
      - ./configs/ppdd.yaml:/etc/ppdd_exporter/config.yaml:ro
    environment:
      - PPDD1_HOSTNAME=${PPDD1_HOSTNAME:-ppdd01.example.com}
      - PPDD1_USERNAME=${PPDD1_USERNAME:-ppdd-monitor}
      - PPDD1_PASSWORD=${PPDD1_PASSWORD:-}
    ports: ["9441:9441"]
    networks: [exporters]
    restart: unless-stopped

  ppdm_exporter:
    image: ghcr.io/fjacquet/ppdm_exporter:${PPDM_TAG:-latest}
    container_name: es_ppdm_exporter
    command: ["--config", "/etc/ppdm_exporter/config.yaml"]
    volumes:
      - ./configs/ppdm.yaml:/etc/ppdm_exporter/config.yaml:ro
    environment:
      - PPDM1_HOSTNAME=${PPDM1_HOSTNAME:-ppdm01.example.com}
      - PPDM1_USERNAME=${PPDM1_USERNAME:-ppdm-monitor}
      - PPDM1_PASSWORD=${PPDM1_PASSWORD:-}
    ports: ["9442:9442"]
    networks: [exporters]
    restart: unless-stopped

  pmax_exporter:
    image: ghcr.io/fjacquet/pmax_exporter:${PMAX_TAG:-latest}
    container_name: es_pmax_exporter
    command: ["--config", "/etc/pmax_exporter/config.yaml"]
    volumes:
      - ./configs/pmax.yaml:/etc/pmax_exporter/config.yaml:ro
    environment:
      - PMAX1_HOSTNAME=${PMAX1_HOSTNAME:-unisphere01.example.com}
      - PMAX1_USERNAME=${PMAX1_USERNAME:-pmax-monitor}
      - PMAX1_PASSWORD=${PMAX1_PASSWORD:-}
    ports: ["9443:9443"]
    networks: [exporters]
    restart: unless-stopped

  pscale_exporter:
    image: ghcr.io/fjacquet/pscale_exporter:${PSCALE_TAG:-latest}
    container_name: es_pscale_exporter
    command: ["--config", "/etc/pscale_exporter/config.yaml"]
    volumes:
      - ./configs/pscale.yaml:/etc/pscale_exporter/config.yaml:ro
    environment:
      - PSCALE1_HOSTNAME=${PSCALE1_HOSTNAME:-pscale-clu1.example.com}
      - PSCALE1_USERNAME=${PSCALE1_USERNAME:-pscale-monitor}
      - PSCALE1_PASSWORD=${PSCALE1_PASSWORD:-}
    ports: ["9444:9444"]
    networks: [exporters]
    restart: unless-stopped

  pflex_exporter:
    image: ghcr.io/fjacquet/pflex_exporter:${PFLEX_TAG:-latest}
    container_name: es_pflex_exporter
    command: ["--config", "/etc/pflex_exporter/config.yaml"]
    volumes:
      - ./configs/pflex.yaml:/etc/pflex_exporter/config.yaml:ro
    environment:
      - PFLEX1_GATEWAY=${PFLEX1_GATEWAY:-flex-clu1-gw01}
      - PFLEX1_USERNAME=${PFLEX1_USERNAME:-flex-username}
      - PFLEX1_PASSWORD=${PFLEX1_PASSWORD:-}
    ports: ["9445:9445"]
    networks: [exporters]
    restart: unless-stopped

  pstore_exporter:
    image: ghcr.io/fjacquet/pstore_exporter:${PSTORE_TAG:-latest}
    container_name: es_pstore_exporter
    command: ["--config", "/etc/pstore_exporter/config.yaml"]
    volumes:
      - ./configs/pstore.yaml:/etc/pstore_exporter/config.yaml:ro
    environment:
      - PSTORE1_HOSTNAME=${PSTORE1_HOSTNAME:-10.0.0.1}
      - PSTORE1_USERNAME=${PSTORE1_USERNAME:-admin}
      - PSTORE1_PASSWORD=${PSTORE1_PASSWORD:-}
    ports: ["9446:9446"]
    networks: [exporters]
    restart: unless-stopped

  nsr_exporter:
    image: ghcr.io/fjacquet/nsr_exporter:${NSR_TAG:-latest}
    container_name: es_nsr_exporter
    command: ["--config", "/etc/nsr_exporter/config.yaml"]
    volumes:
      - ./configs/nsr.yaml:/etc/nsr_exporter/config.yaml:ro
    environment:
      - NSR1_HOST=${NSR1_HOST:-https://networker-prod-01.local:9090}
      - NSR1_USERNAME=${NSR1_USERNAME:-admin}
      - NSR1_PASSWORD=${NSR1_PASSWORD:-}
    ports: ["9447:9447"]
    networks: [exporters]
    restart: unless-stopped

  # ===================== shared observability =====================
  prometheus:
    image: prom/prometheus:latest
    container_name: es_prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports: ["9090:9090"]
    networks: [exporters]
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: es_grafana
    environment:
      - GF_SECURITY_ADMIN_USER=${GF_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PASSWORD:-admin}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - dashboards:/var/lib/grafana/dashboards
    ports: ["3000:3000"]
    networks: [exporters]
    depends_on:
      dashboard-fetcher:
        condition: service_completed_successfully
      prometheus:
        condition: service_started
    restart: unless-stopped

networks:
  exporters:
    driver: bridge

volumes:
  dashboards:
```

- [ ] **Step 3: Validate compose syntax**

Run:
```bash
docker compose config >/dev/null && echo "compose valid"
```
Expected: `compose valid` (no errors; warnings about a missing `.env` are fine).

- [ ] **Step 4: Confirm service inventory**

Run:
```bash
docker compose config --services | sort
```
Expected (13 lines): `dashboard-fetcher`, `grafana`, `idrac_exporter`, `nbu_exporter`, `nsr_exporter`, `obs_exporter`, `pflex_exporter`, `pmax_exporter`, `ppdd_exporter`, `ppdm_exporter`, `prometheus`, `pscale_exporter`, `pstore_exporter`.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml && git commit -m "feat: GHCR-based compose with dashboard-fetcher, no mocks, es_ prefix"
```

---

## Task 8: End-to-end validation

**Files:** none (runtime verification; may produce a fix to `dashboards.manifest.txt`)

- [ ] **Step 1: Create `.env` and start the stack**

Run:
```bash
cp .env.example .env
docker compose up -d
```
Expected: images pull; `es_dashboard_fetcher` runs and exits 0; all exporters + prometheus + grafana start.

- [ ] **Step 2: Verify the fetcher succeeded**

Run:
```bash
docker compose logs dashboard-fetcher | tail -20
```
Expected: per-file `ok ...` lines and a final `fetched N/N dashboards` with N>0. Investigate any `WARN failed:` lines — a 404 means that repo's default branch uses a different path; fix the path in `dashboards.manifest.txt`, then `docker compose up -d --force-recreate dashboard-fetcher grafana` and re-check.

- [ ] **Step 3: Verify Prometheus sees all 10 targets**

Run:
```bash
curl -s 'http://localhost:9090/api/v1/targets' | jq -r '.data.activeTargets[].labels.job' | sort -u
```
Expected: the 10 exporter job names. (`up=0` is expected for targets without real creds.)

- [ ] **Step 4: Verify Grafana provisioned dashboard folders**

Run:
```bash
sleep 10
curl -s -u admin:admin 'http://localhost:3000/api/search?type=dash-db' | jq -r '.[].folderTitle' | sort -u
```
Expected: one folder per exporter that returned dashboards (folder names come from `foldersFromFilesStructure`, e.g. `idrac`, `obs`, `pflex-gen1`…).

- [ ] **Step 5: Tear down**

Run:
```bash
docker compose down
```
Expected: all `es_*` containers removed.

- [ ] **Step 6: Commit any manifest fixes**

```bash
git add -A && git commit -m "fix: align dashboard manifest paths with upstream default branches" || echo "no fixes needed"
```

---

## Task 9: Public docs (README, CHANGELOG) and CLAUDE.md

**Files:**
- Modify (overwrite): `README.md`, `CLAUDE.md`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Overwrite `README.md`**

Replace the entire contents of `README.md` with:
```markdown
# exporter_stack

One `docker compose` that runs the whole family of Prometheus exporters behind a single
Prometheus + Grafana. Exporter images are pulled from GitHub Container Registry; Grafana
dashboards are fetched **fresh from each exporter's own GitHub repo** at startup — never
vendored here, so they never go stale.

## Quick start

```bash
cp .env.example .env        # optional: set creds to point at real targets
docker compose up -d
```

- **Grafana** → http://localhost:3000 (`admin`/`admin`) — one dashboard folder per exporter
- **Prometheus** → http://localhost:9090 → *Status → Targets*

Targets report `up=0` until you set real credentials in `.env`. The stack still starts,
pulls every image, and provisions dashboards without any hardware.

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

## Configuring real targets

Each exporter reads `configs/<exporter>.yaml`, which references environment variables for
hosts and credentials. Set those in `.env` (gitignored) — see `.env.example` for the full
list. For multi-instance monitoring, edit the relevant `configs/<exporter>.yaml` directly.

Pin an image version per exporter with its `*_TAG` variable (e.g. `PFLEX_TAG=0.2.1`).

## How dashboards stay evergreen

On every `up`, the one-shot `dashboard-fetcher` reads `dashboards.manifest.txt` and downloads
each dashboard JSON from the repo's default branch into a shared volume that Grafana
provisions. Override the ref globally with `DASHBOARD_REF` or per-exporter in the manifest.
Set `GITHUB_TOKEN` in `.env` if you hit GitHub's unauthenticated API rate limit.

Inspect a run: `docker compose logs dashboard-fetcher`.

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Create `CHANGELOG.md`**

Create `CHANGELOG.md`:
```markdown
# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-16

First public release.

### Added
- `idrac_exporter` to the stack (10 exporters total).
- `dashboard-fetcher`: dashboards are fetched fresh from each exporter's authoritative
  GitHub repo at startup via `dashboards.manifest.txt` (no vendored copies).
- Committed generic `configs/<exporter>.yaml` referencing environment variables; real
  values supplied via `.env`.
- Public docs: README, this CHANGELOG, and an MIT LICENSE.

### Changed
- Exporters now run from published GHCR images (`ghcr.io/fjacquet/<repo>`) instead of
  building from sibling source repos. No sibling checkouts required.
- Container names use the `es_` prefix.

### Removed
- Mock backends (`mocknw`, `mockdd`, `mockppdm`, `mockecs`) and all build-from-source
  contexts. Every exporter targets real hardware and reports `up=0` until configured.
- Host-port remapping — each exporter now listens on a unique port (9348, 9438, 9440–9447).
```

- [ ] **Step 3: Overwrite `CLAUDE.md`**

Replace the entire contents of `CLAUDE.md` with:
```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **public, self-contained Docker Compose stack**, not a Go exporter. It runs all 10 of
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
- Targets report `up=0` until real creds are set in `.env` — expected, not a failure.

## Architecture (spans multiple files)

- **`docker-compose.yml`** — 10 exporter services pulling `ghcr.io/fjacquet/<repo>`, plus a
  one-shot `dashboard-fetcher`, Prometheus, and Grafana. Container names use the `es_` prefix.
- **`dashboard-fetcher`** — alpine + curl + jq running `scripts/fetch-dashboards.sh`, which
  reads `dashboards.manifest.txt`, resolves each repo's default branch, lists dashboard dirs
  via the GitHub API, downloads JSON into the `dashboards` named volume, then exits 0. Grafana
  waits on `condition: service_completed_successfully`. The script warns-and-continues on a
  per-file failure and only fails if nothing was fetched.
- **`configs/<exporter>.yaml`** — committed, generic, reference `${VAR}`; real values come from
  `.env`. Each sets the exporter's canonical `server.port`; file logging is routed to stdout.
- **Ports** — each exporter listens on a unique port: idrac 9348, obs 9438, nbu 9440,
  ppdd 9441, ppdm 9442, pmax 9443, pscale 9444, pflex 9445, pstore 9446, nsr 9447. A port
  change must be edited in `docker-compose.yml`, `prometheus.yml`, and the README table.

## Gotchas

- **`obs` ≠ `ecs`**: the `obs_exporter` service/image comes from the GitHub repo
  `fjacquet/obs_exporter` (the old local `ecs_exporter` dir is no longer referenced).
- **idrac config path differs**: mounted at `/etc/prometheus/idrac.yml`, not
  `/etc/<exporter>/config.yaml`, and idrac takes no `--config` flag.
- Dashboards track each repo's **default branch**. If a dashboard 404s in the fetcher logs,
  the path moved upstream — fix it in `dashboards.manifest.txt`.
- `.env` and `grafana/dashboards/` are gitignored; never commit secrets or vendored dashboards.
```

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md CLAUDE.md && git commit -m "docs: public README, CHANGELOG 0.1.0, updated CLAUDE.md"
```

---

## Self-Review (completed during planning)

**Spec coverage:** GHCR images (Task 7) ✓; drop mocks/builds (Task 7) ✓; add idrac (Tasks 2,4,7) ✓; init-container dashboard fetch (Tasks 5,7) ✓; default-branch ref with override (Tasks 4,5) ✓; manifest (Task 4) ✓; committed generic configs + .env (Tasks 2,3) ✓; `es_` prefix + drop `all_exporter` (Tasks 7,9) ✓; README/CHANGELOG/MIT LICENSE (Tasks 1,9) ✓; Grafana provisioning reuse (Task 7) ✓; prometheus 10 jobs (Task 6) ✓; validation incl. `up=0` and fetcher logs (Task 8) ✓; git init follow-up (Task 1) ✓.

**Deviation from spec:** the manifest is `dashboards.manifest.txt` (line-based) rather than `.yaml`, so the fetcher parses it with POSIX `sh` (no YAML dependency in the alpine container). Same content and intent.

**Placeholder scan:** none — every file's full content is inline; every command has expected output.

**Type/name consistency:** service names, job names, ports, image names, config mount paths, and env-var names are identical across the canonical table, `configs/`, `prometheus.yml`, `docker-compose.yml`, and docs.

**Known runtime risk (handled in Task 8):** dashboard `paths` reflect the current upstream layout; if a default branch differs, the fetcher warns and Step 6 commits the manifest fix.
```
