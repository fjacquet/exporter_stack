# Stack Expansion Implementation Plan

> **Reconciled post-implementation** (image substitutions, up-semantics, `BackendDown` rule) — see CLAUDE.md gotchas.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 16 community Prometheus exporters (+ a document-only Windows stub) and a self-contained Alertmanager demo to the existing `exporter_stack` Docker Compose project.

**Architecture:** New exporters are a "second lane" of upstream community images running idle (`up=0`) beside the existing 14 `ghcr.io/fjacquet/*` services; node_exporter runs live. The dashboard fetcher gains a grafana.com source. Prometheus rules → a new Alertmanager → a webhook-logger container demonstrate the full alerting path, firing on the idle `up=0` targets with no fake data.

**Tech Stack:** Docker Compose, Prometheus, Alertmanager, Grafana, POSIX `sh` + `curl` + `jq` (dashboard fetcher), `promtool`/`amtool` (validation).

## Global Constraints

- Container names use the `es_` prefix; service names are `<exporter>_exporter`. — verbatim from spec.
- Every service: `networks: [exporters]`, `restart: unless-stopped`, image tag overridable via `${<NAME>_TAG:-latest}`.
- Idle exporters point at fictional targets with placeholder creds (`changeme`, `*.example.com`) and must report `up=0` — real values come from `.env` (gitignored). node_exporter is the only live exporter.
- Ports are each exporter's upstream default; host port == container port. Reserved/in-use: 9090, 3000, 9093, 9095, 9105–9107, 9221, 9348, 9438–9447, and the new set (9100, 9101, 9104, 9113, 9117, 9121, 9128, 9182, 9187, 9216, 9242, 9255, 9308, 9419, 9713, 8080, 4000).
- A new exporter is edited in up to 5 places: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md` table, `.env.example`.
- Dashboard fetcher must preserve warn-and-continue per item and "exit non-zero only if nothing fetched".
- `${VAR}` must NOT appear in nsr-style config comments — not relevant to new files, but keep configs generic referencing `${VAR}` only where the exporter reads env.
- Commit after every task with a `feat:`/`docs:`/`chore:` message.

---

## File Structure

**New files**
- `configs/mysqld.cnf` — my.cnf client creds for mysqld_exporter.
- `configs/ceph.conf`, `configs/ceph.keyring` — placeholder Ceph cluster config + keyring.
- `configs/gluster-exporter.toml` — gluster-prometheus config.
- `alertmanager.yml` — Alertmanager routing + receivers.
- `alertmanager/templates/notification.tmpl` — example notification template (reference).
- `rules/alerts.yml` — Prometheus alert rules.
- `docs/alertmanager.md` — concept + usage doc.

**Modified files**
- `docker-compose.yml` — 16 exporter services + `alertmanager` + `webhook-logger`; `rules` mount on prometheus.
- `prometheus.yml` — 16 scrape jobs, 1 commented Windows job, `alerting:`, `rule_files:`.
- `dashboards.manifest.txt` — `gcom:` rows for dashboards.
- `scripts/fetch-dashboards.sh` — grafana.com (`gcom:<id>`) branch.
- `README.md` — exporter/ports table rows + Alertmanager section.
- `.env.example` — image-tag vars + credential placeholders.
- `CLAUDE.md` — new gotchas (mysql DSN, fail-fast children, gluster legacy, alerting, ports).

---

## Task 1: Extend the dashboard fetcher for grafana.com

**Files:**
- Modify: `scripts/fetch-dashboards.sh`

**Interfaces:**
- Produces: a `gcom:<id>` path token understood by the fetcher; downloads to `$OUT/<name>/<id>.json`, `__inputs`/`__requires` stripped and the prometheus datasource variable rewritten to `prometheus`.

- [ ] **Step 1: Add the grafana.com constant and helper.** Insert after the `RAW=...` line (near line 15) the constant, and after the `flatname()` function (near line 43) the helper:

```sh
GCOM="https://grafana.com/api/dashboards"
```

```sh
fetch_gcom() { # id destfile -> 0 on success, writes normalised dashboard JSON
  _id="$1"; _out="$2"
  _rev=$(curl -fsSL "$GCOM/$_id" | jq -r '.revision // empty' 2>/dev/null)
  [ -n "$_rev" ] || return 1
  _raw=$(curl -fsSL "$GCOM/$_id/revisions/$_rev/download") || return 1
  [ -n "$_raw" ] || return 1
  _dsvar=$(printf '%s' "$_raw" \
    | jq -r '(.__inputs // [])[] | select(.pluginId=="prometheus") | .name' 2>/dev/null \
    | head -n1)
  [ -n "$_dsvar" ] || _dsvar="DS_PROMETHEUS"
  printf '%s' "$_raw" \
    | jq 'del(.__inputs, .__requires)' \
    | sed "s/\${$_dsvar}/prometheus/g" > "$_out" 2>/dev/null || return 1
  [ -s "$_out" ] || return 1
  return 0
}
```

- [ ] **Step 2: Branch on the `gcom:` token in the path loop.** In the `for path in $paths; do` block, change the `case "$path" in` so the first arm handles gcom (before the `*/` and `*` arms):

```sh
    case "$path" in
      gcom:*)
        total=$((total + 1))
        _gid=${path#gcom:}
        if fetch_gcom "$_gid" "$dest/$_gid.json"; then
          ok=$((ok + 1)); echo "ok   $name  grafana.com/$_gid"
        else
          echo "WARN failed: $name  grafana.com/$_gid" >&2
        fi
        continue ;;
      */) files=$(list_dir "$repo" "$rref" "$path") ;;
      *)  files="$path" ;;
    esac
```

- [ ] **Step 3: Run the fetcher against a real grafana.com ID to verify normalisation.**

Run:
```bash
rm -rf /tmp/es-dash-test && mkdir -p /tmp/es-dash-test
docker run --rm -v "$PWD/scripts:/scripts:ro" -v /tmp/es-dash-test:/dashboards alpine:3.20 sh -c \
  'apk add --no-cache curl jq >/dev/null && printf "test - default gcom:1860\n" > /manifest.txt && MANIFEST=/manifest.txt sh /scripts/fetch-dashboards.sh'
```
Expected: log line `ok   test  grafana.com/1860` and `fetched 1/1 dashboards`, exit 0.

- [ ] **Step 4: Assert the output is normalised.**

Run:
```bash
jq -e '.__inputs == null and .__requires == null' /tmp/es-dash-test/test/1860.json && echo INPUTS_STRIPPED_OK
grep -c '${DS_' /tmp/es-dash-test/test/1860.json
```
Expected: `INPUTS_STRIPPED_OK`, and the grep prints `0` (no unresolved datasource variables).

- [ ] **Step 5: Verify the GitHub path still works (no regression).**

Run:
```bash
docker run --rm -v "$PWD/scripts:/scripts:ro" -v /tmp/es-dash-test:/dashboards alpine:3.20 sh -c \
  'apk add --no-cache curl jq >/dev/null && printf "pve fjacquet/pve_exporter default grafana/dashboards/\n" > /manifest.txt && MANIFEST=/manifest.txt sh /scripts/fetch-dashboards.sh'
```
Expected: at least one `ok   pve  fjacquet/pve_exporter@...` line, exit 0.

- [ ] **Step 6: Commit.**

```bash
git add scripts/fetch-dashboards.sh
git commit -m "feat(fetcher): source dashboards from grafana.com via gcom: token"
```

---

## Task 2: node_exporter (live)

**Files:**
- Modify: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md`, `.env.example`

**Interfaces:**
- Consumes: the `gcom:` fetcher token from Task 1.
- Produces: service `node_exporter` on `:9100`, live `up=1`.

- [ ] **Step 1: Add the service to `docker-compose.yml`** (in the exporters block, after `veeam_licenses_exporter`):

```yaml
  node_exporter:
    image: quay.io/prometheus/node-exporter:${NODE_TAG:-latest}
    container_name: es_node_exporter
    command:
      - '--path.rootfs=/host'
    pid: host
    volumes:
      - '/:/host:ro,rslave'
    ports: ["9100:9100"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 2: Add the scrape job to `prometheus.yml`** (append under `scrape_configs`):

```yaml
  - job_name: node_exporter
    static_configs: [{ targets: ['node_exporter:9100'] }]
```

- [ ] **Step 3: Add the dashboard row to `dashboards.manifest.txt`:**

```
node     -  default  gcom:1860
```

- [ ] **Step 4: Add the README table row and the `.env.example` tag line.** README exporter/ports table: `| node | Linux/host metrics | 9100 | live |`. `.env.example` (in the "Image tags" block): `NODE_TAG=latest`.

- [ ] **Step 5: Validate compose and start the service.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d node_exporter
sleep 5
curl -sf http://localhost:9100/metrics | grep -m1 '^node_cpu_seconds_total' && echo METRICS_OK
```
Expected: `CONFIG_OK`, a `node_cpu_seconds_total` line, `METRICS_OK`.

- [ ] **Step 6: Verify Prometheus sees it up.**

Run:
```bash
docker compose up -d prometheus
sleep 20
curl -s 'http://localhost:9090/api/v1/query?query=up{job="node_exporter"}' | jq '.data.result[0].value[1]'
```
Expected: `"1"` (node is live).

- [ ] **Step 7: Commit.**

```bash
git add docker-compose.yml prometheus.yml dashboards.manifest.txt README.md .env.example
git commit -m "feat: add live node_exporter with grafana.com dashboard 1860"
```

---

## Task 3: Database exporters (postgres, mysqld, mongodb, mssql, redis)

**Files:**
- Create: `configs/mysqld.cnf`
- Modify: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md`, `.env.example`

**Interfaces:**
- Consumes: Task 1 fetcher.
- Produces: services `postgres_exporter:9187`, `mysqld_exporter:9104`, `mongodb_exporter:9216`, `mssql_exporter:4000`, `redis_exporter:9121` — all idle `up=0`.

- [ ] **Step 1: Create `configs/mysqld.cnf`:**

```ini
[client]
user = exporter
password = changeme
```

- [ ] **Step 2: Add the five services to `docker-compose.yml`:**

```yaml
  postgres_exporter:
    image: quay.io/prometheuscommunity/postgres-exporter:${POSTGRES_TAG:-latest}
    container_name: es_postgres_exporter
    environment:
      - DATA_SOURCE_NAME=${POSTGRES_DSN:-postgresql://postgres:changeme@postgres.example.com:5432/postgres?sslmode=disable}
    ports: ["9187:9187"]
    networks: [exporters]
    restart: unless-stopped

  mysqld_exporter:
    image: quay.io/prometheus/mysqld-exporter:${MYSQLD_TAG:-latest}
    container_name: es_mysqld_exporter
    command:
      - '--config.my-cnf=/etc/mysqld_exporter/.my.cnf'
      - '--mysqld.address=${MYSQL_ADDRESS:-mysql.example.com:3306}'
    volumes:
      - ./configs/mysqld.cnf:/etc/mysqld_exporter/.my.cnf:ro
    ports: ["9104:9104"]
    networks: [exporters]
    restart: unless-stopped

  mongodb_exporter:
    # percona/mongodb_exporter has no :latest tag — pin a version
    image: percona/mongodb_exporter:${MONGODB_TAG:-0.51.0}
    container_name: es_mongodb_exporter
    command:
      - '--mongodb.uri=${MONGODB_URI:-mongodb://exporter:changeme@mongodb.example.com:27017}'
      - '--collect-all'
    ports: ["9216:9216"]
    networks: [exporters]
    restart: unless-stopped

  mssql_exporter:
    image: awaragi/prometheus-mssql-exporter:${MSSQL_TAG:-latest}
    container_name: es_mssql_exporter
    environment:
      - SERVER=${MSSQL_SERVER:-mssql.example.com}
      - PORT=${MSSQL_PORT:-1433}
      - USERNAME=${MSSQL_USERNAME:-sa}
      - PASSWORD=${MSSQL_PASSWORD:-changeme}
      - EXPOSE=4000
    ports: ["4000:4000"]
    networks: [exporters]
    restart: unless-stopped

  redis_exporter:
    image: oliver006/redis_exporter:${REDIS_TAG:-latest}
    container_name: es_redis_exporter
    environment:
      - REDIS_ADDR=${REDIS_ADDR:-redis://redis.example.com:6379}
      - REDIS_PASSWORD=${REDIS_PASSWORD:-changeme}
    ports: ["9121:9121"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 3: Add scrape jobs to `prometheus.yml`:**

```yaml
  - job_name: postgres_exporter
    static_configs: [{ targets: ['postgres_exporter:9187'] }]
  - job_name: mysqld_exporter
    static_configs: [{ targets: ['mysqld_exporter:9104'] }]
  - job_name: mongodb_exporter
    static_configs: [{ targets: ['mongodb_exporter:9216'] }]
  - job_name: mssql_exporter
    static_configs: [{ targets: ['mssql_exporter:4000'] }]
  - job_name: redis_exporter
    static_configs: [{ targets: ['redis_exporter:9121'] }]
```

- [ ] **Step 4: Add dashboard rows to `dashboards.manifest.txt`:**

```
postgres -  default  gcom:9628
mysqld   -  default  gcom:7362
mongodb  -  default  gcom:20867
mssql    -  default  gcom:9336
redis    -  default  gcom:763
```

- [ ] **Step 5: Add README rows and `.env.example` entries.** README table rows for each (name / target / port / `up=0`). `.env.example` "Image tags": `POSTGRES_TAG=latest`, `MYSQLD_TAG=latest`, `MONGODB_TAG=0.51.0` (no `:latest` tag), `MSSQL_TAG=latest`, `REDIS_TAG=latest`; a new "Community exporter targets (optional)" block with `POSTGRES_DSN=`, `MYSQL_ADDRESS=`, `MONGODB_URI=`, `MSSQL_SERVER=`, `MSSQL_USERNAME=`, `MSSQL_PASSWORD=`, `REDIS_ADDR=`, `REDIS_PASSWORD=` (blank values).

- [ ] **Step 6: Validate and start the batch, checking for restart loops.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d postgres_exporter mysqld_exporter mongodb_exporter mssql_exporter redis_exporter
sleep 15
docker compose ps postgres_exporter mysqld_exporter mongodb_exporter mssql_exporter redis_exporter
```
Expected: `CONFIG_OK`; each container `Up` (not `Restarting`). **If `mongodb_exporter` or `mssql_exporter` is `Restarting`** (fail-fast without a backend), record it — it will be documented in Task 12; do not block the batch.

- [ ] **Step 7: Verify each idle target is up=0 (or scrape-erroring) in Prometheus.**

Run:
```bash
sleep 20
for j in postgres_exporter mysqld_exporter mongodb_exporter mssql_exporter redis_exporter; do
  echo -n "$j: "; curl -s "http://localhost:9090/api/v1/query?query=up{job=\"$j\"}" | jq -r '.data.result[0].value[1] // "no-target"';
done
```
Expected: each prints `0` (idle) or `no-target` for any exporter that restart-loops (noted in Step 6).

- [ ] **Step 8: Commit.**

```bash
git add docker-compose.yml prometheus.yml dashboards.manifest.txt README.md .env.example configs/mysqld.cnf
git commit -m "feat: add database exporters (postgres, mysqld, mongodb, mssql, redis)"
```

---

## Task 4: Web/proxy exporters (nginx, apache, haproxy)

**Files:**
- Modify: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md`, `.env.example`

**Interfaces:**
- Produces: `nginx_exporter:9113`, `apache_exporter:9117`, `haproxy_exporter:9101` — idle `up=0`.

- [ ] **Step 1: Add services to `docker-compose.yml`:**

```yaml
  nginx_exporter:
    image: nginx/nginx-prometheus-exporter:${NGINX_TAG:-latest}
    container_name: es_nginx_exporter
    command:
      - '--nginx.scrape-uri=${NGINX_SCRAPE_URI:-http://nginx.example.com:8080/stub_status}'
    ports: ["9113:9113"]
    networks: [exporters]
    restart: unless-stopped

  apache_exporter:
    image: quay.io/lusitaniae/apache-exporter:${APACHE_TAG:-latest}
    container_name: es_apache_exporter
    command:
      - '--scrape_uri=${APACHE_SCRAPE_URI:-http://apache.example.com/server-status?auto}'
    ports: ["9117:9117"]
    networks: [exporters]
    restart: unless-stopped

  haproxy_exporter:
    image: quay.io/prometheus/haproxy-exporter:${HAPROXY_TAG:-latest}
    container_name: es_haproxy_exporter
    command:
      - '--haproxy.scrape-uri=${HAPROXY_SCRAPE_URI:-http://haproxy.example.com:8404/haproxy?stats;csv}'
    ports: ["9101:9101"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 2: Add scrape jobs to `prometheus.yml`:**

```yaml
  - job_name: nginx_exporter
    static_configs: [{ targets: ['nginx_exporter:9113'] }]
  - job_name: apache_exporter
    static_configs: [{ targets: ['apache_exporter:9117'] }]
  - job_name: haproxy_exporter
    static_configs: [{ targets: ['haproxy_exporter:9101'] }]
```

- [ ] **Step 3: Add dashboard rows to `dashboards.manifest.txt`:**

```
nginx    -  default  gcom:12708
apache   -  default  gcom:3894
haproxy  -  default  gcom:367
```

- [ ] **Step 4: Add README rows and `.env.example` entries.** Tags: `NGINX_TAG=latest`, `APACHE_TAG=latest`, `HAPROXY_TAG=latest`. Targets block: `NGINX_SCRAPE_URI=`, `APACHE_SCRAPE_URI=`, `HAPROXY_SCRAPE_URI=`.

- [ ] **Step 5: Validate and start.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d nginx_exporter apache_exporter haproxy_exporter
sleep 15
docker compose ps nginx_exporter apache_exporter haproxy_exporter
sleep 15
for j in nginx_exporter apache_exporter haproxy_exporter; do
  echo -n "$j: "; curl -s "http://localhost:9090/api/v1/query?query=up{job=\"$j\"}" | jq -r '.data.result[0].value[1] // "no-target"';
done
```
Expected: `CONFIG_OK`; all `Up`; each `up` query prints `0`.

- [ ] **Step 6: Commit.**

```bash
git add docker-compose.yml prometheus.yml dashboards.manifest.txt README.md .env.example
git commit -m "feat: add web/proxy exporters (nginx, apache, haproxy)"
```

---

## Task 5: Messaging exporters (rabbitmq, kafka)

**Files:**
- Modify: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md`, `.env.example`

**Interfaces:**
- Produces: `rabbitmq_exporter:9419`, `kafka_exporter:9308` — idle `up=0`.

- [ ] **Step 1: Add services to `docker-compose.yml`:**

```yaml
  rabbitmq_exporter:
    image: kbudde/rabbitmq-exporter:${RABBITMQ_TAG:-latest}
    container_name: es_rabbitmq_exporter
    environment:
      - RABBIT_URL=${RABBIT_URL:-http://rabbitmq.example.com:15672}
      - RABBIT_USER=${RABBIT_USER:-monitoring}
      - RABBIT_PASSWORD=${RABBIT_PASSWORD:-changeme}
    ports: ["9419:9419"]
    networks: [exporters]
    restart: unless-stopped

  kafka_exporter:
    image: danielqsj/kafka-exporter:${KAFKA_TAG:-latest}
    container_name: es_kafka_exporter
    command:
      - '--kafka.server=${KAFKA_SERVER:-kafka.example.com:9092}'
    ports: ["9308:9308"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 2: Add scrape jobs to `prometheus.yml`:**

```yaml
  - job_name: rabbitmq_exporter
    static_configs: [{ targets: ['rabbitmq_exporter:9419'] }]
  - job_name: kafka_exporter
    static_configs: [{ targets: ['kafka_exporter:9308'] }]
```

- [ ] **Step 3: Add dashboard rows to `dashboards.manifest.txt`:**

```
rabbitmq -  default  gcom:4279
kafka    -  default  gcom:7589
```

- [ ] **Step 4: Add README rows and `.env.example` entries.** Tags: `RABBITMQ_TAG=latest`, `KAFKA_TAG=latest`. Targets: `RABBIT_URL=`, `RABBIT_USER=`, `RABBIT_PASSWORD=`, `KAFKA_SERVER=`.

- [ ] **Step 5: Validate and start.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d rabbitmq_exporter kafka_exporter
sleep 15
docker compose ps rabbitmq_exporter kafka_exporter
sleep 15
for j in rabbitmq_exporter kafka_exporter; do
  echo -n "$j: "; curl -s "http://localhost:9090/api/v1/query?query=up{job=\"$j\"}" | jq -r '.data.result[0].value[1] // "no-target"';
done
```
Expected: `CONFIG_OK`; both `Up`; each `up` prints `0`.

- [ ] **Step 6: Commit.**

```bash
git add docker-compose.yml prometheus.yml dashboards.manifest.txt README.md .env.example
git commit -m "feat: add messaging exporters (rabbitmq, kafka)"
```

---

## Task 6: Cloud exporters (stackdriver, azure)

**Files:**
- Modify: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md`, `.env.example`

**Interfaces:**
- Produces: `stackdriver_exporter:9255`, `azure_exporter:8080`.

Note: azure (webdevops) uses a probe model — its `/metrics` serves exporter self-metrics, so its target reads `up=1` with only meta-metrics (real Azure metrics need probe-style scrape config, out of scope). stackdriver may need valid GCP creds to start; treat a restart loop as a documented fail-fast (Task 12).

- [ ] **Step 1: Add services to `docker-compose.yml`:**

```yaml
  stackdriver_exporter:
    image: quay.io/prometheuscommunity/stackdriver-exporter:${STACKDRIVER_TAG:-latest}
    container_name: es_stackdriver_exporter
    command:
      - '--google.project-ids=${GCP_PROJECT_ID:-my-gcp-project}'
      - '--monitoring.metrics-type-prefixes=compute.googleapis.com/instance/cpu'
    environment:
      - GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS:-}
    ports: ["9255:9255"]
    networks: [exporters]
    restart: unless-stopped

  azure_exporter:
    image: quay.io/webdevops/azure-metrics-exporter:${AZURE_TAG:-latest}
    container_name: es_azure_exporter
    environment:
      - AZURE_TENANT_ID=${AZURE_TENANT_ID:-00000000-0000-0000-0000-000000000000}
      - AZURE_CLIENT_ID=${AZURE_CLIENT_ID:-00000000-0000-0000-0000-000000000000}
      - AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET:-changeme}
    ports: ["8080:8080"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 2: Add scrape jobs to `prometheus.yml`:**

```yaml
  - job_name: stackdriver_exporter
    static_configs: [{ targets: ['stackdriver_exporter:9255'] }]
  - job_name: azure_exporter
    static_configs: [{ targets: ['azure_exporter:8080'] }]
```

- [ ] **Step 3: `dashboards.manifest.txt` — add the stackdriver row; azure has no canonical grafana.com dashboard.** Add the stackdriver dashboard row plus a comment line documenting the azure/radosgw omission:

```
stackdriver -  default  gcom:16572
# azure, radosgw: no canonical grafana.com dashboard — omitted this batch (follow-up).
```

- [ ] **Step 4: Add README rows and `.env.example` entries.** README rows note azure = self-metrics only, stackdriver = idle/creds-required. Tags: `STACKDRIVER_TAG=latest`, `AZURE_TAG=latest`. Targets: `GCP_PROJECT_ID=`, `GOOGLE_APPLICATION_CREDENTIALS=`, `AZURE_TENANT_ID=`, `AZURE_CLIENT_ID=`, `AZURE_CLIENT_SECRET=`.

- [ ] **Step 5: Validate and start, recording startup behavior.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d stackdriver_exporter azure_exporter
sleep 15
docker compose ps stackdriver_exporter azure_exporter
sleep 15
for j in stackdriver_exporter azure_exporter; do
  echo -n "$j: "; curl -s "http://localhost:9090/api/v1/query?query=up{job=\"$j\"}" | jq -r '.data.result[0].value[1] // "no-target"';
done
```
Expected: `CONFIG_OK`; azure `Up` and `up`=`1` (self-metrics). stackdriver either `Up` with `up`=`0`/`1`, or `Restarting` → record for Task 12; do not block.

- [ ] **Step 6: Commit.**

```bash
git add docker-compose.yml prometheus.yml dashboards.manifest.txt README.md .env.example
git commit -m "feat: add cloud exporters (stackdriver, azure)"
```

---

## Task 7: Storage exporters (ceph, radosgw, gluster)

**Files:**
- Create: `configs/ceph.conf`, `configs/ceph.keyring`, `configs/gluster-exporter.toml`
- Modify: `docker-compose.yml`, `prometheus.yml`, `dashboards.manifest.txt`, `README.md`, `.env.example`

**Interfaces:**
- Produces: `ceph_exporter:9128`, `radosgw_exporter:9242`, `gluster_exporter:9713`.

Note: `ceph_exporter` connects to the cluster via librados; without a reachable mon its target likely shows `down` (scrape timeout), like idrac. `gluster-prometheus` expects a local `glusterd`; it may restart-loop — acceptable as a documented legacy entry (Task 12).

- [ ] **Step 1: Create the config files.**

`configs/ceph.conf`:
```ini
[global]
mon_host = 10.0.0.1
```

`configs/ceph.keyring`:
```ini
[client.admin]
key = AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
```

`configs/gluster-exporter.toml`:
```toml
[globals]
port = 9713
metrics-path = "/metrics"
```

- [ ] **Step 2: Add services to `docker-compose.yml`:**

```yaml
  ceph_exporter:
    # amd64-only image — platform pin required on arm64 hosts (e.g. Apple Silicon).
    image: digitalocean/ceph_exporter:${CEPH_TAG:-latest}
    platform: linux/amd64
    container_name: es_ceph_exporter
    volumes:
      - ./configs/ceph.conf:/etc/ceph/ceph.conf:ro
      - ./configs/ceph.keyring:/etc/ceph/keyring:ro
    ports: ["9128:9128"]
    networks: [exporters]
    restart: unless-stopped

  radosgw_exporter:
    image: ghcr.io/pando85/radosgw_usage_exporter:${RADOSGW_TAG:-latest}
    container_name: es_radosgw_exporter
    environment:
      - RADOSGW_SERVER=${RADOSGW_SERVER:-http://radosgw.example.com:7480}
      - ACCESS_KEY=${RADOSGW_ACCESS_KEY:-changeme}
      - SECRET_KEY=${RADOSGW_SECRET_KEY:-changeme}
    ports: ["9242:9242"]
    networks: [exporters]
    restart: unless-stopped

  gluster_exporter:
    # gluster/gluster-prometheus:latest is not published on Docker Hub (denied/unauthorized);
    # substituted the community mirror kurzdigital/gluster-prometheus (same upstream source).
    # amd64-only image (built 2018) — platform pin required on arm64 hosts (e.g. Apple Silicon).
    image: kurzdigital/gluster-prometheus:${GLUSTER_TAG:-latest}
    platform: linux/amd64
    container_name: es_gluster_exporter
    # image's default CMD is a bare /bin/sh (exits immediately) — the exporter binary
    # must be invoked explicitly.
    command: ["/gluster-exporter"]
    volumes:
      - ./configs/gluster-exporter.toml:/etc/gluster-prometheus/gluster-exporter.toml:ro
    ports: ["9713:9713"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 3: Add scrape jobs to `prometheus.yml`:**

```yaml
  - job_name: ceph_exporter
    static_configs: [{ targets: ['ceph_exporter:9128'] }]
  - job_name: radosgw_exporter
    static_configs: [{ targets: ['radosgw_exporter:9242'] }]
  - job_name: gluster_exporter
    static_configs: [{ targets: ['gluster_exporter:9713'] }]
```

- [ ] **Step 4: Add the ceph and gluster dashboard rows to `dashboards.manifest.txt`** (radosgw omitted per Task 6):

```
ceph     -  default  gcom:917
gluster  -  default  gcom:8376
```

- [ ] **Step 5: Add README rows and `.env.example` entries.** Tags: `CEPH_TAG=latest`, `RADOSGW_TAG=latest`, `GLUSTER_TAG=latest`. Targets: `RADOSGW_SERVER=`, `RADOSGW_ACCESS_KEY=`, `RADOSGW_SECRET_KEY=`. README notes: ceph target may show `down` (like idrac); gluster is legacy and may not start without glusterd.

- [ ] **Step 6: Validate and start, recording behavior.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d ceph_exporter radosgw_exporter gluster_exporter
sleep 20
docker compose ps ceph_exporter radosgw_exporter gluster_exporter
for j in ceph_exporter radosgw_exporter gluster_exporter; do
  echo -n "$j: "; curl -s "http://localhost:9090/api/v1/query?query=up{job=\"$j\"}" | jq -r '.data.result[0].value[1] // "no-target"';
done
```
Expected: `CONFIG_OK`. radosgw `Up` with `up`=`0`. ceph target may be `down`/`no-target` (connection timeout). gluster either `Up` `up`=`0` or `Restarting` → record for Task 12.

- [ ] **Step 7: Commit.**

```bash
git add docker-compose.yml prometheus.yml dashboards.manifest.txt README.md .env.example configs/ceph.conf configs/ceph.keyring configs/gluster-exporter.toml
git commit -m "feat: add storage exporters (ceph, radosgw, gluster)"
```

---

## Task 8: Windows document-only stub

**Files:**
- Modify: `prometheus.yml`, `dashboards.manifest.txt`, `README.md`

**Interfaces:**
- Produces: a commented Windows scrape job + a fetched Windows dashboard (no container).

- [ ] **Step 1: Add the commented scrape job to `prometheus.yml`** (append under `scrape_configs`):

```yaml
  # Windows Exporter runs only on Windows hosts (no Linux container). Uncomment and
  # point at your Windows host(s) running windows_exporter on :9182.
  # - job_name: windows_exporter
  #   static_configs: [{ targets: ['windows-host.example.com:9182'] }]
```

- [ ] **Step 2: Add the dashboard row to `dashboards.manifest.txt`** (dashboard is fetched even though nothing runs locally):

```
windows  -  default  gcom:14694
```

- [ ] **Step 3: Add a README note.** In the exporter table add a `windows` row marked *doc-only (Windows host)*, and a sentence: "Windows Exporter has no Linux container; its scrape job in `prometheus.yml` is commented — uncomment and point it at a Windows host running windows_exporter on :9182. Its Grafana dashboard is still provisioned."

- [ ] **Step 4: Verify the Windows dashboard fetches and compose still validates.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d --force-recreate dashboard-fetcher
docker compose logs dashboard-fetcher | grep 'grafana.com/14694'
```
Expected: `CONFIG_OK` and an `ok   windows  grafana.com/14694` line.

- [ ] **Step 5: Commit.**

```bash
git add prometheus.yml dashboards.manifest.txt README.md
git commit -m "docs: add document-only Windows exporter stub + dashboard"
```

---

## Task 9: Prometheus alert rules + rule_files wiring

**Files:**
- Create: `rules/alerts.yml`
- Modify: `prometheus.yml`, `docker-compose.yml`

**Interfaces:**
- Produces: alert rules `Heartbeat`, `BackendDown`, `ExporterDown`, `NodeHighLoad` loaded by Prometheus; `rules` mounted at `/etc/prometheus/rules`.

- [ ] **Step 1: Create `rules/alerts.yml`:**

```yaml
groups:
  - name: exporter-availability
    rules:
      - alert: ExporterDown
        expr: up{job=~"idrac_exporter|nbu_exporter|kafka_exporter|stackdriver_exporter|azure_exporter|ceph_exporter|gluster_exporter|vmware_licenses_exporter|m365_licenses_exporter|veeam_licenses_exporter"} == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Exporter {{ $labels.job }} is down"
          description: >-
            {{ $labels.instance }} (job {{ $labels.job }}) has failed to scrape
            for over 1 minute (up == 0). In this demo it fires for exporters that
            fatal-exit / restart-loop without a real backend (kafka, stackdriver,
            azure, ceph, gluster, and the licensing exporters vmware/m365/veeam) and
            for collect-on-demand exporters (idrac, nbu).
            Exporters that serve /metrics regardless stay up=1 — see BackendDown.

  - name: backend-availability
    rules:
      - alert: BackendDown
        expr: pg_up == 0 or mysql_up == 0 or redis_up == 0 or mongodb_up == 0 or mssql_up == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Exporter {{ $labels.job }} cannot reach its backend"
          description: >-
            {{ $labels.job }} scrapes fine (up == 1) but its internal health gauge
            reports the monitored backend unreachable. In this demo the database
            exporters report their *_up gauge = 0 because they point at fictional
            targets. Fires on startup by design.

  - name: demo-heartbeat
    rules:
      - alert: Heartbeat
        expr: vector(1)
        labels:
          severity: none
        annotations:
          summary: "Alerting pipeline heartbeat"
          description: >-
            Always-firing dead-man's-switch. If this alert is NOT visible in
            Alertmanager, the Prometheus -> Alertmanager path is broken.

  - name: node-examples
    rules:
      - alert: NodeHighLoad
        expr: node_load1 > 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High 1m load on {{ $labels.instance }}"
          description: >-
            Example threshold rule (will not fire in this demo). Shows the normal
            metric-based alerting pattern against node_exporter.
```

- [ ] **Step 2: Add `rule_files` to `prometheus.yml`** (top level, after `global:`):

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml
```

- [ ] **Step 3: Mount the rules dir on the prometheus service in `docker-compose.yml`.** Change the prometheus `volumes:` to add the rules mount:

```yaml
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
```

- [ ] **Step 4: Validate the rules with promtool.**

Run:
```bash
docker compose up -d prometheus
sleep 5
docker compose exec -T prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```
Expected: `SUCCESS: 4 rules found`.

- [ ] **Step 5: Verify Prometheus loaded and is firing the rules.**

Run:
```bash
docker compose up -d --force-recreate prometheus
sleep 75
curl -s http://localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[].name' | sort -u
curl -s 'http://localhost:9090/api/v1/query?query=ALERTS{alertname="Heartbeat",alertstate="firing"}' | jq '.data.result | length'
```
Expected: rule names include `ExporterDown`, `BackendDown`, `Heartbeat`, `NodeHighLoad`; the Heartbeat query returns `1`.

- [ ] **Step 6: Commit.**

```bash
git add rules/alerts.yml prometheus.yml docker-compose.yml
git commit -m "feat(alerting): add Prometheus alert rules and rule_files wiring"
```

---

## Task 10: Alertmanager + webhook-logger services

**Files:**
- Create: `alertmanager.yml`
- Modify: `docker-compose.yml`, `prometheus.yml`

**Interfaces:**
- Consumes: firing alerts from Task 9.
- Produces: `alertmanager:9093`, `webhook-logger:8080` (host 9095); Prometheus `alerting` → alertmanager.

- [ ] **Step 1: Create `alertmanager.yml`** (email receiver + templates commented as reference; active route → webhook):

```yaml
route:
  receiver: webhook-logger
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 30s
  repeat_interval: 1h

receivers:
  - name: webhook-logger
    webhook_configs:
      - url: 'http://webhook-logger:8080/'
        send_resolved: true

  # --- Reference only: an email receiver showing where a notification template
  # --- plugs in. Inactive (the route above sends everything to webhook-logger).
  # - name: email-example
  #   email_configs:
  #     - to: 'oncall@example.com'
  #       from: 'alertmanager@example.com'
  #       smarthost: 'mailpit:1025'
  #       require_tls: false
  #       headers:
  #         subject: '{{ template "email.subject" . }}'
  #       html: '{{ template "email.body" . }}'

# templates:
#   - '/etc/alertmanager/templates/*.tmpl'
```

- [ ] **Step 2: Add the two services to `docker-compose.yml`** (in the shared-observability block, before `prometheus`):

```yaml
  alertmanager:
    image: prom/alertmanager:${ALERTMANAGER_TAG:-latest}
    container_name: es_alertmanager
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - ./alertmanager/templates:/etc/alertmanager/templates:ro
    ports: ["9093:9093"]
    networks: [exporters]
    restart: unless-stopped

  webhook-logger:
    image: mendhak/http-https-echo:${WEBHOOK_LOGGER_TAG:-latest}
    container_name: es_webhook_logger
    environment:
      - HTTP_PORT=8080
    ports: ["9095:8080"]
    networks: [exporters]
    restart: unless-stopped
```

- [ ] **Step 3: Point Prometheus at Alertmanager in `prometheus.yml`** (top level, after `global:`):

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
```

- [ ] **Step 4: Create the templates dir placeholder so the mount exists.** (The real template file is added in Task 11; create the directory now with a `.gitkeep` so the compose mount is valid.)

Run:
```bash
mkdir -p alertmanager/templates && touch alertmanager/templates/.gitkeep
```

- [ ] **Step 5: Validate the Alertmanager config.**

Run:
```bash
docker compose config -q && echo CONFIG_OK
docker compose up -d alertmanager webhook-logger
sleep 5
docker compose exec -T alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```
Expected: `CONFIG_OK`; amtool prints `Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS` and `Found 1 receivers`.

- [ ] **Step 6: Verify the end-to-end path — alerts reach the webhook logger.**

Run:
```bash
docker compose up -d --force-recreate prometheus
sleep 90
curl -s http://localhost:9093/api/v2/alerts | jq 'length'
docker compose logs webhook-logger | grep -i -m1 'alertname'
```
Expected: the Alertmanager alerts count is `> 0`, and the webhook-logger log contains a JSON payload mentioning `alertname` (ExporterDown/Heartbeat).

- [ ] **Step 7: Commit.**

```bash
git add alertmanager.yml docker-compose.yml prometheus.yml alertmanager/templates/.gitkeep
git commit -m "feat(alerting): add Alertmanager + webhook-logger receiver"
```

---

## Task 11: Notification template + Alertmanager docs

**Files:**
- Create: `alertmanager/templates/notification.tmpl`, `docs/alertmanager.md`
- Modify: `README.md`, `.env.example`

**Interfaces:**
- Produces: reference template used by the commented email receiver; user-facing docs.

- [ ] **Step 1: Create `alertmanager/templates/notification.tmpl`:**

```
{{ define "email.subject" }}[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ .Alerts | len }} alert(s)){{ end }}

{{ define "email.body" }}
<h2>{{ .CommonLabels.alertname }}</h2>
<p>Status: <b>{{ .Status }}</b></p>
{{ range .Alerts }}
<hr>
<p><b>{{ .Annotations.summary }}</b></p>
<p>{{ .Annotations.description }}</p>
<p>Labels: {{ range .Labels.SortedPairs }}{{ .Name }}={{ .Value }} {{ end }}</p>
{{ end }}
{{ end }}
```

- [ ] **Step 2: Remove the `.gitkeep` now that a real file exists.**

Run:
```bash
git rm --cached alertmanager/templates/.gitkeep 2>/dev/null; rm -f alertmanager/templates/.gitkeep
```

- [ ] **Step 3: Create `docs/alertmanager.md`:**

```markdown
# Alertmanager demo

Prometheus evaluates the rules in `rules/alerts.yml` and hands firing alerts to
**Alertmanager** (`:9093`), which groups, routes, and notifies. In this stack the
receiver is a **webhook logger** so you can see the exact notification payload.

## What fires, and why

- `ExporterDown` (scoped `up == 0`) — fires on startup for the exporters that fatal-exit /
  restart-loop without a real backend (kafka, stackdriver, azure, ceph, gluster, idrac, nbu,
  and the licensing exporters vmware/m365/veeam), so the demo shows real firing alerts with
  no fake data.
- `BackendDown` (`pg_up == 0 or mysql_up == 0 or redis_up == 0 or mongodb_up == 0 or
  mssql_up == 0`) — fires for exporters that scrape fine (`up == 1`) but whose internal
  health gauge reports the monitored backend unreachable (the database exporters point at
  fictional targets).
- `Heartbeat` (`vector(1)`) — always-firing dead-man's-switch. If it's *absent* in
  Alertmanager, the Prometheus -> Alertmanager path is broken.
- `NodeHighLoad` — example threshold rule; does not fire in the demo.

## How to watch it

1. `docker compose up -d`
2. Prometheus rules/alerts: http://localhost:9090/alerts
3. Alertmanager UI (grouping, silences): http://localhost:9093
4. The delivered notifications (JSON): `docker compose logs -f webhook-logger`

## Concepts

- **Rules** live in Prometheus (`rules/alerts.yml`): a PromQL `expr` + `for:` duration.
- **Routing** (`alertmanager.yml` `route:`) sends alerts to a **receiver** by label;
  `group_by`/`group_wait`/`repeat_interval` control batching and re-notification.
- **Receivers** are integrations (webhook, email, Slack, PagerDuty). This demo uses a
  webhook; a commented `email-example` receiver shows where a **notification template**
  (`alertmanager/templates/notification.tmpl`) plugs in. Templates shape email/Slack
  text — a webhook always posts fixed JSON, so they are reference-only here.
- **Silences** (Alertmanager UI) mute alerts during maintenance; **inhibition** suppresses
  one alert while another is firing.
```

- [ ] **Step 4: Add a README "Alerting" section and `.env.example` tags.** README: a short section linking to `docs/alertmanager.md`, listing Alertmanager `:9093` and the webhook-logger log command. `.env.example` "Image tags": `ALERTMANAGER_TAG=latest`, `WEBHOOK_LOGGER_TAG=latest`.

- [ ] **Step 5: Re-validate Alertmanager still starts (template dir now has a real file).**

Run:
```bash
docker compose up -d --force-recreate alertmanager
sleep 5
docker compose exec -T alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```
Expected: `SUCCESS`.

- [ ] **Step 6: Commit.**

```bash
git add alertmanager/templates/notification.tmpl docs/alertmanager.md README.md .env.example
git commit -m "docs(alerting): add notification template and Alertmanager doc"
```

---

## Task 12: Full-stack smoke test + CLAUDE.md gotchas

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the recorded startup behavior of the fail-fast candidates (Tasks 3, 6, 7).

- [ ] **Step 1: Bring up the entire stack clean.**

Run:
```bash
docker compose down
docker compose up -d
sleep 90
docker compose ps --format '{{.Name}}\t{{.State}}' | sort
```
Expected: every container `running` except `es_dashboard_fetcher` (`exited (0)`). Note any container in `restarting` — these are the documented fail-fast exporters.

- [ ] **Step 2: Verify the dashboard fetcher fetched the grafana.com dashboards.**

Run:
```bash
docker compose logs dashboard-fetcher | grep -c 'grafana.com/'
docker compose logs dashboard-fetcher | tail -1
```
Expected: count `>= 13` (the gcom rows added), and the last line `fetched N/M dashboards` with the run exiting 0.

- [ ] **Step 3: Verify targets and alerting end to end.**

Run:
```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job="node_exporter"}' | jq -r '.data.result[0].value[1]'   # 1
curl -s 'http://localhost:9090/api/v1/query?query=count(up==0)' | jq -r '.data.result[0].value[1]'               # many
curl -s http://localhost:9093/api/v2/alerts | jq 'length'                                                        # > 0
docker compose logs webhook-logger | grep -c -i 'alertname'                                                      # > 0
```
Expected: node `1`; several `up==0`; Alertmanager alert count `> 0`; webhook payloads `> 0`.

- [ ] **Step 4: Update `CLAUDE.md` Gotchas** with the verified facts. Add bullets (adjust the fail-fast list to what was actually observed in Steps of Tasks 3/6/7):

```markdown
- **Community exporters (second lane):** upstream images (`prom/*`, `quay.io/...`,
  `oliver006/redis_exporter`, etc.), not `ghcr.io/fjacquet`. All idle `up=0` except
  `node_exporter`, which is live (mounts host `/proc`,`/sys`,`/`).
- **MySQL:** `mysqld_exporter` v0.15.0+ removed `DATA_SOURCE_NAME`; wiring uses
  `configs/mysqld.cnf` + `--config.my-cnf` + `--mysqld.address`.
- **Fail-fast without a backend:** <list the exporters observed restart-looping —
  candidates: mongodb, mssql, stackdriver, gluster>. Like idrac/nbu, they need a
  reachable target (or real creds) to stay up; documented, not a bug.
- **azure_exporter** uses a probe model — its `/metrics` is exporter self-metrics
  (`up=1`); real Azure metrics need probe-style scrape config (out of scope).
- **ceph_exporter** connects via librados; target shows `down` (scrape timeout)
  without a reachable mon, like idrac.
- **gluster_exporter** is a legacy entry; `gluster/gluster-prometheus` does not exist as a
  published image — uses the unofficial, low-activity `kurzdigital/gluster-prometheus` mirror
  (amd64-only, `platform: linux/amd64` pin, `command: ["/gluster-exporter"]` override).
- **apache_exporter** substitutes `quay.io/lusitaniae/apache-exporter` — the
  `quay.io/prometheuscommunity/apache-exporter` image is dead/unauthorized.
- **mongodb_exporter** pins `${MONGODB_TAG:-0.51.0}` — `percona/mongodb_exporter` has no
  `:latest` tag.
- **Alerting:** `rules/alerts.yml` -> Prometheus (`rule_files`) -> `alertmanager` (:9093)
  -> `webhook-logger` (view via `docker compose logs webhook-logger`). `ExporterDown` (scoped
  to restart-looping exporters) and `BackendDown` (database *_up gauges) fire on startup.
  See `docs/alertmanager.md`.
- **New ports:** node 9100, mysqld 9104, apache 9117, nginx 9113, redis 9121,
  postgres 9187, mongodb 9216, kafka 9308, rabbitmq 9419, haproxy 9101, ceph 9128,
  radosgw 9242, gluster 9713, stackdriver 9255, azure 8080, mssql 4000,
  alertmanager 9093, webhook-logger 9095. Windows 9182 is a commented doc-only job.
```

- [ ] **Step 5: Commit.**

```bash
git add CLAUDE.md
git commit -m "docs: record community-exporter + alerting gotchas in CLAUDE.md"
```

---

## Self-Review Notes (author)

- **Spec coverage:** Part A fetcher (T1), node live (T2), 15 idle exporters (T3–T7), Windows doc-only + dashboard (T8), azure/radosgw dashboard omission (T6 §3, T7 §4). Part B rules (T9), Alertmanager + webhook receiver (T10), template + docs (T11), gcom Alertmanager dashboard is optional and intentionally not added. Verification + gotchas (T12). CloudWatch correctly absent.
- **Fail-fast handling:** Tasks 3/6/7 record actual behavior rather than assume; T12 documents the observed set — matches the spec's error-handling note.
- **Type/name consistency:** service names, ports, and image refs match the spec table verbatim; `gcom:<id>` token identical in T1 and all manifest rows; datasource rewrite target `prometheus` matches the provisioned `uid: prometheus`.
