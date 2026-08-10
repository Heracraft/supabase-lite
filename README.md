# Self-Hosted Supabase, trimmed

A fork of Supabase's official [Docker self-hosting
setup](https://supabase.com/docs/guides/self-hosting/docker), cut down for
smaller servers and wired into an existing observability stack.

Three differences from upstream:

1. **Traefik instead of Kong** as the API gateway.
2. **Studio behind OIDC** instead of HTTP basic auth.
3. **Logs and metrics to Loki and Prometheus**, with Logflare removed.

Everything else tracks upstream. See [docs/upgrading.md](docs/upgrading.md) for
how the fork stays in sync.

## Quickstart

```sh
cp .env.example .env
./utils/generate-keys.sh          # writes secrets into .env
./utils/generate-htpasswd.sh      # dashboard password file
docker network create observability
docker compose up -d
```

Studio is on `${KONG_HTTP_PORT}` (8000 by default), behind basic auth using
`DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD`. To put it behind your identity
provider instead, see [docs/oidc.md](docs/oidc.md).

The `observability` network must exist before the stack starts, because the
compose file declares it `external`. If your LGTM stack already owns a network,
point `OBSERVABILITY_NETWORK` at it instead.

## What was removed

| Service | Why |
|---|---|
| `analytics` (Logflare) | Heaviest idle service. Logs go to Loki now |
| `kong` | Replaced by Traefik |

Logflare was the real saving. It is an Elixir application holding a `_analytics`
schema, and nearly every service in the stack waited on its health check at
startup.

**On the Kong figure.** An earlier version of this README credited the gateway
swap with ~748MB. That number is not typical for Kong, which defaults to
`nginx_worker_processes: auto`, one worker per core, so it scales with the
machine rather than the workload. Setting that to `1` would have recovered most
of it without replacing the gateway. Traefik still earns its place here, for the
OIDC middleware and the free per-route metrics, but not for that number.

Idle figures for this fork have not been measured on the current configuration.
Anything quoted here would be a guess, so nothing is quoted.

## What you give up

Studio's **Logs Explorer** and **Reports** tabs stop working. They query
Logflare in its own SQL dialect over `/analytics/v1`, and Grafana does not
provide that, so they are switched off rather than left throwing errors.

The **`/pg/` route to postgres-meta** is gone. postgres-meta does no
authentication of its own and its `/query` endpoint runs arbitrary SQL as a
privileged role, so it should never have been reachable behind a gateway check
weaker than Kong's literal key match. Studio still reaches it directly over the
compose network. See [docs/gateway.md](docs/gateway.md) if you need it back for
the Management API.

## Documentation

| | |
|---|---|
| [docs/gateway.md](docs/gateway.md) | Traefik layout, Kong route translation, how requests are gated, adding a route |
| [docs/oidc.md](docs/oidc.md) | Putting Studio behind an identity provider, and back |
| [docs/observability.md](docs/observability.md) | Loki and Prometheus wiring, scrape targets, LogQL and PromQL to start from |
| [docs/upgrading.md](docs/upgrading.md) | Merging upstream changes into the fork |
| [CHANGELOG.md](CHANGELOG.md) | Upstream service changes |
| [versions.md](versions.md) | Upstream image history |

## Services

- **[Studio](https://github.com/supabase/supabase/tree/master/apps/studio)** dashboard
- **[Traefik](https://traefik.io/traefik/)** API gateway
- **[Auth](https://github.com/supabase/auth)** JWT authentication
- **[PostgREST](https://github.com/PostgREST/postgrest)** REST API over Postgres
- **[Realtime](https://github.com/supabase/realtime)** database change broadcasting
- **[Storage](https://github.com/supabase/storage)** S3-compatible file API
- **[imgproxy](https://github.com/imgproxy/imgproxy)** image transformation
- **[postgres-meta](https://github.com/supabase/postgres-meta)** database management API
- **[PostgreSQL](https://github.com/supabase/postgres)** the database
- **[Edge Runtime](https://github.com/supabase/edge-runtime)** Deno functions
- **[Vector](https://github.com/vectordotdev/vector)** log shipping, to Loki
- **[Supavisor](https://github.com/supabase/supavisor)** connection pooler
- **[oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy)** OIDC for Studio, optional

## Security

The default configuration is not production-ready. Before deploying:

- Run `./utils/generate-keys.sh` and never ship the example values
- Terminate TLS in front of the stack, then set `OIDC_COOKIE_SECURE=true`
- Put Studio behind OIDC and restrict it by group, not just email domain
- Keep `api.insecure` off in `volumes/api/traefik.yml`; it exposes an
  unauthenticated endpoint that renders router configuration
- Review the gating trade-off in [docs/gateway.md](docs/gateway.md): the gateway
  checks that a credential is present, not that it is valid, and leaves
  validation to each service
- Set up backups

## Updating

1. Read [CHANGELOG.md](CHANGELOG.md) for breaking changes
2. Check [versions.md](versions.md) for new image versions
3. Follow [docs/upgrading.md](docs/upgrading.md) to merge upstream
4. `docker compose pull && docker compose up -d`

Back up the database first.

## Support

Self-hosted Supabase is community-supported.

- [GitHub Discussions](https://github.com/orgs/supabase/discussions?discussions_q=is%3Aopen+label%3Aself-hosted)
- [GitHub Issues](https://github.com/supabase/supabase/issues?q=is%3Aissue%20state%3Aopen%20label%3Aself-hosted)
- [Discord](https://discord.supabase.com)

Changes specific to this fork are not upstream's problem. Raise those here.
