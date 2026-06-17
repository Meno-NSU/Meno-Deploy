# Meno-Deploy — Design

**Date:** 2026-06-17
**Status:** Approved (design phase)
**Repo:** https://github.com/Meno-NSU/Meno-Deploy

## 1. Purpose & scope

`Meno-Deploy` is the infrastructure-as-code repository that exposes the **Meno-Web**
frontend at **`meno.nsu.ru`** (84.237.50.35) over HTTPS, **gated behind a shared
access token** so only the dev/test group can reach it. This is a **closed pilot,
not a public launch** — the system processes personal data and must not be publicly
reachable until the information-security team signs off (registration, session
storage, PD handling).

It owns exactly one concern: the **public edge** — an nginx reverse proxy that
terminates TLS, enforces the token gate, and forwards traffic to the already-running
Meno-Web Express server. It does **not** own application lifecycle (that stays with
the app repos' `run_backend.sh` / pm2).

**Goal:** a browser hitting `https://meno.nsu.ru` is challenged for the shared token;
only with it does the request reach the Meno-Web SPA and its `/v1/*` API (including
SSE chat streaming). Secure, reproducible, config tracked in git, and reversible.

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
│   ├── issue-cert.sh                  # certbot webroot issuance + reload deploy-hook
│   └── set-gate-token.sh              # generate shared token → bcrypt htpasswd (§13)
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

Express currently binds `0.0.0.0:9012` and is reachable directly from the internet
(confirmed: `http://84.237.50.35:9012` is open — it is the current corporate access
path), **bypassing both TLS and the token gate**. The token wall (§13) is only
meaningful once this is closed.

**Fix (mandatory):** bind Express to `127.0.0.1` — a one-line, revertable change in the
**Meno-Web** repo (`server.js`, default host). The backend `:9006` already binds
`127.0.0.1` (re-verified). `Meno-Deploy` ships no firewall tooling; loopback binding is
the clean primary control and avoids the SSH lock-out footgun.

**Timing:** because `:9012` is the *current* live access path and `meno.nsu.ru` is not
serving the app yet, close `:9012` **right after** the gated path is verified — not
before — to avoid cutting current access. The short overlap (both paths up) is no more
exposed than today. See the rollout order in §13.

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
- **`:9012` bypass** — closed as the mandatory first rollout step (§9, §13); the gate
  is only meaningful once Express is loopback-bound.
- **Shared-token leak** — one leaked token compromises all access; mitigated by
  rotation (`set-gate-token.sh --rotate`), the accepted trade-off of the single-token
  model.

## 13. Access gate — closed-pilot token wall

Restricts the entire site to holders of a single shared token, enforced at the nginx
edge in front of everything. Extends §6 (vhost) and §9 (loopback bind).

**Mechanism:** nginx HTTP Basic Auth (`auth_basic`) on the whole `:443` server block —
checked *before* `proxy_pass`, so an unauthenticated request never reaches the app.
Zero custom code, minimal attack surface.

**Token model:** a single shared credential for the dev/test group (user `menon` +
token). Chosen for simple distribution; the trade-off (leak → rotate for everyone, no
per-user audit) is accepted and noted in the runbook.

**nginx changes** — add to the `:443` server block of `meno.nsu.ru.conf` (§6):

```nginx
auth_basic           "Menon — restricted";
auth_basic_user_file /etc/nginx/.meno_htpasswd;
```

The `:80` block is unchanged: it only 301-redirects (and serves ACME), with **no**
auth — so the token is **only ever sent over TLS**, and Let's Encrypt renewal (HTTP-01
on `:80`) keeps working. `:443` never serves ACME, so no auth exception is needed there.

**Token management** — `scripts/set-gate-token.sh` (run under sudo):

- Generates a strong random token (`openssl rand -base64 32`), writes
  `/etc/nginx/.meno_htpasswd` via `htpasswd -B` (bcrypt), `chmod 640 root:www-data`,
  and **prints the token once** for out-of-band distribution.
- Overwriting an existing token requires `--rotate` (so `deploy.sh` never clobbers it).
- Only the bcrypt **hash** is stored on disk; the plaintext token is never written to
  the repo. `/etc/nginx/.meno_htpasswd` lives outside the repo; `.env` is git-ignored.

**Fail-closed by construction:**

- If the htpasswd file is missing, `nginx -t` fails on `auth_basic_user_file` →
  `deploy.sh` does not reload, and additionally refuses to install the gated vhost
  without it. There is no state in which the app is served un-gated.
- During first-time cert issuance the bootstrap vhost returns `404` for everything
  except ACME — the app is not exposed even in that window.

**Rollout order (safe — gate first, then close the port):**

1. `set-gate-token.sh` — create the token.
2. `deploy.sh` — install the gated vhost; `meno.nsu.ru` goes live (cert issued over
   `:80` without disrupting `:9012`).
3. Verify the gated path (401 without token, 200 with).
4. **Only then** bind Express to `127.0.0.1` + `pm2 restart meno-web` (§9) — closes the
   direct-`:9012` bypass. Doing this earlier would cut the current access path.

**No-bypass verification:**

- From outside: `nc -vz meno.nsu.ru 9012` and `:9006` → unreachable (loopback).
- `curl -skI https://meno.nsu.ru` (no creds) → **401**; with `-u menon:<token>` → **200**.
- `curl -I http://meno.nsu.ru/.well-known/acme-challenge/x` → **404, not 401** (path not
  gated) and `certbot renew --dry-run` succeeds.
- On host `ss -tlnp`: only nginx on `:80/:443` is public; `:9012`/`:9006` on `127.0.0.1`.

**Security / legal posture (technical controls only — not legal advice):**

- The gate makes the site non-public, so random internet users cannot reach the
  registration endpoint or any PD — supporting the "not public until ИБ sign-off" stance.
- Distribute the token over a secure channel; rotate on leak (`--rotate`).
- Rate-limiting (`limit_req`) is **not** in v1: a high-entropy token makes brute force
  infeasible, and `limit_req` risks throttling the SPA's burst of asset requests on first
  load. Documented as a tunable option (§11).
- Legal sign-off (152-ФЗ etc.) remains with the user / ИБ; this repo provides correct
  technical controls only.

## 14. Reversibility & rollback

The deploy mutates **only the nginx edge** (routing/TLS/auth). It does **not** touch the
application, backend, or database — no migrations, no data writes. Blast radius is the
edge layer.

| Action | Reversible? | How / how fast |
|---|---|---|
| Meno-Web bind → `127.0.0.1` + `pm2 restart` | Yes | revert the line + `pm2 restart` (seconds); no data touched |
| `apt install certbot` | Yes | `apt remove`, or leave it (harmless) |
| nginx snippets/vhost, drop `default`, reload | Yes | README rollback: restore `default`, remove meno vhost, reload (~5 s) |
| Let's Encrypt issuance | Mostly | files deletable (`certbot delete`); but a public CT-log record remains (below) |
| Token / htpasswd | Yes | delete the file or `set-gate-token.sh --rotate` |
| Application / database | Untouched | no migrations, no writes — system state unchanged |

**Kill switches (close access immediately):**

- `sudo systemctl stop nginx` → site instantly unreachable on `:80/:443`; since `:9012`
  is loopback by then, the app has no public path at all. Reverse with `systemctl start`.
- Rollback to the default vhost → back to the stock nginx page, app not exposed (~5 s).
- Close access while keeping the site up: `set-gate-token.sh --rotate` (or remove the
  htpasswd) + reload → everyone gets `401`.

**The one irreversible footprint:** issuing a cert from a public CA writes the hostname
to **Certificate Transparency** logs (e.g. crt.sh) — an immutable public record that
`meno.nsu.ru` has a certificate. But the hostname is already in **public DNS** (resolves
to `84.237.50.35`), so the host's existence is already discoverable, and the gate means
discovery ≠ access. If even this footprint is unwanted, use an NSU-issued or self-signed
cert (no public CT); likely unnecessary.

**Fail-safe:** any config error fails `nginx -t`, which blocks the reload and leaves the
previous working state. There is no failure mode that serves the app un-gated.
