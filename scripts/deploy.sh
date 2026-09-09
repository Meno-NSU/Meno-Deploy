#!/usr/bin/env bash
# Idempotent deploy of the meno.nsu.ru nginx vhost. Safe to re-run.
#
#   sudo ./scripts/deploy.sh
#
# Two-phase: when no TLS cert exists yet, first install an HTTP-only bootstrap
# vhost and obtain the certificate, then install the full TLS vhost. nginx is
# never reloaded unless `nginx -t` passes.
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

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/deploy.sh" >&2
    exit 1
fi

NGINX_AVAIL=/etc/nginx/sites-available
NGINX_ENABLED=/etc/nginx/sites-enabled
NGINX_SNIPPETS=/etc/nginx/snippets
WEBROOT=/var/www/certbot
CERT_LIVE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

reload_nginx() {
    nginx -t
    systemctl reload nginx
}

enable_site() {  # $1 = source conf in repo, $2 = site name
    install -m 0644 "$1" "$NGINX_AVAIL/$2"
    ln -sf "$NGINX_AVAIL/$2" "$NGINX_ENABLED/$2"
}

# 1. Snippets + ACME webroot.
install -d "$NGINX_SNIPPETS" "$WEBROOT"
install -m 0644 "$REPO_DIR/nginx/snippets/meno-proxy.conf" "$NGINX_SNIPPETS/meno-proxy.conf"
install -m 0644 "$REPO_DIR/nginx/snippets/meno-sse.conf"   "$NGINX_SNIPPETS/meno-sse.conf"

# Benchmark token map. The real file is created by scripts/set-bench-token.sh
# and is never in git; install a no-token placeholder if it is absent, so that
# $bench_ok is always defined. Referencing an undefined variable would make
# `nginx -t` fail and block this deploy entirely — and the benchmark endpoint
# is optional, so its absence must never stop the public site from deploying.
install -d /etc/nginx/conf.d
if [[ ! -f /etc/nginx/conf.d/meno-bench-token.conf ]]; then
    echo "[deploy] no benchmark token configured — installing the no-token placeholder"
    install -m 0600 -o root -g root \
        "$REPO_DIR/nginx/conf.d/meno-bench-token.placeholder.conf" \
        /etc/nginx/conf.d/meno-bench-token.conf
fi

# 2. First run only: bootstrap HTTP vhost + obtain cert.
if [[ ! -f "$CERT_LIVE" ]]; then
    echo "[deploy] no cert yet — installing bootstrap vhost and issuing certificate"
    enable_site "$REPO_DIR/nginx/meno.nsu.ru.bootstrap.conf" "$DOMAIN"
    rm -f "$NGINX_ENABLED/default"
    reload_nginx
    "$SCRIPT_DIR/issue-cert.sh"
fi

# The closed-pilot access gate has been removed (public launch), so the vhost no
# longer requires /etc/nginx/.meno_htpasswd. `nginx -t` below still guards every
# reload. To re-gate, restore auth_basic in nginx/meno.nsu.ru.conf, run
# scripts/set-gate-token.sh, and re-add a token-file check here.

# 3. Install the production vhost (overwrites the bootstrap site of the same name).
echo "[deploy] installing production vhost"
enable_site "$REPO_DIR/nginx/meno.nsu.ru.conf" "$DOMAIN"
rm -f "$NGINX_ENABLED/default"

# 4. Validate, then reload. `set -e` aborts before reload if `nginx -t` fails.
reload_nginx
echo "[deploy] done — https://$DOMAIN should be live"
