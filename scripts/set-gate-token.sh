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
echo "Next: restore the auth_basic directives in nginx/meno.nsu.ru.conf, then"
echo "      sudo ./scripts/deploy.sh   (re-applies the gated vhost)"
