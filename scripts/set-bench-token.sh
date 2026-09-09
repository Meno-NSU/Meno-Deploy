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

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/set-bench-token.sh" >&2
    exit 1
fi

# A configured file is one that actually carries a token; the placeholder that
# deploy.sh installs has only `default 0` and must not block a first run.
if grep -q 'Bearer' "$MAP_FILE" 2>/dev/null && [[ "${1:-}" != "--rotate" ]]; then
    echo "$MAP_FILE already carries a token. Re-run with --rotate to replace it." >&2
    exit 1
fi

TOKEN="$(openssl rand -hex 32)"

umask 077
cat > "$MAP_FILE" <<EOF
# Benchmark endpoint token map — GENERATED, DO NOT EDIT BY HAND.
# Written by scripts/set-bench-token.sh. Rotate with --rotate.
map \$http_authorization \$bench_ok {
    default            0;
    "Bearer $TOKEN"    1;
}
EOF
chown root:root "$MAP_FILE"
chmod 600 "$MAP_FILE"

nginx -t
systemctl reload nginx

echo "[set-bench-token] wrote $MAP_FILE and reloaded nginx"
echo
echo "  ===== BENCHMARK TOKEN (shown once) ====="
echo "  $TOKEN"
echo "  ========================================"
echo
echo "The backend must carry the SAME token or it will answer as an ordinary"
echo "request — no trace, and every question written to the production tables."
echo "On this host:"
echo
echo "  1. add to ~/Meno-Stand/Meno-Stand-RAG-Core/.env:"
echo "       BENCH_API_TOKEN=$TOKEN"
echo "  2. cd ~/Meno-Stand/Meno-Stand-RAG-Core && ./scripts/run_backend.sh restart"
echo
echo "Verify — the X-Bench-Mode header proves the token matched on BOTH sides:"
echo "  curl -si https://meno.nsu.ru/bench/v1/chat/completions \\"
echo "    -H \"Authorization: Bearer $TOKEN\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"meno-lite\",\"messages\":[{\"role\":\"user\",\"content\":\"тест\"}]}' | head -20"
