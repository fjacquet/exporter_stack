# Alertmanager demo

Prometheus evaluates the rules in `rules/alerts.yml` and hands firing alerts to
**Alertmanager** (`:9093`), which groups, routes, and notifies. In this stack the
receiver is a **webhook logger** so you can see the exact notification payload.

## What fires, and why

- `Heartbeat` (`vector(1)`) — always-firing dead-man's-switch. If it's *absent* in
  Alertmanager, the Prometheus -> Alertmanager path is broken.
- `BackendDown` (`pg_up == 0 or mysql_up == 0 or redis_up == 0 or mongodb_up == 0 or
  mssql_up == 0`) — the five database exporters scrape fine (Prometheus `up == 1`) but
  each reports its own internal health gauge as unreachable, since they point at
  fictional targets. Fires on startup by design.
- `ExporterDown` (`up == 0`) — Prometheus itself failed to scrape the target. Most
  exporters in this stack serve `/metrics` regardless of backend reachability, so they
  stay `up == 1` and don't trigger this. It fires for the exporters that fatal-exit and
  restart-loop without a real backend (kafka, stackdriver, azure, ceph, gluster) and for
  the collect-on-demand exporters (idrac, nbu), whose scrape times out with no reachable
  backend.
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
