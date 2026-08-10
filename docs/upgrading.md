# Upgrading from upstream

This repo is a fork of Supabase's official self-hosted compose stack. The
`reference` branch mirrors upstream; `master` carries the changes described in
the README.

## Branch layout

```
reference   upstream, unmodified
master      this fork
```

Pull upstream in, then merge:

```sh
git checkout reference
git pull                     # or fetch from supabase/supabase directly
git checkout master
git merge reference
```

## Files that conflict every time

| File | Why | What to do |
|---|---|---|
| `docker-compose.yml` | Both sides edit it constantly | Merge by hand, keep the fork's networks, metrics vars, and the absence of `analytics` |
| `volumes/logs/vector.yml` | Upstream keeps Logflare sinks | Keep the fork's Loki sink; take upstream's transforms if they improved parsing |
| `.env.example` | Upstream adds and removes keys | Take upstream's additions, keep the OIDC and observability blocks |

## Files upstream owns

Take upstream's version unless you have a specific reason not to: everything
under `volumes/db/`, `volumes/functions/`, `volumes/pooler/`, plus `reset.sh`,
`CHANGELOG.md` and `versions.md`.

## Files this fork owns

Upstream does not have these. Conflicts here mean something went wrong with the
merge, not that upstream changed them.

- `volumes/api/traefik.yml`
- `volumes/api/dynamic/`
- `volumes/api/optional/`
- `utils/generate-htpasswd.sh`
- `docs/`

`volumes/api/kong.yml` is upstream's and is kept deliberately even though Kong
is gone. It is the reference for the route translation table in
[gateway.md](gateway.md). When upstream adds a route there, decide whether this
fork needs it and add the equivalent to `dynamic/20-routers.yml`.

## After merging

Upstream changes to `kong.yml` do not reach the running gateway. Nothing tells
you a route stopped matching, so check by hand:

```sh
# Did upstream add or change a route?
git diff reference...master -- volumes/api/kong.yml

# Config still parses
docker compose config >/dev/null

# No secrets leaked into gateway config
grep -rE 'eyJ[A-Za-z0-9_-]{20,}' volumes/api/     # expect no hits

# Routing table intact
docker compose up -d
curl -i -X OPTIONS localhost:8000/rest/v1/ \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: GET"          # 200
curl -o /dev/null -s -w '%{http_code}\n' localhost:8000/rest/v1/    # 404
```

Then walk the paths that image bumps most often disturb: sign up through
`/auth/v1`, select through `/rest/v1`, open a Realtime socket, upload through
`/storage/v1`, invoke `/functions/v1/hello`, and connect through Supavisor on
6543.

## Image pins

`versions.md` tracks upstream's image history. This fork pins three images
upstream does not ship:

| Image | Pin | Note |
|---|---|---|
| `traefik` | v3.0 | Released 2024. A bump is worth doing on its own; router matcher names changed between v2 and v3 |
| `quay.io/oauth2-proxy/oauth2-proxy` | v7.7.1 | Not yet pulled in this environment; confirm on first `docker compose --profile oidc pull` |
| `quay.io/prometheuscommunity/postgres-exporter` | v0.15.0 | |

`timberio/vector` is pinned at 0.28.1 from upstream, which is early 2023. The
Loki sink works there, but a bump would be worth its own commit.
