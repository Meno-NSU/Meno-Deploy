#!/usr/bin/env bash
# Obtain (or renew on demand) the Let's Encrypt certificate for $DOMAIN using
# the webroot challenge. A vhost must already serve /.well-known/acme-challenge/
# from /var/www/certbot on port 80 (deploy.sh guarantees this).
#
# Requires: certbot installed (sudo apt-get install -y certbot).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
    set +a
fi
: "${DOMAIN:?DOMAIN must be set in .env}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL must be set in .env}"

WEBROOT=/var/www/certbot
mkdir -p "$WEBROOT"

certbot certonly \
    --webroot -w "$WEBROOT" \
    -d "$DOMAIN" \
    --email "$LETSENCRYPT_EMAIL" \
    --agree-tos --no-eff-email \
    --non-interactive \
    --deploy-hook "systemctl reload nginx"

echo "[issue-cert] certificate ready at /etc/letsencrypt/live/$DOMAIN/"
