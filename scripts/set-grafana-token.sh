#!/usr/bin/env bash
# Create or rotate the Basic Auth credential for /grafana/.
#
#   sudo ./scripts/set-grafana-token.sh            # first time (refuses if set)
#   sudo ./scripts/set-grafana-token.sh --rotate   # replace it
#
# This is only the OUTER gate. Grafana still asks for its own login.
#
# Note the file mode differs from the benchmark token map: nginx WORKERS read
# an htpasswd on every request, so it must be readable by www-data. A `map` is
# compiled into the config at load time by the master process, so that one
# stays root-only.
#
# bcrypt (-B) on purpose. Note it cannot be exercised on macOS: nginx verifies
# Basic Auth through the system crypt(), and macOS's does not implement $2y$,
# so a local test rig will 401 on a correct password. glibc does implement it,
# and the pilot gate proved bcrypt works on this production host. Do NOT
# "fix" a failing local test by downgrading to -m (apr1/MD5).
#
# Requires: htpasswd + openssl  (sudo apt-get install -y apache2-utils openssl).
set -euo pipefail

GRAFANA_GATE_USER="${GRAFANA_GATE_USER:-meno-monitoring}"
HTPASSWD=/etc/nginx/.meno_grafana_htpasswd

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/set-grafana-token.sh" >&2
    exit 1
fi

# The placeholder deploy.sh installs has `*` as the password field; that is not
# a configured credential and must not block a first run.
if grep -qv ':\*$' "$HTPASSWD" 2>/dev/null && [[ "${1:-}" != "--rotate" ]]; then
    echo "$HTPASSWD already carries a credential. Re-run with --rotate to replace it." >&2
    exit 1
fi

TOKEN="$(openssl rand -base64 32)"

# -B bcrypt, -c (re)create, -i read from stdin so the secret never enters argv.
printf '%s' "$TOKEN" | htpasswd -B -c -i "$HTPASSWD" "$GRAFANA_GATE_USER"
chown root:www-data "$HTPASSWD"
chmod 640 "$HTPASSWD"

# Print BEFORE reloading. The token is shown once and only once; if an
# unrelated pre-existing config error made `nginx -t` fail here, `set -e` would
# abort with the credential already written and never displayed — and the guard
# above would then refuse a plain re-run.
echo "[set-grafana-token] wrote $HTPASSWD for user '$GRAFANA_GATE_USER'"
echo
echo "  ===== GRAFANA ACCESS (shown once) ====="
echo "  url:   https://meno.nsu.ru/grafana/"
echo "  user:  $GRAFANA_GATE_USER"
echo "  token: $TOKEN"
echo "  ======================================="
echo
echo "This is the OUTER gate only — Grafana asks for its own login after it."
echo

nginx -t
systemctl reload nginx
echo "[set-grafana-token] nginx reloaded"
