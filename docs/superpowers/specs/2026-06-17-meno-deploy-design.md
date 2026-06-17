# Meno-Deploy — Design

**Date:** 2026-06-17
**Status:** Approved (design phase)
**Repo:** https://github.com/Meno-NSU/Meno-Deploy

## 1. Purpose & scope

`Meno-Deploy` is the infrastructure-as-code repository that exposes the **Meno-Web**
frontend at the public address **`meno.nsu.ru`** (84.237.50.35) over HTTPS.

It owns exactly one concern: the **public edge** — an nginx reverse proxy that
terminates TLS and forwards traffic to the already-running Meno-Web Express
server. It does **not** own application lifecycle (that stays with the app repos'
`run_backend.sh` / pm2).

**Goal:** a browser hitting `https://meno.nsu.ru` reaches the Meno-Web SPA and its
`/v1/*` API (including SSE chat streaming) securely, reproducibly, and with
config tracked in git.

## 2. Current state (diagnosed on the server, 2026-06-17)

Host `meno` (user `m.kulakov`), Ubuntu 24.04.1 LTS.

| Component | State |
|---|---|
| Backend `meno-rag-api` | listening on `127.0.0.1:9006` (localhost only — good), runs from `~/Meno-Stand/Meno-Stand-RAG-Core/.venv` |
| Frontend Express (`pm2 meno-web`) | listening on `0.0.0.0:9012`, returns 200; serves static + SPA fallback, proxies `/v1/* → :9006` |
| nginx | **installed & active**, listening on `:80` only, serving the **default Ubuntu page** (`sites-enabled/default`, `conf.d` empty) — not proxying to the app yet |
| `:443` | **no listener** — HTTPS does not work yet |
| TLS certs | none (`/etc/letsencrypt/live/` empty) |
| Repos on host | `~/Meno-Stand/Meno-Web`, `~/Meno-Stand/Meno-Stand-RAG-Core` |

**Correction to the original assumption:** the server was *not* actually serving
HTTPS — only HTTP on `:80` with the stock nginx welcome page.

## 3. Prerequisites (verified)

| Check | Result | Meaning |
|---|---|---|
| `dig CAA nsu.ru` / `meno.nsu.ru` | empty | no CA restriction → Let's Encrypt may issue |
| inbound `:80` | open | HTTP-01 ACME challenge works |
| inbound `:443` (probed from outside NSU network) | "Connection refused" | RST reached host → firewall **passes** 443; only a listener is missing |
| nginx | active | reuse it, just add a vhost |

Conclusion: **Let's Encrypt + Variant A are fully applicable**, no NSU firewall
ticket required. (Residual edge case: a REJECT-style firewall could also yield
"refused" without forwarding; confirmed false-positive-free by `curl https://meno.nsu.ru`
from outside immediately after deploy — see §10.)

## 4. Architecture (Variant A — nginx in front of the existing Express server)

```
                       meno.nsu.ru (84.237.50.35)
  Internet
    │  :80  ──▶ nginx :80   ── /.well-known/acme-challenge/ ─▶ webroot (Let's Encrypt)
    │                        └─ everything else ─▶ 301 https://
    │
    │  :443 ─TLS─▶ nginx :443  ── /v1/  ─▶ 127.0.0.1:9012  (SSE: proxy_buffering off)
                               └─ /     ─▶ 127.0.0.1:9012  (static + SPA fallback)
                                              │
                              Express (pm2 meno-web) ── /v1/* ─▶ 127.0.0.1:9006 (backend)
```

nginx is the **only** internet-facing process. Express and the backend stay on
localhost. The Express layer is left untouched — it keeps serving static assets,
SPA fallback, and the `/v1` proxy.

**Rationale for A over B (nginx-serves-static-directly):** minimal change, matches
the stated goal ("expose the Meno-Web frontend's address"), and keeps `server.js`
owned by the frontend team. Variant B (better under the 50–100 concurrent-user
load target, removes a Node hop) is documented as a future optimization (§11) and
is reachable by swapping the vhost only.

## 5. Repository layout

```
Meno-Deploy/
├── README.md                          # quickstart + runbook
├── .env.example                       # DOMAIN, LETSENCRYPT_EMAIL (consumed by scripts)
├── .gitignore                         # ignores real .env
├── nginx/
│   ├── meno.nsu.ru.conf               # production vhost (:80 redirect + :443 TLS)
│   ├── meno.nsu.ru.bootstrap.conf     # http-only vhost for the first cert issuance
│   └── snippets/
│       ├── meno-proxy.conf            # forwarded headers, proxy_http_version 1.1
│       └── meno-sse.conf              # streaming: proxy_buffering off, long timeouts
├── scripts/
│   ├── deploy.sh                      # idempotent: lay down config, nginx -t, reload
│   └── issue-cert.sh                  # certbot webroot issuance + reload deploy-hook
└── docs/superpowers/specs/2026-06-17-meno-deploy-design.md
```

Source of truth is the repo; `deploy.sh` syncs configs into `/etc/nginx/...`,
validates, and reloads. One domain → the nginx configs are **concrete and literal**
(domain and the `127.0.0.1:9012` upstream baked in, so `nginx -t` runs directly on
the repo files). `.env` carries only what the **scripts** need — `DOMAIN` and
`LETSENCRYPT_EMAIL` for `issue-cert.sh`. No templating engine (YAGNI).

> Note: `harden-frontend.sh` was intentionally **dropped**. Locking down `:9012`
> is handled by a one-line bind change in Meno-Web (§9), not by shipping firewall
> tooling from this repo (avoids the SSH lock-out footgun).

## 6. nginx vhost design

**`meno.nsu.ru.conf`** — two server blocks:

```nginx
server {                                   # :80 — ACME challenge + redirect
    listen 80; listen [::]:80;
    server_name meno.nsu.ru;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {                                   # :443 — TLS edge
    listen 443 ssl; listen [::]:443 ssl; http2 on;
    server_name meno.nsu.ru;

    ssl_certificate     /etc/letsencrypt/live/meno.nsu.ru/fullchain.pem;   # cert-agnostic:
    ssl_certificate_key /etc/letsencrypt/live/meno.nsu.ru/privkey.pem;     # swap for an NSU cert
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/meno.nsu.ru.access.log;
    error_log  /var/log/nginx/meno.nsu.ru.error.log;
    client_max_body_size 25m;

    location /v1/ {                        # SSE chat streaming
        proxy_pass http://127.0.0.1:9012;
        include snippets/meno-proxy.conf;
        include snippets/meno-sse.conf;
    }
    location / {                           # static + SPA
        proxy_pass http://127.0.0.1:9012;
        include snippets/meno-proxy.conf;
    }
}
```

**`snippets/meno-proxy.conf`:**

```nginx
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Connection        "";
```

**`snippets/meno-sse.conf`:**

```nginx
proxy_buffering off;        # critical: without this nginx buffers the stream and chat "hangs"
proxy_cache off;
proxy_read_timeout 3600s;   # long-lived SSE connections must not be cut
proxy_send_timeout 3600s;
```

`proxy_buffering off` on `/v1/` is the load-critical setting for the 50–100
concurrent-stream target. `HSTS` (`Strict-Transport-Security`) is added in a
**second pass after** HTTPS is confirmed working, to avoid locking browsers onto
HTTPS while still debugging.

## 7. TLS / certificates

- **Issuance** (`issue-cert.sh`):
  `certbot certonly --webroot -w /var/www/certbot -d meno.nsu.ru --email "$LETSENCRYPT_EMAIL" --agree-tos -n`
  Needs only `:80` (open). CAA is clear, so issuance succeeds.
- **Renewal:** the system `certbot.timer` (installed by Ubuntu's certbot package)
  renews automatically; a `--deploy-hook "systemctl reload nginx"` reloads nginx on
  renewal. Validate with `certbot renew --dry-run`.
- **Cert-agnostic:** if NSU issues its own certificate, drop the files in and point
  the two `ssl_certificate*` paths at them; the rest of the config and `deploy.sh`
  are unchanged, and `issue-cert.sh` is simply not run.

## 8. `deploy.sh` (idempotent, two-phase)

The `:443` block references a certificate that does not exist on the first run, so
`nginx -t` would fail. The script is therefore self-healing and two-phase:

```
1. Lay down snippets; ensure /var/www/certbot exists.
2. If the cert is MISSING → install the bootstrap vhost (:80 only), reload,
   run issue-cert.sh.
3. Install the production vhost (:80 + :443); remove `default` from sites-enabled.
4. nginx -t  → on success: systemctl reload nginx
             → on failure: DO NOT reload; exit non-zero with the error.
```

Run on the host: `git pull && sudo ./scripts/deploy.sh`. Re-running is safe.

## 9. Security: locking down `:9012`

Express currently binds `0.0.0.0:9012`, i.e. it is reachable directly from the
internet, bypassing TLS. **Chosen fix:** bind Express to `127.0.0.1` — a one-line,
revertable change in the **Meno-Web** repo (`server.js` / `.env`), done as a
separate commit there. `Meno-Deploy` does not ship firewall tooling.

This repo's runbook records the recommendation and the exact change; it is tracked
as a follow-up item, not part of the nginx deploy itself.

## 10. Verification

- `nginx -t` before every reload (enforced inside `deploy.sh`).
- `curl -I http://meno.nsu.ru` → `301`.
- `curl -skI https://meno.nsu.ru` → `200` + valid certificate chain.
- **External HTTPS reachability:** `curl https://meno.nsu.ru` from outside the NSU
  network — connects (confirms `:443` open) vs times out (REJECT firewall → NSU
  ticket). This is the definitive resolution of the §3 residual edge case.
- **SSE smoke test:** a streaming request to `/v1/...` arrives in chunks, not as one
  buffered blob (proves `proxy_buffering off` is effective).
- TLS grade sanity: `openssl s_client -connect meno.nsu.ru:443 -servername meno.nsu.ru`.

## 11. Out of scope (documented in runbook, not built now)

- Application process management (`run_backend.sh`, pm2) — stays in the app repos.
- Containerization (docker-compose) — apps run natively under systemd/pm2.
- **Variant B** (nginx serves the SPA build directly + proxies `/v1` to `:9006`) —
  load-target optimization, reachable by swapping the vhost.
- `limit_req` rate-limiting; CI that runs `nginx -t` in a container — optional, later.
- HSTS hardening — added in a second pass after HTTPS is confirmed (§6).

## 12. Risks & open items

- **443 REJECT edge case** (low) — resolved by the external `curl` in §10 right
  after deploy.
- **Let's Encrypt renewal silently failing** if the network posture changes later —
  mitigated by `certbot renew --dry-run` in the runbook and the deploy-hook reload.
- **`:9012` exposure** until the Meno-Web bind fix lands — tracked as a follow-up
  (§9).
