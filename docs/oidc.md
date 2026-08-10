# OIDC for Studio

Studio ships behind HTTP basic auth. This puts it behind your identity provider
instead, using oauth2-proxy.

Only the dashboard is affected. API traffic to `/rest/v1`, `/auth/v1` and the
rest routes straight through, so `supabase-js` clients never touch the proxy.

## Understand this before enabling

**Studio has no user model.** Anyone the proxy admits gets full dashboard
access: every table, every row, the SQL editor, service-role credentials.
There are no roles inside Studio to fall back on. The proxy's allow-list is the
entire access control boundary.

`OIDC_ALLOWED_EMAIL_DOMAINS` and `OIDC_ALLOWED_GROUPS` both default to empty,
which admits nobody. Set one deliberately. An email domain is weak if anyone can
get an address in it; prefer a group.

## Setup

### 1. Register the application with your provider

Redirect URI:

```
${SUPABASE_PUBLIC_URL}/oauth2/callback
```

Request the `openid`, `email` and `profile` scopes. Add `groups` if you plan to
restrict by group; the claim has to actually appear in the ID token, which on
most providers is a per-application setting rather than a default.

### 2. Fill in `.env`

```sh
OIDC_ISSUER_URL=https://idp.example.com/application/o/supabase/
OIDC_CLIENT_ID=<from your provider>
OIDC_CLIENT_SECRET=<from your provider>
OIDC_COOKIE_SECRET=<./utils/generate-keys.sh>
OIDC_ALLOWED_EMAIL_DOMAINS=example.com
OIDC_ALLOWED_GROUPS=
OIDC_COOKIE_SECURE=false
```

`OIDC_ISSUER_URL` is the base URL, without `/.well-known/openid-configuration`.
oauth2-proxy appends that itself, and including it produces a discovery error
that reads like a network failure.

Generate the cookie secret with `./utils/generate-keys.sh`. It must decode to
exactly 16, 24 or 32 bytes, URL-safe and padded. The `base64_url_encode` helper
in that script strips padding, which oauth2-proxy rejects, so the generator uses
a separate path for this value.

### 3. Turn it on

```sh
cp volumes/api/optional/30-auth.yml volumes/api/dynamic/
docker compose --profile oidc up -d
```

Both steps are needed. The compose profile starts oauth2-proxy; the config
fragment tells Traefik to route Studio through it.

### 4. Set `OIDC_COOKIE_SECURE=true` in production

The session cookie is a full dashboard credential. Once `SUPABASE_PUBLIC_URL` is
https, set this to `true` and restart, so the cookie is never sent in the clear.

## How it works

oauth2-proxy sits in front of Studio as its upstream, rather than as a Traefik
`forwardAuth` middleware.

forwardAuth answers with a bare 401, so an unauthenticated browser gets an error
page instead of a login redirect unless you add an `errors` middleware to
rewrite the 401 into a redirect to `/oauth2/start`. As an upstream proxy,
oauth2-proxy performs the redirect itself and serves its own `/oauth2/*`
endpoints on the same listener, so one router covers everything.

`optional/30-auth.yml` is additive, not an override. Two files in the same
provider directory defining the same router key conflict with no defined winner.
The fragment adds `studio-oidc` at priority 2, matching the same paths as the
plain `studio` router at priority 1, so it shadows it cleanly.

## Turning it off

```sh
rm volumes/api/dynamic/30-auth.yml
docker compose stop oauth2-proxy
docker compose restart traefik
```

Basic auth comes back on its own, because the `studio` router underneath was
never removed. Regenerate the password file if you have not used it in a while:

```sh
./utils/generate-htpasswd.sh
```

That reads `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD` from `.env` and writes
`volumes/api/htpasswd`, which is gitignored. It uses openssl rather than
`htpasswd`, so there is no apache2-utils dependency.

## Troubleshooting

**Redirect loop.** `OAUTH2_PROXY_REDIRECT_URL` must match the registered URI
exactly, scheme and trailing path included. Check `SUPABASE_PUBLIC_URL` is the
address you actually browse to, not `localhost` behind a reverse proxy.

**403 after a successful login.** The provider authenticated you but the
allow-list rejected you. With `OIDC_ALLOWED_GROUPS` set, confirm the `groups`
claim is really in the token:

```sh
docker compose logs oauth2-proxy | grep -i "groups\|claim"
```

**Discovery fails at startup.** Confirm the issuer resolves from inside the
container, which is a different network view than your laptop:

```sh
docker compose exec oauth2-proxy wget -qO- \
  "${OIDC_ISSUER_URL}.well-known/openid-configuration"
```

**Cookie rejected.** With `OIDC_COOKIE_SECURE=true` over plain http the browser
drops the cookie silently and you loop back to login with no error.

**API calls break after enabling.** They should not; API prefixes are excluded
from the Studio router. If you added a new API namespace, add it to the
exclusion list in both `dynamic/20-routers.yml` and `optional/30-auth.yml`.
