# Meno-Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an nginx reverse-proxy + TLS edge so `https://meno.nsu.ru` serves the Meno-Web frontend (and its `/v1` SSE API) securely, with all config tracked in this repo.

**Architecture:** nginx terminates TLS on `:443` and proxies to the existing Meno-Web Express server on `127.0.0.1:9012` (Variant A). `:80` serves ACME challenges and redirects to HTTPS. Config lives in the repo and is synced to `/etc/nginx` by an idempotent, two-phase `deploy.sh`. TLS is Let's Encrypt by default but cert-source-agnostic.

**Tech Stack:** nginx 1.24.0 (Ubuntu 24.04), Let's Encrypt / certbot (webroot), Bash, systemd.

**Note on "tests":** This is an infrastructure/config repo — there is no application code to unit-test. The verification analogs used throughout are: `bash -n` + `shellcheck` for scripts, `nginx -t` for config (authoritative run is on the server in Task 8), and live `curl`/SSE checks after deploy. Full design: `docs/superpowers/specs/2026-06-17-meno-deploy-design.md`.

**Server facts (already verified):** host `meno` / user `m.kulakov`, Ubuntu 24.04.1, nginx 1.24.0 active on `:80` (default vhost), backend on `127.0.0.1:9006`, Express `pm2 meno-web` on `0.0.0.0:9012`, no certs yet, CAA empty, inbound `:80` and `:443` open. Repos on host: `~/Meno-Stand/Meno-Web`, `~/Meno-Stand/Meno-Stand-RAG-Core`.

---

## File Structure

All paths relative to the repo root (`~/Projects/Meno-Deploy` locally, `~/Meno-Stand/Meno-Deploy` on the server).

| File | Responsibility |
|---|---|
| `.gitignore` | Keep the real `.env` and OS cruft out of git |
| `.env.example` | Documents `DOMAIN` + `LETSENCRYPT_EMAIL` consumed by the scripts |
| `nginx/snippets/meno-proxy.conf` | Shared forwarded-headers proxy settings |
| `nginx/snippets/meno-sse.conf` | SSE/streaming settings (no buffering, long timeouts) |
| `nginx/meno.nsu.ru.bootstrap.conf` | HTTP-only vhost used once, to obtain the first cert |
| `nginx/meno.nsu.ru.conf` | Production vhost: `:80` redirect + `:443` TLS proxy |
| `scripts/issue-cert.sh` | Obtain/renew the Let's Encrypt cert via webroot |
| `scripts/deploy.sh` | Idempotent two-phase deploy into `/etc/nginx` |
| `README.md` | Quickstart + runbook (deploy, renew, Variant B, `:9012` fix, troubleshoot, rollback) |

Cross-repo follow-up (Task 9, in **Meno-Web**): bind Express to `127.0.0.1`.

---

## Task 1: Repo scaffolding (`.gitignore`, `.env.example`)

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Local environment — never commit the real values/secrets
.env

# OS / editor cruft
.DS_Store
*.swp
```

- [ ] **Step 2: Create `.env.example`**

```bash
# Public domain served by nginx.
DOMAIN=meno.nsu.ru

# Email used for Let's Encrypt registration and expiry notices.
# Replace with a real address you control before deploying.
LETSENCRYPT_EMAIL=you@example.com
```

- [ ] **Step 3: Verify `.env` would be ignored**

Run: `printf 'DOMAIN=x\n' > .env && git status --porcelain && rm .env`
Expected: output shows `?? .env.example` and `?? .gitignore` but **not** `.env`.

- [ ] **Step 4: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: add gitignore and env example"
```

---

## Task 2: nginx proxy + SSE snippets

**Files:**
- Create: `nginx/snippets/meno-proxy.conf`
- Create: `nginx/snippets/meno-sse.conf`

- [ ] **Step 1: Create `nginx/snippets/meno-proxy.conf`**

```nginx
# Shared proxy settings for forwarding to the Meno-Web Express server.
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Connection        "";
```

- [ ] **Step 2: Create `nginx/snippets/meno-sse.conf`**

```nginx
# Server-Sent Events / streaming chat: never buffer, allow long-lived streams.
# Without proxy_buffering off the chat stream is held by nginx and "hangs".
proxy_buffering off;
proxy_cache off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
```

- [ ] **Step 3: Sanity-check the snippet contents**

Run: `grep -q 'proxy_buffering off;' nginx/snippets/meno-sse.conf && grep -q 'X-Forwarded-Proto' nginx/snippets/meno-proxy.conf && echo OK`
Expected: `OK` (authoritative `nginx -t` happens on the server in Task 8).

- [ ] **Step 4: Commit**

```bash
git add nginx/snippets/
git commit -m "feat(nginx): add proxy and SSE snippets"
```

---

## Task 3: nginx vhosts (bootstrap + production)

**Files:**
- Create: `nginx/meno.nsu.ru.bootstrap.conf`
- Create: `nginx/meno.nsu.ru.conf`

- [ ] **Step 1: Create `nginx/meno.nsu.ru.bootstrap.conf`**

```nginx
# Bootstrap vhost: HTTP only. Used for the very first Let's Encrypt issuance,
# before any TLS certificate exists. deploy.sh replaces it with the production
# vhost (meno.nsu.ru.conf) immediately after the cert is obtained.
server {
    listen 80;
    listen [::]:80;
    server_name meno.nsu.ru;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 404;
    }
}
```

- [ ] **Step 2: Create `nginx/meno.nsu.ru.conf`**

Note: nginx 1.24 uses the `listen ... http2` parameter (the `http2 on;` directive only exists from 1.25.1).

```nginx
# Production vhost for meno.nsu.ru — TLS edge in front of the Meno-Web
# Express server on 127.0.0.1:9012.
# Design: docs/superpowers/specs/2026-06-17-meno-deploy-design.md

server {
    # HTTP: serve ACME renewals, redirect everything else to HTTPS.
    listen 80;
    listen [::]:80;
    server_name meno.nsu.ru;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # HTTPS: TLS termination and reverse proxy.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name meno.nsu.ru;

    ssl_certificate     /etc/letsencrypt/live/meno.nsu.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meno.nsu.ru/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    access_log /var/log/nginx/meno.nsu.ru.access.log;
    error_log  /var/log/nginx/meno.nsu.ru.error.log;

    client_max_body_size 25m;

    # API + SSE streaming chat.
    location /v1/ {
        proxy_pass http://127.0.0.1:9012;
        include snippets/meno-proxy.conf;
        include snippets/meno-sse.conf;
    }

    # Static assets + SPA fallback (served by the Express server).
    location / {
        proxy_pass http://127.0.0.1:9012;
        include snippets/meno-proxy.conf;
    }
}
```

- [ ] **Step 3: Sanity-check vhost contents**

Run: `grep -q 'listen 443 ssl http2;' nginx/meno.nsu.ru.conf && ! grep -q 'http2 on;' nginx/meno.nsu.ru.conf && grep -q 'return 404;' nginx/meno.nsu.ru.bootstrap.conf && echo OK`
Expected: `OK` (confirms 1.24-correct http2 syntax and bootstrap is HTTP-only).

- [ ] **Step 4: Commit**

```bash
git add nginx/meno.nsu.ru.bootstrap.conf nginx/meno.nsu.ru.conf
git commit -m "feat(nginx): add bootstrap and production vhosts for meno.nsu.ru"
```

---

## Task 4: `scripts/issue-cert.sh`

**Files:**
- Create: `scripts/issue-cert.sh`

- [ ] **Step 1: Create `scripts/issue-cert.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and check syntax**

Run: `chmod +x scripts/issue-cert.sh && bash -n scripts/issue-cert.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Lint with shellcheck**

Run: `shellcheck scripts/issue-cert.sh && echo LINT_OK`
Expected: `LINT_OK` (no findings). If `shellcheck` is missing: `brew install shellcheck`.

- [ ] **Step 4: Commit**

```bash
git add scripts/issue-cert.sh
git commit -m "feat(scripts): add Let's Encrypt webroot issuance script"
```

---

## Task 5: `scripts/deploy.sh`

**Files:**
- Create: `scripts/deploy.sh`

- [ ] **Step 1: Create `scripts/deploy.sh`**

```bash
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

# 2. First run only: bootstrap HTTP vhost + obtain cert.
if [[ ! -f "$CERT_LIVE" ]]; then
    echo "[deploy] no cert yet — installing bootstrap vhost and issuing certificate"
    enable_site "$REPO_DIR/nginx/meno.nsu.ru.bootstrap.conf" "$DOMAIN"
    rm -f "$NGINX_ENABLED/default"
    reload_nginx
    "$SCRIPT_DIR/issue-cert.sh"
fi

# 3. Install the production vhost (overwrites the bootstrap site of the same name).
echo "[deploy] installing production vhost"
enable_site "$REPO_DIR/nginx/meno.nsu.ru.conf" "$DOMAIN"
rm -f "$NGINX_ENABLED/default"

# 4. Validate, then reload. `set -e` aborts before reload if `nginx -t` fails.
reload_nginx
echo "[deploy] done — https://$DOMAIN should be live"
```

- [ ] **Step 2: Make executable and check syntax**

Run: `chmod +x scripts/deploy.sh && bash -n scripts/deploy.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Lint with shellcheck**

Run: `shellcheck scripts/deploy.sh && echo LINT_OK`
Expected: `LINT_OK` (no findings).

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy.sh
git commit -m "feat(scripts): add idempotent two-phase nginx deploy script"
```

---

## Task 6: `README.md` runbook

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

````markdown
# Meno-Deploy

Public edge for **Meno-Web** at `https://meno.nsu.ru`: an nginx reverse proxy that
terminates TLS and forwards to the Meno-Web Express server on `127.0.0.1:9012`
(which serves the SPA and proxies `/v1/* → 127.0.0.1:9006`).

This repo owns **only** the public edge (nginx + TLS). Application lifecycle stays
with the app repos (`run_backend.sh`, pm2). Design:
`docs/superpowers/specs/2026-06-17-meno-deploy-design.md`.

```
Internet ──:80──▶ nginx ── ACME + 301→https
         ──:443─▶ nginx (TLS) ──▶ 127.0.0.1:9012 (Express: static + SPA + /v1→:9006)
```

## Prerequisites (server)

- Ubuntu with nginx already installed (host `meno` runs nginx 1.24.0).
- certbot: `sudo apt-get update && sudo apt-get install -y certbot`
- DNS `meno.nsu.ru → 84.237.50.35` and inbound `:80`/`:443` open (both verified).

## First deploy

```bash
# On the server, next to the other repos:
cd ~/Meno-Stand
git clone https://github.com/Meno-NSU/Meno-Deploy.git
cd Meno-Deploy
cp .env.example .env
# edit .env — set a real LETSENCRYPT_EMAIL
sudo ./scripts/deploy.sh
```

`deploy.sh` is idempotent and two-phase: on the first run it installs an HTTP-only
bootstrap vhost, obtains the Let's Encrypt cert, then installs the full TLS vhost.
nginx is reloaded only if `nginx -t` passes.

## Re-deploy after a config change

```bash
cd ~/Meno-Stand/Meno-Deploy && git pull && sudo ./scripts/deploy.sh
```

## Verify

```bash
curl -I  http://meno.nsu.ru                      # expect 301 → https
curl -skI https://meno.nsu.ru                    # expect 200 + valid cert
# From OUTSIDE the NSU network (phone/hotspot): expect a TLS handshake, not a timeout
curl -skI https://meno.nsu.ru
```

## TLS certificate

- **Renewal** is automatic via the system `certbot.timer`; the `--deploy-hook`
  reloads nginx on renewal. Check it: `sudo certbot renew --dry-run`.
- **Using an NSU-issued cert instead of Let's Encrypt** (cert-agnostic): place the
  files on the server, point `ssl_certificate` / `ssl_certificate_key` in
  `nginx/meno.nsu.ru.conf` at them, run `sudo ./scripts/deploy.sh`, and do **not**
  run `issue-cert.sh`.

## Security follow-up: lock down `:9012`

The Meno-Web Express server currently binds `0.0.0.0:9012`, i.e. it is reachable
directly from the internet, bypassing TLS. Fix it in the **Meno-Web** repo by
binding to `127.0.0.1` (one-line change in `server.js`, default host). nginx
proxies to `127.0.0.1:9012` so this is transparent to users.

## Future optimization: Variant B

To remove the Node hop under heavy load, nginx can serve the SPA build directly
and proxy `/v1` straight to `:9006`. This is a vhost swap only; see the design doc.

## Deferred hardening (not built yet)

Tracked in the design doc (§11); add when needed, after HTTPS is confirmed stable:

- **HSTS** — add `add_header Strict-Transport-Security "max-age=31536000" always;`
  to the `:443` server block. Only after HTTPS is confirmed working, since it locks
  browsers onto HTTPS.
- **Rate limiting** — `limit_req` in front of `/v1/` to shield the backend from
  abuse (tune so it never throttles legitimate bursts; note arena = 2 concurrent).
- **CI** — a GitHub Actions job running `nginx -t` (in an `nginx` container) and
  `shellcheck` on every push.

## Troubleshooting

- `nginx -t` fails after edit → fix the reported file; `deploy.sh` will not reload
  a broken config.
- 502 from nginx → the Express server (`pm2 meno-web`) is down: `pm2 restart meno-web`.
- Chat stream "hangs" → confirm `/v1/` includes `snippets/meno-sse.conf`
  (`proxy_buffering off`).
- certbot challenge fails → confirm inbound `:80` and that
  `/.well-known/acme-challenge/` is served from `/var/www/certbot`.

## Rollback

```bash
# Restore the stock default site and drop the meno vhost:
sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-enabled/meno.nsu.ru
sudo nginx -t && sudo systemctl reload nginx
```
````

- [ ] **Step 2: Verify README mentions the key runbook entries**

Run: `for s in "First deploy" "certbot renew --dry-run" "Variant B" "HSTS" "Rollback" ":9012"; do grep -q "$s" README.md || echo "MISSING: $s"; done; echo DONE`
Expected: `DONE` with no `MISSING:` lines.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add deploy runbook README"
```

---

## Task 7: Push the repo to GitHub

The design spec and this plan are already committed locally. The server clones
from GitHub in Task 8, so `main` must be pushed first.

- [ ] **Step 1: Push `main` to origin** (requires your go-ahead — it publishes the repo)

Run: `git push -u origin main`
Expected: branch `main` set up to track `origin/main`; objects pushed.

- [ ] **Step 2: Confirm remote state**

Run: `git log --oneline origin/main | head`
Expected: lists the design spec, the artifact commits (Tasks 1–6), and this plan.

---

## Task 8: Deploy on the server and verify (operational)

Run these **on the server** (`m.kulakov@meno`). This is the live verification of the whole repo.

- [ ] **Step 1: Clone and configure**

```bash
cd ~/Meno-Stand
git clone https://github.com/Meno-NSU/Meno-Deploy.git
cd Meno-Deploy
cp .env.example .env
# edit .env: set a real LETSENCRYPT_EMAIL (DOMAIN already meno.nsu.ru)
```

- [ ] **Step 2: Ensure certbot is present**

Run: `command -v certbot || sudo apt-get update && sudo apt-get install -y certbot`
Expected: a certbot path, or successful install.

- [ ] **Step 3: Run the deploy**

Run: `sudo ./scripts/deploy.sh`
Expected: log lines ending with `[deploy] done — https://meno.nsu.ru should be live`. `nginx -t` reports `syntax is ok` / `test is successful`. A cert appears under `/etc/letsencrypt/live/meno.nsu.ru/`.

- [ ] **Step 4: Verify HTTP redirect and HTTPS locally**

Run: `curl -I http://meno.nsu.ru ; curl -skI https://meno.nsu.ru`
Expected: first → `301` with `Location: https://meno.nsu.ru/`; second → `200`.

- [ ] **Step 5: Verify HTTPS from outside the NSU network**

Run (from a phone/hotspot or external host): `curl -skI https://meno.nsu.ru`
Expected: `200` (TLS handshake succeeds). A timeout here means the firewall REJECTs inbound `:443` → open an NSU ticket (per design §12).

- [ ] **Step 6: SSE smoke test (stream is not buffered)**

The streaming endpoint is `POST /v1/chat/completions` (`stream: true`) and requires a Bearer token, so the reliable check is through the app:

In a browser, open `https://meno.nsu.ru`, sign in, and send a chat message.
Expected: the assistant's reply renders **progressively** (token-by-token, with live "thinking"/agent-stage updates). If the full reply instead appears all at once after a long pause, nginx is buffering — re-check that the `/v1/` location includes `snippets/meno-sse.conf` (`proxy_buffering off`).

Optional CLI variant, using a token you already hold from signing in (DevTools → Network → any `/v1` request's `Authorization` header) and a `modelId` from `GET /v1/models`:

```bash
curl -N -s https://meno.nsu.ru/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hello"}],"modelId":"'"$MODEL_ID"'","stream":true}' | head -c 300
```
Expected: incremental `data:` SSE chunks, not one buffered blob.

- [ ] **Step 7: Confirm the default site is gone**

Run: `ls /etc/nginx/sites-enabled/`
Expected: `meno.nsu.ru` present, `default` absent.

---

## Task 9: Follow-up — bind Meno-Web Express to `127.0.0.1` (repo: Meno-Web)

This lands in the **Meno-Web** repo (`~/PycharmProjects/Meno-Web` locally), as its own commit. It removes the direct-from-internet exposure of `:9012`.

**Files:**
- Modify: `server.js` (Meno-Web) — the `app.listen(...)` call
- Modify: `example.env` (Meno-Web) — document the `HOST` var

- [ ] **Step 1: Make the bind host configurable, default `127.0.0.1`**

In `server.js`, replace:

```javascript
app.listen(PORT, '0.0.0.0', () => {
    console.log(`✅ Meno-Web server listening on http://0.0.0.0:${PORT}`);
    console.log(`   Proxying /v1/* → ${BACKEND_URL}`);
});
```

with:

```javascript
const HOST = process.env.HOST || '127.0.0.1';

app.listen(PORT, HOST, () => {
    console.log(`✅ Meno-Web server listening on http://${HOST}:${PORT}`);
    console.log(`   Proxying /v1/* → ${BACKEND_URL}`);
});
```

And add near the top, beside the existing `PORT`/`BACKEND_URL` constants, nothing
else is required — `HOST` is read inline above.

- [ ] **Step 2: Document `HOST` in `example.env`**

Append to Meno-Web's `example.env`:

```bash
# Interface the web server binds to. Default 127.0.0.1 so the app is only
# reachable via the nginx TLS proxy. Set to 0.0.0.0 only for direct local dev.
HOST=127.0.0.1
```

- [ ] **Step 3: Verify the server still starts and binds locally**

Run (in Meno-Web): `npm run build && (node server.js & sleep 2 ; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9012/ ; kill %1)`
Expected: `200`, and the startup log shows `http://127.0.0.1:9012`.

- [ ] **Step 4: Commit (in the Meno-Web repo)**

```bash
git add server.js example.env
git commit -m "fix(server): bind to 127.0.0.1 by default (serve only via nginx)"
```

- [ ] **Step 5: Redeploy Meno-Web on the server and confirm `:9012` is local-only**

```bash
# On the server, in ~/Meno-Stand/Meno-Web after git pull + rebuild:
pm2 restart meno-web
ss -tlnp | grep ':9012'        # expect 127.0.0.1:9012, NOT 0.0.0.0:9012
curl -skI https://meno.nsu.ru  # expect 200 — proxy path still works
```
Expected: `:9012` bound to `127.0.0.1`; the public site still returns `200`.

---

## Done when

- `https://meno.nsu.ru` serves the Meno-Web SPA with a valid certificate, from inside and outside the NSU network.
- `http://meno.nsu.ru` 301-redirects to HTTPS.
- SSE chat streams without buffering.
- `certbot renew --dry-run` succeeds.
- Express `:9012` is bound to `127.0.0.1` (Task 9).
- All config is committed and pushed to `Meno-NSU/Meno-Deploy`.
