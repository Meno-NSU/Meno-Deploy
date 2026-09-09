#!/usr/bin/env bash
# Create or rotate the benchmark endpoint's secret token.
#
#   sudo ./scripts/set-bench-token.sh            # first time (refuses if set)
#   sudo ./scripts/set-bench-token.sh --rotate   # replace an existing token
#
# Writes an nginx `map` that gates /bench/v1/, and prints the token ONCE.
#
# Unlike the old access gate, the token is stored in CLEAR TEXT: nginx `map`
# can only compare literals, it cannot verify a hash. The file is root-owned
# and 0600, and the same token also sits in clear text in the backend's .env
# (the backend has to compare it too), so the trust boundary is the host's
# root account either way.
set -euo pipefail

MAP_FILE=/etc/nginx/conf.d/meno-bench-token.conf
# $HOME is /root under sudo, so it would point the operator at a .env the
# backend never reads. Resolve the INVOKING user's home instead, and fall back
# to $HOME only when the script is somehow not run through sudo.
_invoking_home="$(getent passwd "${SUDO_USER:-$(id -un)}" 2>/dev/null | cut -d: -f6)"
BACKEND_DIR="${BACKEND_DIR:-${_invoking_home:-$HOME}/Meno-Stand/Meno-Stand-RAG-Core}"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/set-bench-token.sh" >&2
    exit 1
fi

# A configured file is one with an actual token line. Anchored on purpose: a
# loose grep for "Bearer" would also match a comment someone adds to the
# placeholder, and then a first run would refuse for no reason.
if grep -qE '^\s*"~\^\[Bb\]earer ' "$MAP_FILE" 2>/dev/null && [[ "${1:-}" != "--rotate" ]]; then
    echo "$MAP_FILE already carries a token. Re-run with --rotate to replace it." >&2
    exit 1
fi

TOKEN="$(openssl rand -hex 32)"

# Keep a copy so a failed `nginx -t` can be rolled back. Without this, a bad
# write leaves the host with a map nginx refuses to load — which blocks every
# later deploy of the PUBLIC site, not just the benchmark endpoint.
BACKUP="$(mktemp)"
trap 'rm -f "$BACKUP" "$MAP_FILE.new"' EXIT
[[ -f "$MAP_FILE" ]] && cp -p "$MAP_FILE" "$BACKUP"

# Write to a temp file and mv into place: `cat > $MAP_FILE` truncates first, so
# an interrupted write would leave a file that exists but defines nothing.
umask 077
cat > "$MAP_FILE.new" <<EOF
# Benchmark endpoint token map — GENERATED, DO NOT EDIT BY HAND.
# Written by scripts/set-bench-token.sh. Rotate with --rotate.
#
# A regex, not a plain string: nginx map matches STRINGS CASE-INSENSITIVELY,
# so a plain "Bearer $TOKEN" entry would also admit an upper-cased token. The
# backend compares with hmac.compare_digest and would then reject it — serving
# the request as an ordinary one, with no trace and every benchmark question
# written to the production tables. \`~\` makes the match case-sensitive;
# [Bb]earer keeps the two spellings a client might send.
map \$http_authorization \$bench_ok {
    default                     0;
    "~^[Bb]earer $TOKEN\$"      1;
}
EOF
chown root:root "$MAP_FILE.new"
chmod 600 "$MAP_FILE.new"
mv "$MAP_FILE.new" "$MAP_FILE"

if ! nginx -t; then
    echo "[set-bench-token] nginx -t FAILED — restoring the previous map" >&2
    if [[ -s "$BACKUP" ]]; then
        cp -p "$BACKUP" "$MAP_FILE"
    else
        rm -f "$MAP_FILE"
    fi
    exit 1
fi
systemctl reload nginx

echo "[set-bench-token] wrote $MAP_FILE and reloaded nginx"
echo
echo "  ===== BENCHMARK TOKEN (shown once) ====="
echo "  $TOKEN"
echo "  ========================================"
echo
echo "The backend must carry the SAME token or it will answer as an ordinary"
echo "request — no trace, and every question written to the production tables."
echo
echo "  1. add to $BACKEND_DIR/.env:"
echo "       BENCH_API_TOKEN=$TOKEN"
echo "  2. cd $BACKEND_DIR && ./scripts/run_backend.sh restart"
echo

# Close the loop instead of only documenting it: nginx now admits bench traffic,
# and until the backend carries the same token that traffic is persisted to the
# production tables. Detect that here rather than leaving it to discipline.
if curl -fsS -o /dev/null -D- --max-time 10 \
        -H "Authorization: Bearer $TOKEN" \
        http://127.0.0.1:9006/v1/models 2>/dev/null \
        | grep -qi '^x-bench-mode: 1'; then
    echo "[set-bench-token] backend already carries this token — bench mode is live."
else
    echo "!! WARNING: the backend does NOT yet recognise this token."
    echo "!! Until you finish steps 1-2, /bench/ requests are served as ORDINARY"
    echo "!! production requests and every question is written to the database."
fi
