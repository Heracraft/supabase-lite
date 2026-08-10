# Gateway

Traefik replaces Kong as the API gateway. This page covers what changed, why
requests are gated the way they are, and how to add a route.

## Layout

| File | Holds |
|---|---|
| `volumes/api/traefik.yml` | Static config: entrypoints, providers, metrics, access log |
| `volumes/api/dynamic/00-middlewares.yml` | CORS, prefix stripping, GraphQL rewrites, basic auth |
| `volumes/api/dynamic/10-services.yml` | Backend addresses |
| `volumes/api/dynamic/20-routers.yml` | Routing rules and priorities |
| `volumes/api/optional/30-auth.yml` | OIDC, copied into `dynamic/` to enable |
| `volumes/api/kong.yml` | The old Kong config, kept as the reference for this table |

Traefik's file provider merges everything in `dynamic/`. Two files defining the
same router key conflict with no defined winner, so shadow a router with a
higher `priority` instead of redefining it. That is how `30-auth.yml` swaps
Studio onto oauth2-proxy without touching `20-routers.yml`.

The directory is mounted as a directory, not file by file. Bind-mounting a
single file pins the container to one inode, and an editor that writes and
renames leaves Traefik reading the old copy, so `watch: true` appears to do
nothing. Mounting the directory avoids that.

## Route translation

| Path | Kong | Traefik | Gate |
|---|---|---|---|
| `/auth/v1/verify` | `auth-v1-open` | `auth-verify` | none |
| `/auth/v1/callback` | `auth-v1-open-callback` | `auth-callback` | none |
| `/auth/v1/authorize` | `auth-v1-open-authorize` | `auth-authorize` | none |
| `/auth/v1/` | `auth-v1` + key-auth + acl | `auth-secure` | credential present |
| `/rest/v1/` | `rest-v1` + key-auth + acl | `rest` | credential present |
| `/graphql/v1` | `graphql-v1` + request-transformer | `graphql` | credential present |
| `/realtime/v1/api` | `realtime-v1-rest` | `realtime-api` | credential present |
| `/realtime/v1/` | `realtime-v1-ws` | `realtime-ws` | credential present |
| `/storage/v1/` | `storage-v1` | `storage` | none |
| `/functions/v1/` | `functions-v1` | `functions` | none |
| `/analytics/v1/` | `analytics-v1` | removed | n/a |
| `/pg/` | `meta` | removed | n/a |
| `/` | n/a | `studio` | basic auth or OIDC |

## Why the gate checks presence, not value

Kong's `key-auth` plugin compared the incoming `apikey` against the real anon
and `service_role` keys. The first Traefik port reproduced that by embedding the
key literals in router rules. That broke two ways.

A browser CORS preflight carries `Origin` and `Access-Control-Request-*` and
nothing else. With the key in the rule, preflight matched no router, fell
through to the Studio catch-all and came back 401, so every cross-origin
browser client failed before its real request went out.

Traefik's API renders router rules verbatim at `/api/rawdata`. With
`api.insecure: true` that endpoint was unauthenticated on the compose network,
so anything that could reach it, including `functions` running user Deno code,
could read the `service_role` key.

Rules now check that a credential exists:

```
PathPrefix(`/rest/v1/`) && (
  Method(`OPTIONS`)
  || HeaderRegexp(`apikey`, `.+`)
  || QueryRegexp(`apikey`, `.+`)
  || HeaderRegexp(`Authorization`, `Bearer .+`)
)
```

**The trade-off.** A request with a junk `apikey` header now reaches PostgREST
or GoTrue instead of dying at the gateway. Every one of those services validates
the JWT itself against `JWT_SECRET`, so it is rejected there; what you lose is
the gateway shedding that load first. On a self-hosted single node this is
cheap. Behind an untrusted network, put a rate limiter in front.

`Method(OPTIONS)` in each gated rule is what lets preflight through. Traefik's
`cors` middleware answers the preflight directly without touching the backend.

## Priorities

Traefik's default priority is the rule string's length, so editing a rule can
silently reorder the table. Every router here sets one:

| Priority | Use |
|---|---|
| 100 | Specific sub-paths that must beat their own prefix (`/auth/v1/verify`, `/realtime/v1/api`) |
| 90 | Prefixes shadowed by a 100-level route (`/realtime/v1/`) |
| 80 | Ordinary service prefixes |
| 2 | `studio-oidc`, shadowing `studio` when OIDC is on |
| 1 | `studio` catch-all, always last |

## The Studio catch-all excludes API namespaces

Studio is a SPA and needs `PathPrefix('/')`, but a bare catch-all swallows
anything the API routers reject. A keyless `/rest/v1/` request then answers
`WWW-Authenticate: Basic`, which pops a browser login dialog on a failed API
call and advertises how the dashboard is protected.

The router excludes every API prefix, so those requests match nothing and get a
plain 404. `/analytics/v1/` stays in the exclusion list even though nothing
serves it, so a leftover client gets a 404 rather than a login prompt.

Adding a new API namespace means adding it to the exclusion list in both
`20-routers.yml` and `optional/30-auth.yml`.

## `/pg/` is deliberately absent

postgres-meta performs no authentication of its own, and its `/query` endpoint
executes arbitrary SQL as a privileged role. Kong gated it on a literal
`service_role` match, which a presence check does not replace: any request with
any `apikey` header would have full database access.

Studio does not need the route. It reaches the service directly over the compose
network via `STUDIO_PG_META_URL`.

If you need the Management API externally, do not re-add it with a presence
check. Put it behind the OIDC middleware, or terminate it on a separate
entrypoint that is not publicly bound.

## Adding a route

1. Backend address in `10-services.yml`.
2. Prefix-stripping middleware in `00-middlewares.yml` if the backend does not
   expect the public prefix.
3. Router in `20-routers.yml` with an explicit priority.
4. If it is an API namespace, add it to both Studio exclusion lists.

Check it without restarting the stack:

```sh
docker compose restart traefik
docker compose logs traefik | grep -i error
```

To see the compiled routing table, turn the API on for one run:

```sh
docker compose run --rm --service-ports traefik --api.insecure=true
curl -s localhost:8080/api/http/routers | jq '.[] | {name, rule, priority, status}'
```

Never leave `api.insecure` on in a running stack.

## Verifying a change

```sh
# Preflight must be admitted
curl -i -X OPTIONS localhost:8000/rest/v1/ \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: GET"          # 200

# Credentialled request routes
curl -i localhost:8000/rest/v1/ -H "apikey: $ANON_KEY"

# Keyless request is rejected without a basic-auth challenge
curl -i localhost:8000/rest/v1/                     # 404, no WWW-Authenticate

# Dashboard API stays shut
docker compose exec functions wget -qO- http://traefik:8080/api/rawdata   # fails
```
