#!/bin/sh
#
# Generates volumes/api/htpasswd for Traefik's basicAuth middleware from
# DASHBOARD_USERNAME and DASHBOARD_PASSWORD in .env.
#
# This replaces the previous approach of installing apache2-utils inside the
# Traefik container at every boot and running the gateway as root. Uses
# openssl, which utils/generate-keys.sh already depends on, so there is no
# htpasswd binary to install.
#
# The output file is gitignored. Re-run after changing the dashboard password.
#
# Not needed when Studio is behind OIDC; see docs/oidc.md.

set -e

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required but not found."
    exit 1
fi

if [ ! -f .env ]; then
    echo "Error: no .env file in the current directory."
    echo "Run this from the repository root."
    exit 1
fi

username=$(grep -E '^DASHBOARD_USERNAME=' .env | head -n1 | cut -d= -f2- | tr -d '"')
password=$(grep -E '^DASHBOARD_PASSWORD=' .env | head -n1 | cut -d= -f2- | tr -d '"')

if [ -z "$username" ] || [ -z "$password" ]; then
    echo "Error: DASHBOARD_USERNAME and DASHBOARD_PASSWORD must be set in .env."
    exit 1
fi

outfile="volumes/api/htpasswd"

# -apr1 is Apache's MD5 variant. Traefik accepts it, and unlike bcrypt it is
# available in every openssl build.
hash=$(openssl passwd -apr1 "$password")

printf '%s:%s\n' "$username" "$hash" > "$outfile"
chmod 600 "$outfile"

echo "Wrote $outfile for user '$username'."
echo "Restart the gateway to pick it up: docker compose restart traefik"
