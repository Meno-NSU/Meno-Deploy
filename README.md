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

## Access gate (closed pilot — required)

The whole site is behind a single shared token (nginx Basic Auth). It is **not
public** until InfoSec sign-off.

```bash
# On the server, once (prints the token a single time — copy it):
sudo ./scripts/set-gate-token.sh
# Rotate later (e.g. on leak or when someone leaves the group):
sudo ./scripts/set-gate-token.sh --rotate
sudo systemctl reload nginx
```

Testers open `https://meno.nsu.ru`, and the browser prompts for credentials:
enter user `menon` and the shared token. After that the Menon app loads and its
own email/password login applies as usual.

`deploy.sh` is **fail-closed**: it refuses to install the gated vhost if the token
file is missing, and `nginx -t` would fail too — there is no state where the app is
served without the gate.

**Emergency — close access immediately:** `sudo systemctl stop nginx` (with `:9012`
on loopback, the app then has no public path), or rotate the token.

## Lock down `:9012` (mandatory — right after the gate is verified)

The gate is bypassable while Meno-Web's Express binds `0.0.0.0:9012` (anyone can hit
`84.237.50.35:9012` directly). Close it by binding Express to `127.0.0.1` (`server.js`,
default host) and restarting `pm2 meno-web`; the backend `:9006` already binds
`127.0.0.1`.

**Order matters:** `:9012` is the *current* (corporate) access path and `meno.nsu.ru`
isn't serving the app yet — so close `:9012` **after** the gated path is confirmed
working, never before, or you cut off current access. The brief overlap where both
paths work is no more exposed than today (where `:9012` is already open).

### Rollout order

1. `sudo ./scripts/set-gate-token.sh` (capture the token).
2. `sudo ./scripts/deploy.sh` — gated `meno.nsu.ru` goes live (the cert is issued over
   `:80` without disrupting `:9012`).
3. Verify the gated path: `curl -skI -u menon:TOKEN https://meno.nsu.ru` → 200, and
   `curl -skI https://meno.nsu.ru` → 401.
4. **Only now** close the direct port: in Meno-Web bind `127.0.0.1`, `pm2 restart meno-web`.
5. Final no-bypass check (below).

### Verify nobody can bypass the gate

```bash
# From OUTSIDE the NSU network — these ports must NOT be reachable:
nc -vz meno.nsu.ru 9012   # expect: refused/timeout
nc -vz meno.nsu.ru 9006   # expect: refused/timeout
# Gate works:
curl -skI https://meno.nsu.ru                 # expect 401
curl -skI -u menon:THE_TOKEN https://meno.nsu.ru  # expect 200
# ACME stays open (renewal) and is NOT gated:
curl -I http://meno.nsu.ru/.well-known/acme-challenge/probe  # expect 404, not 401
# On the server:
ss -tlnp | grep -E ':(9012|9006)'   # expect 127.0.0.1 only
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
