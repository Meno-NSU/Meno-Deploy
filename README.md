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
curl -I  http://meno.nsu.ru                          # expect 301 → https
curl -skI https://meno.nsu.ru                        # expect 200 + valid cert (public)
# From OUTSIDE the NSU network (phone/hotspot): TLS handshake + 200, not a timeout
curl -skI https://meno.nsu.ru
```

## TLS certificate

- **Renewal** is automatic via the system `certbot.timer`; the `--deploy-hook`
  reloads nginx on renewal. Check it: `sudo certbot renew --dry-run`.
- **Using an NSU-issued cert instead of Let's Encrypt** (cert-agnostic): place the
  files on the server, point `ssl_certificate` / `ssl_certificate_key` in
  `nginx/meno.nsu.ru.conf` at them, run `sudo ./scripts/deploy.sh`, and do **not**
  run `issue-cert.sh`.

## Access gate (removed — the site is public)

The closed-pilot shared-token gate (nginx Basic Auth) was **removed after InfoSec
sign-off**. `https://meno.nsu.ru` is now public; the app's own email/password login
applies as usual.

**To re-gate** (e.g. a future restricted preview): restore the two `auth_basic`
directives in `nginx/meno.nsu.ru.conf` (a commented block there shows exactly what),
create the token, and re-deploy. `scripts/set-gate-token.sh` is kept for this.

```bash
sudo ./scripts/set-gate-token.sh        # create the shared token (printed once)
sudo ./scripts/deploy.sh
```

**Emergency — close access immediately:** `sudo systemctl stop nginx` (with the app
ports on loopback, the site then has no public path).

## Lock down `:9012` (mandatory)

With the gate removed, the site's **only** public path must be nginx `:443`. While
Meno-Web's Express binds `0.0.0.0:9012`, anyone can hit `84.237.50.35:9012` directly
and reach the app past the edge. Bind Express to `127.0.0.1` (`server.js`, default
host) and restart `pm2 meno-web`; the backend `:9006` already binds `127.0.0.1`.

**Verify before opening up:** if `:9012` is still the current (corporate) access path,
confirm `https://meno.nsu.ru` serves the app first, then close `:9012` — never before,
or you cut off current access.

### Verify the only public path is nginx :443

```bash
# From OUTSIDE the NSU network — these ports must NOT be reachable:
nc -vz meno.nsu.ru 9012   # expect: refused/timeout
nc -vz meno.nsu.ru 9006   # expect: refused/timeout
nc -vz meno.nsu.ru 9022   # expect: refused/timeout (vLLM EngineCore — must be loopback too)
# The public site works:
curl -skI https://meno.nsu.ru   # expect 200 + valid cert
# On the server — app ports loopback only:
ss -tlnp | grep -E ':(9012|9006|9022)'   # expect 127.0.0.1 only
```

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
