# Meno-Deploy Access Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the entire `meno.nsu.ru` site behind a single shared access token (nginx HTTP Basic Auth) so only the dev/test group can reach it — a closed pilot, not a public launch.

**Architecture:** Add `auth_basic` to the whole `:443` server block (checked before `proxy_pass`); a script creates the bcrypt token file; `deploy.sh` refuses to install the gated vhost without it (fail-closed); the Express upstream is bound to `127.0.0.1` so the gate cannot be bypassed via the raw port.

**Tech Stack:** nginx 1.24.0 (Ubuntu 24.04), `auth_basic`, `htpasswd -B` (apache2-utils), openssl, Bash; Meno-Web (Node/Express) for the bind change.

**Note on "tests":** infra/config repo — verification analogs are `bash -n` + `shellcheck` for scripts, `nginx -t` (authoritative on-server in Task 6), and live `curl`/no-bypass checks. Full design: `docs/superpowers/specs/2026-06-17-meno-deploy-design.md` (§9, §13, §14).

**Prereq context:** Base deploy artifacts (`2026-06-17-meno-deploy.md`, Tasks 1–6) are committed on `main`. This plan is being implemented on branch `feat/access-gate` (the updated spec is already committed there). It **supersedes** the base plan's Tasks 8–9 (server rollout / Meno-Web bind) with the gated sequence in Task 6.

---

## File Structure

| File | Change |
|---|---|
| `scripts/set-gate-token.sh` | **Create** — generate token, write bcrypt htpasswd, print token once, `--rotate` |
| `nginx/meno.nsu.ru.conf` | **Modify** — add `auth_basic` to the `:443` server block |
| `scripts/deploy.sh` | **Modify** — fail-closed: refuse the gated vhost if the htpasswd file is missing |
| `.gitignore` | **Modify** — never commit a stray local htpasswd |
| `README.md` | **Modify** — gate runbook (set/rotate token, what testers do, no-bypass checks); rollout order |
| `server.js` (Meno-Web repo) | **Modify** — bind to `127.0.0.1` (mandatory) |
| `example.env` (Meno-Web repo) | **Modify** — document `HOST` |

The token file `/etc/nginx/.meno_htpasswd` lives only on the server — never in the repo.

---

## Task 1: `scripts/set-gate-token.sh`

**Files:**
- Create: `scripts/set-gate-token.sh`

- [ ] **Step 1: Create `scripts/set-gate-token.sh`**

```bash
#!/usr/bin/env bash
# Create or rotate the shared access token for the meno.nsu.ru gate.
# Writes a bcrypt htpasswd file that nginx (auth_basic) checks, and prints the
# plaintext token ONCE for out-of-band distribution. Plaintext is never stored.
#
#   sudo ./scripts/set-gate-token.sh            # first time (refuses if file exists)
#   sudo ./scripts/set-gate-token.sh --rotate   # replace an existing token
#
# Requires: htpasswd + openssl  (sudo apt-get install -y apache2-utils openssl).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
    set +a
fi

GATE_USER="${GATE_USER:-menon}"
HTPASSWD=/etc/nginx/.meno_htpasswd

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/set-gate-token.sh" >&2
    exit 1
fi

if [[ -f "$HTPASSWD" && "${1:-}" != "--rotate" ]]; then
    echo "$HTPASSWD already exists. Re-run with --rotate to replace the token." >&2
    exit 1
fi

TOKEN="$(openssl rand -base64 32)"

# -B bcrypt, -c (re)create the file, -i read the password from stdin
# (so the token never appears in argv / the process list).
printf '%s' "$TOKEN" | htpasswd -B -c -i "$HTPASSWD" "$GATE_USER"
chown root:www-data "$HTPASSWD"
chmod 640 "$HTPASSWD"

echo "[set-gate-token] wrote $HTPASSWD for user '$GATE_USER'"
echo
echo "  ===== SHARE WITH THE TEST GROUP (shown once) ====="
echo "  user:  $GATE_USER"
echo "  token: $TOKEN"
echo "  =================================================="
echo
echo "Next: sudo ./scripts/deploy.sh   (applies the gated vhost)"
```

- [ ] **Step 2: Make executable and check syntax**

Run: `chmod +x scripts/set-gate-token.sh && bash -n scripts/set-gate-token.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Lint with shellcheck**

Run: `shellcheck scripts/set-gate-token.sh && echo LINT_OK`
Expected: `LINT_OK` (no findings).

- [ ] **Step 4: Commit**

```bash
git add scripts/set-gate-token.sh
git commit -m "feat(scripts): add set-gate-token.sh (shared-token bcrypt htpasswd)"
```

---

## Task 2: Add `auth_basic` to the production vhost

**Files:**
- Modify: `nginx/meno.nsu.ru.conf` (the `:443` server block)
- Modify: `.gitignore`

- [ ] **Step 1: Insert the gate into the `:443` block**

In `nginx/meno.nsu.ru.conf`, find this line in the **HTTPS** server block:

```nginx
    ssl_session_timeout 1d;
```

Insert immediately **after** it:

```nginx

    # ── Closed-pilot access gate ──────────────────────────────────────────
    # Shared-token HTTP Basic Auth on the WHOLE server block — checked before
    # any proxy_pass, inherited by every location below. The site is NOT public
    # until InfoSec sign-off. Token file is created by scripts/set-gate-token.sh
    # and never committed. The :80 block stays auth-free (redirect + ACME only),
    # so the token only ever travels over TLS and cert renewal keeps working.
    auth_basic           "Menon — restricted";
    auth_basic_user_file /etc/nginx/.meno_htpasswd;
```

- [ ] **Step 2: Guard against committing a stray htpasswd**

Append to `.gitignore`:

```gitignore

# Never commit an access-token file (the real one lives at /etc/nginx/.meno_htpasswd)
*.htpasswd
.meno_htpasswd
```

- [ ] **Step 3: Verify the edits**

Run: `grep -q 'auth_basic_user_file /etc/nginx/.meno_htpasswd;' nginx/meno.nsu.ru.conf && grep -q 'auth_basic ' nginx/meno.nsu.ru.conf && grep -q '.meno_htpasswd' .gitignore && echo OK`
Expected: `OK`. (auth_basic sits at server scope, before the `location` blocks, so it covers `/` and `/v1/`. Authoritative `nginx -t` runs on the server in Task 6.)

- [ ] **Step 4: Commit**

```bash
git add nginx/meno.nsu.ru.conf .gitignore
git commit -m "feat(nginx): gate the :443 vhost behind shared-token Basic Auth"
```

---

## Task 3: Make `deploy.sh` fail-closed on a missing token

**Files:**
- Modify: `scripts/deploy.sh`

- [ ] **Step 1: Add an htpasswd precondition before installing the production vhost**

In `scripts/deploy.sh`, find:

```bash
# 3. Install the production vhost (overwrites the bootstrap site of the same name).
echo "[deploy] installing production vhost"
```

Replace those two lines with:

```bash
# Fail-closed: never install the gated vhost without its token file. (nginx -t
# would also fail on a missing auth_basic_user_file; this gives a clear message.)
if [[ ! -f /etc/nginx/.meno_htpasswd ]]; then
    echo "[deploy] ERROR: gate token /etc/nginx/.meno_htpasswd is missing." >&2
    echo "         Create it first:  sudo ./scripts/set-gate-token.sh" >&2
    exit 1
fi

# 3. Install the production vhost (overwrites the bootstrap site of the same name).
echo "[deploy] installing production vhost"
```

- [ ] **Step 2: Check syntax**

Run: `bash -n scripts/deploy.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 3: Lint with shellcheck**

Run: `shellcheck scripts/deploy.sh && echo LINT_OK`
Expected: `LINT_OK` (no findings).

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy.sh
git commit -m "feat(scripts): deploy.sh fails closed when the gate token is absent"
```

---

## Task 4: README — gate runbook and rollout order

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the gate section**

In `README.md`, find the heading:

```markdown
## Security follow-up: lock down `:9012`
```

Insert this **before** it:

````markdown
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
````

- [ ] **Step 2: Replace the rollout/`:9012` section with the mandatory-first ordering**

In `README.md`, replace this whole block:

```markdown
## Security follow-up: lock down `:9012`

The Meno-Web Express server currently binds `0.0.0.0:9012`, i.e. it is reachable
directly from the internet, bypassing TLS. Fix it in the **Meno-Web** repo by
binding to `127.0.0.1` (one-line change in `server.js`, default host). nginx
proxies to `127.0.0.1:9012` so this is transparent to users.
```

with:

````markdown
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
````

- [ ] **Step 3: Verify the runbook entries**

Run: `for s in "Access gate" "set-gate-token.sh --rotate" "Rollout order" "expect 401" "Order matters"; do grep -q "$s" README.md || echo "MISSING: $s"; done; echo DONE`
Expected: `DONE` with no `MISSING:` lines.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add access-gate runbook and mandatory-first rollout order"
```

---

## Task 5: Bind Meno-Web Express to `127.0.0.1` (repo: Meno-Web)

Lands in the **Meno-Web** repo (`~/PycharmProjects/Meno-Web` locally), its own commit/branch. Mandatory — it closes the bypass.

**Files:**
- Modify: `server.js`
- Modify: `example.env`

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

- [ ] **Step 2: Document `HOST` in `example.env`**

Append to Meno-Web's `example.env`:

```bash
# Interface the web server binds to. Default 127.0.0.1 so the app is only
# reachable via the nginx TLS+token proxy. Set 0.0.0.0 only for direct local dev.
HOST=127.0.0.1
```

- [ ] **Step 3: Verify it starts and binds locally only**

Run (in Meno-Web): `npm run build && (node server.js & sleep 2 ; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9012/ ; kill %1)`
Expected: `200`, and the startup log shows `http://127.0.0.1:9012`.

- [ ] **Step 4: Commit (in the Meno-Web repo)**

```bash
git add server.js example.env
git commit -m "fix(server): bind to 127.0.0.1 by default (serve only via nginx gate)"
```

---

## Task 6: Publish and roll out on the server (operational)

After the gate code is merged to `main` and pushed (handled by the finishing step), perform the rollout **on the server** (`m.kulakov@meno`) in the safe order — **gate up and verified first, then close the direct port** (`:9012` is the current live access path, so closing it earlier would cut access). This is the live, end-to-end verification.

- [ ] **Step 1: Get Meno-Deploy onto the server**

```bash
cd ~/Meno-Stand && git clone https://github.com/Meno-NSU/Meno-Deploy.git 2>/dev/null || (cd Meno-Deploy && git pull)
cd ~/Meno-Stand/Meno-Deploy && cp -n .env.example .env   # then edit .env: real LETSENCRYPT_EMAIL
```

- [ ] **Step 2: Install dependencies (certbot + htpasswd)**

Run: `command -v certbot >/dev/null && command -v htpasswd >/dev/null && echo OK || sudo apt-get update && sudo apt-get install -y certbot apache2-utils`
Expected: tools present (or installed).

- [ ] **Step 3: Create the shared token**

Run: `sudo ./scripts/set-gate-token.sh`
Expected: prints `user: menon` and a `token:` line **once** — copy it for the group. Writes `/etc/nginx/.meno_htpasswd`.

- [ ] **Step 4: Deploy the gated vhost**

Run: `sudo ./scripts/deploy.sh`
Expected: bootstrap → cert issued (over `:80`, `:9012` undisturbed) → production vhost installed → `nginx -t` `syntax is ok` / `test is successful` → reload. Ends with `[deploy] done`. `meno.nsu.ru` is now gated-serving; `:9012` is still open (expected at this point).

- [ ] **Step 5: Verify the gated path works (before closing anything)**

```bash
curl -skI https://meno.nsu.ru                         # expect 401
curl -skI -u "menon:THE_TOKEN" https://meno.nsu.ru    # expect 200
curl -I http://meno.nsu.ru/.well-known/acme-challenge/probe  # expect 404 (NOT 401)
sudo certbot renew --dry-run                          # expect success
```
Expected: unauthenticated = `401`; correct token = `200`; ACME open; renewal dry-run passes. Confirm testers can reach the app via the token **before** cutting `:9012`.

- [ ] **Step 6: Now close the direct port (Meno-Web bind change)**

```bash
cd ~/Meno-Stand/Meno-Web && git pull && npm install && npm run build && pm2 restart meno-web
ss -tlnp | grep ':9012'     # expect 127.0.0.1:9012 (NOT 0.0.0.0:9012)
```
Expected: `:9012` now bound to `127.0.0.1`. The direct corporate path is closed; the only way in is the gated `meno.nsu.ru`.

- [ ] **Step 7: Final no-bypass verification**

On the server: `ss -tlnp | grep -E ':(9012|9006)'` → expect `127.0.0.1` only.
From **outside** the NSU network:
```bash
nc -vz -w5 84.237.50.35 9012   # expect refused/timeout (not "succeeded")
nc -vz -w5 84.237.50.35 9006   # expect refused/timeout
curl -skI https://meno.nsu.ru                       # expect 401
curl -skI -u "menon:THE_TOKEN" https://meno.nsu.ru  # expect 200
```
Expected: raw app ports unreachable from the internet; the gated path still works with the token.

---

## Done when

- `https://meno.nsu.ru` returns `401` without the token and serves the SPA **only** with `-u menon:<token>`, from inside and outside the NSU network.
- `meno.nsu.ru:9012` and `:9006` are unreachable from the internet (`127.0.0.1` only).
- ACME path is un-gated and `certbot renew --dry-run` succeeds.
- A missing token file makes `deploy.sh` refuse and `nginx -t` fail (fail-closed) — never an un-gated site.
- Gate code merged to `main` and pushed; Meno-Web bind change committed.
