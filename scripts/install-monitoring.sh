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

# Fail on the first line rather than halfway through. envsubst (gettext-base)
# and gpg (gnupg) are routinely absent on a minimal server install, and hitting
# that after Prometheus is already unpacked leaves a half-built stack.
MISSING=()
declare -A PKG=(
    [envsubst]=gettext-base [curl]=curl
    [ss]=iproute2 [psql]=postgresql-client [tar]=tar
)
for cmd in "${!PKG[@]}"; do
    command -v "$cmd" &>/dev/null || MISSING+=("${PKG[$cmd]}")
done
if (( ${#MISSING[@]} )); then
    echo "Missing required commands. Install them first:" >&2
    printf '  sudo apt-get install -y %s\n' "$(printf '%s ' "${MISSING[@]}" | xargs -n99 echo)" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/install-monitoring.sh" >&2
    exit 1
fi

# Pinned, not "latest": a deploy must be reproducible. Check these against the
# current releases and bump deliberately.
PROM_VERSION="2.53.2"
NODE_EXPORTER_VERSION="1.8.2"
GRAFANA_VERSION="11.6.1"
case "$(uname -m)" in
    x86_64)  ARCH="linux-amd64" ;;
    aarch64) ARCH="linux-arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

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

# Validate the REPO copies before installing anything. Validating after the
# install would mean an invalid rules file has already replaced a working one
# by the time the script aborts — and Prometheus would load it on next restart.
promtool check rules "$REPO_DIR/monitoring/prometheus-rules.yml"

# Never clobber a config edited on the host: the README tells the operator to
# tune the alert thresholds, so re-running must not silently discard that.
install_unless_edited() {  # $1 = repo source, $2 = installed path
    if [[ -f "$2" ]] && ! cmp -s "$1" "$2"; then
        echo "[install] $2 differs from the repo copy — leaving it alone."
        echo "[install]   to adopt the repo version: rm it and re-run."
        return 0
    fi
    install -m 0644 "$1" "$2"
}
install_unless_edited "$REPO_DIR/monitoring/prometheus.yml"       /etc/prometheus/prometheus.yml
install_unless_edited "$REPO_DIR/monitoring/prometheus-rules.yml" /etc/prometheus/rules.yml
promtool check config /etc/prometheus/prometheus.yml

# ── node_exporter ─────────────────────────────────────────────────────────
install_user node_exporter
fetch_and_verify node_exporter "$NODE_EXPORTER_VERSION" \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"
install -m 0755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" \
    /usr/local/bin/node_exporter

# ── Grafana ───────────────────────────────────────────────────────────────
# Direct .deb, NOT the apt repo. apt.grafana.com and packages.grafana.com both
# answer 403 from this host's network ("Sorry, the provided token is not valid"
# — Grafana's own infrastructure, not a local block page), while
# dl.grafana.com serves the package normally. Measured on the production host
# 2026-09-09. The apt route would also have meant a signing key this machine
# cannot fetch, so there is nothing to fall back to.
#
# Trade-off worth stating: no apt repo means `apt upgrade` will not update
# Grafana. Bumping GRAFANA_VERSION here and re-running is the upgrade path.
if ! dpkg -s grafana &>/dev/null || \
   [[ "$(dpkg-query -W -f='${Version}' grafana 2>/dev/null)" != "$GRAFANA_VERSION" ]]; then
    echo "[install] installing Grafana $GRAFANA_VERSION from dl.grafana.com"
    deb="grafana_${GRAFANA_VERSION}_amd64.deb"
    base="https://dl.grafana.com/oss/release"
    curl -fsSL -o "$TMP/$deb"          "$base/$deb"
    curl -fsSL -o "$TMP/$deb.sha256"   "$base/$deb.sha256"
    # The .sha256 file holds the bare digest, so pair it with the filename
    # ourselves before handing it to sha256sum -c.
    ( cd "$TMP" && echo "$(cat "$deb.sha256")  $deb" | sha256sum -c - )
    # Grafana needs adduser/libfontconfig1/musl; -f resolves them from the
    # distro repos, which are reachable.
    dpkg -i "$TMP/$deb" || apt-get install -y -f
fi

# A plain "differs from the repo copy? leave it alone" guard is WRONG here,
# unlike for prometheus.yml: the .deb ships its own /etc/grafana/grafana.ini,
# which of course differs — so on a first install the guard would skip our
# config entirely and Grafana would come up on its default bind address,
# meaning ALL interfaces, on a host whose upstream firewall is permissive.
#
# Track what WE last wrote instead. Untouched since our last install → safe
# to update. Changed → a human edited it, leave it alone.
GRAFANA_INI=/etc/grafana/grafana.ini
GRAFANA_MARKER=/etc/grafana/.meno-grafana-ini.sha256
if [[ -f "$GRAFANA_MARKER" ]] \
   && ! sha256sum -c --status "$GRAFANA_MARKER" 2>/dev/null; then
    echo "[install] $GRAFANA_INI was edited by hand since our last install — leaving it alone."
    echo "[install]   to adopt the repo version: rm $GRAFANA_MARKER and re-run."
else
    install -m 0640 -o root -g grafana "$REPO_DIR/monitoring/grafana.ini" "$GRAFANA_INI"
    sha256sum "$GRAFANA_INI" > "$GRAFANA_MARKER"
    chmod 600 "$GRAFANA_MARKER"
fi
install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards \
           /var/lib/grafana/dashboards

# The datasource file carries the DB password, so render it from .env rather
# than committing it, and keep it unreadable by anyone but grafana.
DS_FILE=/etc/grafana/provisioning/datasources/meno.yml
# Create with the final mode BEFORE writing the secret: a `>` redirect would
# create it with the shell's umask (world-readable), and an interruption
# between the redirect and a later chmod would leave it that way permanently.
install -m 0640 -o root -g grafana /dev/null "$DS_FILE"
# shellcheck disable=SC2016  # envsubst takes the LITERAL variable name as its
# allow-list; expanding it here would substitute every variable in the file.
GRAFANA_DB_PASSWORD="$GRAFANA_DB_PASSWORD" envsubst '$GRAFANA_DB_PASSWORD' \
    < "$REPO_DIR/monitoring/grafana/provisioning/datasources/meno.yml" \
    > "$DS_FILE"

install -m 0644 "$REPO_DIR/monitoring/grafana/provisioning/dashboards/meno.yml" \
    /etc/grafana/provisioning/dashboards/meno.yml
if compgen -G "$REPO_DIR/monitoring/grafana/dashboards/*.json" > /dev/null; then
    install -m 0644 -o grafana -g grafana \
        "$REPO_DIR"/monitoring/grafana/dashboards/*.json /var/lib/grafana/dashboards/
else
    echo "[install] no dashboard JSON yet — build them in the UI and export (see the plan)."
fi

# ── Database: views, role, password ───────────────────────────────────────
# Grafana interpolates $VAR in provisioning files from its own environment, so
# a $ in the password would be silently eaten there and the datasource would
# fail at query time — invisibly, since our own psql checks would still pass.
# Restrict the alphabet rather than debug that later. `openssl rand -base64 24`
# (what .env.example recommends) always satisfies this.
if [[ ! "$GRAFANA_DB_PASSWORD" =~ ^[A-Za-z0-9+/=_.-]+$ ]]; then
    echo "GRAFANA_DB_PASSWORD contains characters that Grafana provisioning or SQL" >&2
    echo "quoting handle badly. Use: openssl rand -base64 24" >&2
    exit 1
fi

# ON_ERROR_STOP is not optional here: without it psql exits 0 on a SQL error,
# so `set -e` never sees a failed migration and the script marches on.
echo "[install] applying usage views and the Grafana role"
# Redirect, not -f: with -f the file is opened by the postgres user, which
# cannot traverse the operator's home directory. The redirect is performed by
# root before privileges drop, so postgres only ever receives the contents.
# shellcheck disable=SC2024  # "sudo doesn't affect redirects" is the POINT:
# root opens the file, postgres only receives the bytes on stdin.
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d meno_rag \
    < "$REPO_DIR/monitoring/sql/usage_view.sql"

# Double any single quote so a password containing one cannot close the literal
# (or inject SQL). Quote both halves of the substitution: the backslash form
# `${VAR//\'/\'\'}` produces \'\' — a backslash-escape, NOT a doubled quote —
# which closes the literal and hands the remainder to psql as commands.
# Piped over stdin, never argv: a password on a command line is visible in ps.
ESCAPED_PW=${GRAFANA_DB_PASSWORD//"'"/"''"}
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d meno_rag <<SQL
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
#
# An ALLOW-list, not a deny-list. A deny-list ("is it 0.0.0.0 or * or [::]?")
# reports a clean "ok" for a service bound to the host's PUBLIC IP, and for a
# service that is not listening at all — the two answers you least want to be
# optimistic about.
echo
echo "[install] verifying every listener is loopback-only"
# Grafana is the slow starter; give it room before concluding anything.
for _ in $(seq 30); do
    ss -tlnH 2>/dev/null | grep -q ':3000$\|:3000 ' && break
    sleep 1
done
LEAKED=0
for port in 9090 9100 3000; do
    addrs="$(ss -tlnH 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $4}')"
    if [[ -z "$addrs" ]]; then
        echo "  !! ${port} is NOT LISTENING — the service failed to start" >&2
        LEAKED=1
        continue
    fi
    bad="$(grep -vE '^(127\.0\.0\.1|\[::1\]):' <<<"$addrs" || true)"
    if [[ -n "$bad" ]]; then
        echo "  !! ${port} bound to ${bad//$'\n'/, } — NOT loopback" >&2
        LEAKED=1
    else
        echo "  ok  ${port} loopback only"
    fi
done
if [[ $LEAKED -ne 0 ]]; then
    # Refusing to report success is not the same as removing the exposure. On a
    # host with a permissive upstream firewall the port stays on the internet
    # until a human reads this output, so stop the services first.
    echo >&2
    echo "[install] stopping the monitoring services to remove any exposure" >&2
    systemctl stop prometheus node_exporter grafana-server || true
    echo "REFUSING TO REPORT SUCCESS. Fix the bind addresses and re-run." >&2
    exit 1
fi

# Prove the content boundary rather than asserting it: a new PostgreSQL role
# gets no table grants by default, but "we did not grant it" is not the same as
# "it cannot read it", and the README claims the role reads the usage views
# "and nothing else". Enumerate what it can actually read and assert on that —
# this is the artifact to hand InfoSec.
echo
echo "[install] verifying what the Grafana role can read"
READABLE="$(sudo -u postgres psql -tAq -v ON_ERROR_STOP=1 -d meno_rag -c "
    SELECT string_agg(c.relname, ',' ORDER BY c.relname)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r','v','m','p')
      AND has_table_privilege('meno_grafana', c.oid, 'SELECT');")"
if [[ "$READABLE" != "usage_conversations,usage_messages" ]]; then
    echo "  !! meno_grafana can read: ${READABLE:-<nothing>}" >&2
    echo "  !! expected exactly: usage_conversations,usage_messages" >&2
    exit 1
fi
echo "  ok  readable relations are exactly the two content-free views"

# Positive control. Without it the negative test above is unsound: a role that
# simply cannot log in would also "pass" a can't-read-content check.
if ! PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h 127.0.0.1 -U meno_grafana -d meno_rag \
        -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM usage_conversations;' &>/dev/null; then
    echo "  !! meno_grafana cannot log in or read the views — dashboards will be empty." >&2
    echo "  !! Check pg_hba.conf has a host line for 127.0.0.1 with scram-sha-256 or md5." >&2
    exit 1
fi
echo "  ok  the role can log in and read the views"

echo
echo "[install] done. Next:"
echo "  1. sudo ./scripts/set-grafana-token.sh   (Basic Auth for /grafana/)"
echo "  2. sudo ./scripts/deploy.sh              (publish the /grafana/ location)"
echo "  3. open https://meno.nsu.ru/grafana/ and build the dashboards"
