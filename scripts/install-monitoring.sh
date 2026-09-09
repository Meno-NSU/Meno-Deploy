#!/usr/bin/env bash
# Idempotent install of the Meno monitoring stack. Safe to re-run.
#
#   sudo ./scripts/install-monitoring.sh
#
# Prometheus + node_exporter from the official release tarballs, Grafana from
# the official apt repo. Every service binds loopback only; the script refuses
# to report success otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_DIR/.env"
    set +a
fi
: "${GRAFANA_DB_PASSWORD:?GRAFANA_DB_PASSWORD must be set in .env}"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/install-monitoring.sh" >&2
    exit 1
fi

# Pinned, not "latest": a deploy must be reproducible. Check these against the
# current releases and bump deliberately.
PROM_VERSION="2.53.2"
NODE_EXPORTER_VERSION="1.8.2"
ARCH="linux-amd64"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Verifies the tarball against the release's own sha256sums file. That catches
# corruption and truncated downloads; it does NOT protect against a compromised
# release, since both files come from the same origin. TLS to github is the
# trust anchor — worth knowing rather than assuming.
fetch_and_verify() {  # $1=name $2=version $3=url-base
    local name="$1" version="$2" base="$3"
    local tarball="${name}-${version}.${ARCH}.tar.gz"
    echo "[install] fetching $tarball"
    curl -fsSL -o "$TMP/$tarball" "$base/$tarball"
    curl -fsSL -o "$TMP/${name}-sha.txt" "$base/sha256sums.txt"
    ( cd "$TMP" && grep " ${tarball}\$" "${name}-sha.txt" | sha256sum -c - )
    tar -xzf "$TMP/$tarball" -C "$TMP"
}

install_user() {  # $1 = username
    id -u "$1" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$1"
}

# ── Prometheus ────────────────────────────────────────────────────────────
install_user prometheus
fetch_and_verify prometheus "$PROM_VERSION" \
    "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}"
install -m 0755 "$TMP/prometheus-${PROM_VERSION}.${ARCH}/prometheus" /usr/local/bin/prometheus
install -m 0755 "$TMP/prometheus-${PROM_VERSION}.${ARCH}/promtool"   /usr/local/bin/promtool

install -d -o prometheus -g prometheus /etc/prometheus /var/lib/prometheus

# Never clobber a config edited on the host: re-running the installer must not
# silently discard a hand-tuned scrape config or alert threshold.
if [[ -f /etc/prometheus/prometheus.yml ]] \
   && ! cmp -s "$REPO_DIR/monitoring/prometheus.yml" /etc/prometheus/prometheus.yml; then
    echo "[install] /etc/prometheus/prometheus.yml differs from the repo copy — leaving it alone."
    echo "[install] to adopt the repo version: rm it and re-run."
else
    install -m 0644 "$REPO_DIR/monitoring/prometheus.yml" /etc/prometheus/prometheus.yml
fi
install -m 0644 "$REPO_DIR/monitoring/prometheus-rules.yml" /etc/prometheus/rules.yml
promtool check config /etc/prometheus/prometheus.yml
promtool check rules  /etc/prometheus/rules.yml

# ── node_exporter ─────────────────────────────────────────────────────────
install_user node_exporter
fetch_and_verify node_exporter "$NODE_EXPORTER_VERSION" \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"
install -m 0755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" \
    /usr/local/bin/node_exporter

# ── Grafana ───────────────────────────────────────────────────────────────
if ! dpkg -s grafana &>/dev/null; then
    echo "[install] installing Grafana from the official apt repo"
    install -d /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    apt-get install -y grafana
fi

install -m 0640 -o root -g grafana "$REPO_DIR/monitoring/grafana.ini" /etc/grafana/grafana.ini
install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards \
           /var/lib/grafana/dashboards

# The datasource file carries the DB password, so render it from .env rather
# than committing it, and keep it unreadable by anyone but grafana.
# shellcheck disable=SC2016  # envsubst takes the LITERAL variable name as its
# allow-list; expanding it here would substitute every variable in the file.
GRAFANA_DB_PASSWORD="$GRAFANA_DB_PASSWORD" envsubst '$GRAFANA_DB_PASSWORD' \
    < "$REPO_DIR/monitoring/grafana/provisioning/datasources/meno.yml" \
    > /etc/grafana/provisioning/datasources/meno.yml
chown root:grafana /etc/grafana/provisioning/datasources/meno.yml
chmod 640 /etc/grafana/provisioning/datasources/meno.yml

install -m 0644 "$REPO_DIR/monitoring/grafana/provisioning/dashboards/meno.yml" \
    /etc/grafana/provisioning/dashboards/meno.yml
if compgen -G "$REPO_DIR/monitoring/grafana/dashboards/*.json" > /dev/null; then
    install -m 0644 -o grafana -g grafana \
        "$REPO_DIR"/monitoring/grafana/dashboards/*.json /var/lib/grafana/dashboards/
else
    echo "[install] no dashboard JSON yet — build them in the UI and export (see the plan)."
fi

# ── Database: views, role, password ───────────────────────────────────────
# Piped over stdin, never argv: a password on a command line is visible in ps
# to every user on the box.
echo "[install] applying usage views and the Grafana role"
sudo -u postgres psql -q -d meno_rag -f "$REPO_DIR/monitoring/sql/usage_view.sql"
# Double any single quote so a password containing one cannot break out of the
# literal (or inject SQL).
ESCAPED_PW="${GRAFANA_DB_PASSWORD//\'/\'\'}"
sudo -u postgres psql -q -d meno_rag <<SQL
ALTER ROLE meno_grafana WITH LOGIN PASSWORD '${ESCAPED_PW}';
SQL

# ── systemd ───────────────────────────────────────────────────────────────
install -m 0644 "$REPO_DIR/monitoring/systemd/prometheus.service"    /etc/systemd/system/
install -m 0644 "$REPO_DIR/monitoring/systemd/node_exporter.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now prometheus node_exporter grafana-server
systemctl restart prometheus node_exporter grafana-server

# ── The check that matters most ───────────────────────────────────────────
# On this host the upstream firewall is permissive: a service bound to 0.0.0.0
# is on the internet. That mistake previously exposed the vLLM engine on :9022.
echo
echo "[install] verifying every listener is loopback-only"
sleep 3
LEAKED=0
for port in 9090 9100 3000; do
    if ss -tln | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]):${port}\$"; then
        echo "  !! PORT ${port} IS BOUND TO ALL INTERFACES — exposed to the internet" >&2
        LEAKED=1
    else
        echo "  ok  ${port} loopback only"
    fi
done
if [[ $LEAKED -ne 0 ]]; then
    echo >&2
    echo "REFUSING TO REPORT SUCCESS. Fix the bind address and re-run." >&2
    exit 1
fi

# Prove the content boundary rather than asserting it: a new PostgreSQL role
# gets no table grants by default, but PUBLIC holds USAGE on schema public, so
# "we did not grant it" is not the same as "it cannot read it".
echo
echo "[install] verifying Grafana cannot read dialogue content"
if PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h 127.0.0.1 -U meno_grafana -d meno_rag \
        -c 'SELECT content FROM messages LIMIT 1;' &>/dev/null; then
    echo "  !! meno_grafana CAN read messages.content — the boundary is not in place" >&2
    exit 1
fi
echo "  ok  messages.content is denied"
if ! PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h 127.0.0.1 -U meno_grafana -d meno_rag \
        -c 'SELECT count(*) FROM usage_conversations;' &>/dev/null; then
    echo "  !! meno_grafana cannot read usage_conversations — dashboards will be empty" >&2
    exit 1
fi
echo "  ok  usage views are readable"

echo
echo "[install] done. Next:"
echo "  1. sudo ./scripts/set-grafana-token.sh   (Basic Auth for /grafana/)"
echo "  2. sudo ./scripts/deploy.sh              (publish the /grafana/ location)"
echo "  3. open https://meno.nsu.ru/grafana/ and build the dashboards"
