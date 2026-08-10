# Observability

Logs go to Loki, metrics to Prometheus or Mimir, both rendered in Grafana. This
replaces Logflare, which was the heaviest idle service in the stack.

## What you lose

Studio's **Logs Explorer** and **Reports** tabs stop working. They query
Logflare over `/analytics/v1` using Logflare's own SQL dialect, and Grafana does
not provide that. `NEXT_PUBLIC_ENABLE_LOGS` is set to `false` so the tabs are
switched off rather than left throwing errors.

Observability moves out of Studio rather than being reimplemented inside it.
For most self-hosted setups that is a trade up, since Grafana's alerting and
retention are better than the log viewer ever was. It is still a real change,
and anyone used to opening Studio for logs needs to know where they went.

## Topology

Both stacks share an external docker network. Nothing publishes a metrics port
to the host.

```
observability network
  ├── Supabase: traefik, auth, rest, storage, imgproxy,
  │             realtime, supavisor, db-exporter, vector
  └── LGTM:     prometheus/mimir, loki, grafana
```

Create the network once, on whichever side comes up first:

```sh
docker network create observability
```

`docker compose up` fails until it exists, because the compose file declares it
`external: true`. Point `OBSERVABILITY_NETWORK` in `.env` at a different name if
your LGTM stack already owns one.

## Logs

Vector collects every container's stdout through the docker socket, parses each
service's format, and pushes to Loki.

Per-service parsing is preserved from the Logflare setup and is what makes the
lines queryable: GoTrue's JSON, PostgREST's timestamp split, Postgres severity
extraction, Realtime's level regex, and Traefik's JSON access log.

Configure with `LOKI_ENDPOINT` in `.env`, as reachable from inside the
observability network.

### Labels

Only `service` and `project` are labels. Everything else stays in the log line.

Labels are Loki's index, and a high-cardinality label is how you take Loki down.
A request path or a status code as a label produces a stream per distinct value.
Query those with `| json` instead:

```logql
# Everything from one service
{service="supabase-auth"}

# Errors across the stack
{project="default"} |= "error"

# Gateway 5xx, status pulled from the line rather than a label
{service="supabase-traefik"} | json | metadata_response_status_code >= 500

# One route's traffic
{service="supabase-traefik"} | json | metadata_router = "rest@file"

# Postgres at WARNING or above
{service="supabase-db"} | json | metadata_parsed_error_severity =~ "WARNING|ERROR|FATAL|PANIC"

# Auth failures
{service="supabase-auth"} | json | msg =~ "(?i)invalid|denied|failed"
```

Container logs that match no per-service parser, from Studio, meta, imgproxy,
Supavisor and oauth2-proxy, are shipped unparsed rather than dropped. Logflare
discarded them.

## Metrics

| Service | Endpoint | Auth | Enabled by |
|---|---|---|---|
| Traefik | `traefik:8082/metrics` | none | `metrics.prometheus` in `traefik.yml` |
| PostgREST | `rest:3001/metrics` | none | `PGRST_ADMIN_SERVER_PORT` |
| GoTrue | `auth:9100/metrics` | none | `GOTRUE_METRICS_ENABLED` |
| Storage | `storage:5000/metrics` | none | on by default |
| imgproxy | `imgproxy:8081/metrics` | none | `IMGPROXY_PROMETHEUS_BIND` |
| Postgres | `db-exporter:9187/metrics` | none | `db-exporter` sidecar |
| Realtime | `realtime-dev.supabase-realtime:4000/metrics` | JWT | `METRICS_JWT_SECRET` |
| Supavisor | `supavisor:4000/metrics` | JWT | `METRICS_JWT_SECRET` |

Traefik is the one to wire first. It fronts every service, so its per-router
series cover the whole stack without instrumenting anything else.

### Scrape config

```yaml
scrape_configs:
  - job_name: supabase
    static_configs:
      - targets:
          - traefik:8082
          - rest:3001
          - auth:9100
          - storage:5000
          - imgproxy:8081
          - db-exporter:9187

  # Realtime and Supavisor gate /metrics behind a JWT signed with
  # METRICS_JWT_SECRET, which is JWT_SECRET in .env. Mint a token with the
  # service_role claim and point bearer_token_file at it.
  - job_name: supabase-jwt
    bearer_token_file: /etc/prometheus/supabase-metrics.jwt
    static_configs:
      - targets:
          - realtime-dev.supabase-realtime:4000
          - supavisor:4000
```

Both JWT-gated endpoints are wired to the network but their scrape has not been
confirmed against a running stack. Verify before relying on them.

### Useful queries

```promql
# Request rate per route
sum by (router) (rate(traefik_router_requests_total[5m]))

# 95th percentile latency per service
histogram_quantile(0.95,
  sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))

# Gateway error ratio
sum(rate(traefik_router_requests_total{code=~"5.."}[5m]))
  / sum(rate(traefik_router_requests_total[5m]))

# Postgres connections against the limit
sum(pg_stat_activity_count) / on() pg_settings_max_connections

# PostgREST connection pool saturation
pgrst_db_pool_available
```

## Verifying

```sh
# Metrics reachable from inside the network
docker compose exec traefik wget -qO- http://localhost:8082/metrics | grep traefik_router
docker compose exec storage wget -qO- http://localhost:5000/metrics | head

# Loki received logs, run from a host on the observability network
curl -sG http://loki:3100/loki/api/v1/labels
curl -sG http://loki:3100/loki/api/v1/query \
  --data-urlencode 'query={service="supabase-db"}' | head

# Vector is not dropping events
docker compose logs vector | grep -iE "error|dropped"
```

In Grafana, a `traefik_router_request_duration_seconds` panel and a
`{service="supabase-auth"} | json` log panel should both return data.

## Notes

`out_of_order_action: accept` is set on the Loki sink. Loki 2.4 and later accept
out-of-order writes within their window; on an older Loki, drop the setting and
expect rejected batches when container clocks drift.

Vector is pinned at 0.28.1, which is old. The Loki sink works, but a bump is
worth doing on its own so a regression is easy to isolate.

`volumes/db/logs.sql` still creates the `_analytics` schema on a fresh database.
It is harmless and left alone; removing it is a separate change.
