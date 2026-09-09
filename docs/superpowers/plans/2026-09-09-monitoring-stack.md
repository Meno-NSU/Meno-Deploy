# B2 — Мониторинг с ретенцией: Prometheus, node_exporter, Grafana

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** История нагрузки, латентности, ошибок и числа пользователей, переживающая рестарты бэкенда, с дашбордами и алертами.

**Architecture:** Prometheus на петле скрейпит уже написанный `/metrics` бэкенда и node_exporter. Grafana читает два источника: Prometheus (операционные ряды) и PostgreSQL через view без доступа к содержимому диалогов (продуктовые). Наружу торчит только `/grafana/` за `auth_basic`.

**Tech Stack:** Prometheus, node_exporter, Grafana, PostgreSQL, systemd, nginx.

**Спека:** `Meno-Stand-RAG-Core/docs/superpowers/specs/2026-09-09-bench-endpoint-and-monitoring-design.md`, Часть 3.

**Не зависит** от B1 и от bench вообще. Может выполняться параллельно.

---

## Что уже есть и не нужно писать

Prometheus-инструментирование бэкенда написано целиком в `Meno-Stand-RAG-Core/src/meno_rag/api/metrics.py` и отдаётся на `GET /metrics`:

`meno_chat_requests`, `meno_chat_request_seconds` (гистограмма → p50/p95/p99), `meno_chat_in_flight`, `meno_llm_calls`, `meno_llm_latency_seconds` (по этапам), `meno_errors` (по кодам), `meno_http_requests`, `meno_http_request_seconds`, `meno_http_in_flight`, `meno_admission_active/limit`, `meno_pipeline_trace`, `meno_bench_requests`.

Не хватает только сборщика с ретенцией. **Новых метрик не пишем.**

## Топология

```
                        ┌─ Prometheus (127.0.0.1:9090, ретенция 90д)
127.0.0.1:9006/metrics ─┤     ↑ scrape 15s
                        │  node_exporter (127.0.0.1:9100)
                        └─→ Grafana (127.0.0.1:3000) ──┐
PostgreSQL (view, read-only роль) ─────────────────────┘
                                                        ↓
                                       nginx /grafana/ (auth_basic)
```

**Все три сервиса строго на loopback.** На этом хосте внешний фаервол разрешающий: бинд в `0.0.0.0` означает публикацию в интернет. Это стоило проекту открытых `:9012` и vLLM `:9022`. После установки каждого сервиса проверять `ss -tlnp`.

## Структура файлов

| Файл | Ответственность |
|---|---|
| `monitoring/prometheus.yml` | конфиг скрейпа |
| `monitoring/systemd/prometheus.service` | юнит, бинд на петлю, ретенция |
| `monitoring/systemd/node_exporter.service` | юнит, бинд на петлю |
| `monitoring/grafana.ini` | бинд на петлю, работа под префиксом `/grafana/` |
| `monitoring/sql/usage_view.sql` | view и read-only роль |
| `monitoring/grafana/dashboards/*.json` | дашборды |
| `monitoring/grafana/provisioning/**` | датасорсы и подключение дашбордов |
| `scripts/install-monitoring.sh` | идемпотентная установка |
| `scripts/set-grafana-token.sh` | htpasswd для `/grafana/` |
| `nginx/meno.nsu.ru.conf` | `location /grafana/` |

---

## Task 1: Проверка предусловий на хосте

Выполняется на хосте `meno` до написания чего-либо. Отрицательный результат меняет план.

- [ ] **Step 1: Свободное место**

```bash
df -h /var
```

Оценка TSDB: ~1500–2000 рядов при текущем наборе меток, 15-секундный скрейп, 90 дней → примерно 1–2 ГБ. Нужно минимум 5 ГБ свободного запаса. **Если меньше — сократить ретенцию до 30 дней и записать это решение в план.**

- [ ] **Step 2: Порты свободны**

```bash
sudo ss -tlnp | grep -E ':(9090|9100|3000)' || echo "все три порта свободны"
```

- [ ] **Step 3: Метрики бэкенда отдаются**

```bash
curl -s http://127.0.0.1:9006/metrics | head -5
curl -s http://127.0.0.1:9006/metrics | grep -c '^meno_'
```

Expected: строки формата Prometheus, счётчик заметно больше нуля.

- [ ] **Step 4: Метрики НЕ торчат наружу**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/metrics
```

Expected: **не** `200` с телом метрик. Если `200` и внутри `meno_*` — у Express есть catch-all прокси на бэкенд, и это самостоятельная утечка (имена моделей, адреса эндпоинтов, объёмы трафика, коды ошибок). Чинить до всего остального.

- [ ] **Step 5: Доступ к БД**

```bash
sudo -u postgres psql -c "\l" | grep meno_rag
```

---

## Task 2: node_exporter

**Files:**
- Create: `monitoring/systemd/node_exporter.service`

Включён намеренно: заполненный диск — самая частая причина отказа такого сервиса, и ни одна прикладная метрика её не покажет.

- [ ] **Step 1: Юнит**

```ini
[Unit]
Description=Prometheus node exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
# Loopback only. On this host the upstream firewall is permissive, so a
# 0.0.0.0 bind would publish host metrics to the internet.
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Коммит**

```bash
git add monitoring/systemd/node_exporter.service
git commit -m "feat(monitoring): add the node_exporter systemd unit (loopback only)"
```

---

## Task 3: Prometheus — конфиг и юнит

**Files:**
- Create: `monitoring/prometheus.yml`, `monitoring/systemd/prometheus.service`

- [ ] **Step 1: Конфиг скрейпа**

```yaml
# Prometheus for the Meno RAG backend.
# The backend's metrics registry is in-memory and resets on restart; this is
# what turns it into history that survives one.
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # The RAG backend. Loopback: the scrape never crosses the public edge, so
  # /metrics needs no exposure and no authentication.
  - job_name: meno-rag-api
    static_configs:
      - targets: ['127.0.0.1:9006']

  # Host: CPU, RAM, disk. A full disk is the most common cause of an outage
  # here and no application metric would show it.
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']

  # Prometheus itself, so a sick scraper is visible.
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
```

- [ ] **Step 2: Юнит**

```ini
[Unit]
Description=Prometheus time-series database
Documentation=https://prometheus.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
# --web.listen-address on loopback: Prometheus has no authentication of its
# own, and its UI exposes every series plus the scrape configuration.
# Retention is the whole point of installing it — see the plan for the sizing
# estimate (~1-2 GB at 90d for this metric set).
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=90d \
  --web.listen-address=127.0.0.1:9090
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/prometheus

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Коммит**

```bash
git add monitoring/prometheus.yml monitoring/systemd/prometheus.service
git commit -m "feat(monitoring): add Prometheus config and unit (loopback, 90d retention)"
```

---

## Task 4: SQL — view без доступа к содержимому и read-only роль

**Files:**
- Create: `monitoring/sql/usage_view.sql`

Здесь граница проводится на уровне БД, а не на уровне аккуратно написанного `SELECT`. Это сильнее и это та формулировка, которую можно показать ИБ: у дашборда нет доступа к содержимому диалогов, только к фактам о них.

- [ ] **Step 1: SQL**

```sql
-- Usage metrics for Grafana. Idempotent: safe to re-run.
--
-- Grafana reads product metrics (how many people, how many dialogues) straight
-- from PostgreSQL rather than through a bespoke API endpoint. History is
-- available retroactively, unlike Prometheus which only starts counting at
-- install time.
--
-- IMPORTANT — what this deliberately does NOT expose: messages.content. The
-- Grafana role is granted SELECT on this view only, never on the base tables,
-- so the dashboard cannot read what anyone actually asked or was told. That is
-- a database-enforced boundary, not a convention.
--
-- Basing usage on `conversations` is deliberate: it is written unconditionally.
-- `pipeline_runs` is written only under the improvement consent gate, so any
-- metric built on it is a biased sample of unknown size.

CREATE OR REPLACE VIEW usage_conversations AS
    SELECT
        id,
        user_id,
        guest_session_id,
        created_at
    FROM conversations;

CREATE OR REPLACE VIEW usage_messages AS
    SELECT
        id,
        conversation_id,
        role,
        model,
        created_at
    FROM messages;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meno_grafana') THEN
        CREATE ROLE meno_grafana WITH LOGIN PASSWORD 'CHANGE_ME_BEFORE_RUNNING';
    END IF;
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM meno_grafana;
GRANT CONNECT ON DATABASE meno_rag TO meno_grafana;
GRANT USAGE ON SCHEMA public TO meno_grafana;
GRANT SELECT ON usage_conversations, usage_messages TO meno_grafana;
```

Пароль подставляется при запуске, в git не коммитится реальное значение.

- [ ] **Step 2: Обязательная проверка изоляции**

Утверждение «Grafana не может прочитать содержимое» подлежит проверке, а не декларации. Новая роль в PostgreSQL не получает `SELECT` на таблицы автоматически, но `PUBLIC` имеет `USAGE` на схему `public`, поэтому проверять надо фактом:

```bash
PGPASSWORD='<пароль>' psql -h 127.0.0.1 -U meno_grafana -d meno_rag \
  -c "SELECT content FROM messages LIMIT 1;"
```

Expected: **`ERROR: permission denied for table messages`**. Любой другой результат — задача не выполнена.

```bash
PGPASSWORD='<пароль>' psql -h 127.0.0.1 -U meno_grafana -d meno_rag \
  -c "SELECT count(*) FROM usage_conversations;"
```

Expected: число.

- [ ] **Step 3: Коммит**

```bash
git add monitoring/sql/usage_view.sql
git commit -m "feat(monitoring): add usage views and a content-free Grafana role"
```

---

## Task 5: Grafana — конфиг

**Files:**
- Create: `monitoring/grafana.ini`

- [ ] **Step 1: Конфиг**

```ini
# Grafana for Meno. Served under /grafana/ behind nginx.
[server]
# Loopback only; nginx is the sole way in.
http_addr = 127.0.0.1
http_port = 3000
domain = meno.nsu.ru
root_url = https://meno.nsu.ru/grafana/
serve_from_sub_path = true

[security]
# Anonymous access off: nginx auth_basic is the outer gate, Grafana's own
# login is the inner one. Two independent barriers.
disable_initial_admin_creation = false
cookie_secure = true

[auth.anonymous]
enabled = false

[users]
# No self-service signup: this is an internal dashboard for a named few.
allow_sign_up = false
allow_org_create = false

[analytics]
reporting_enabled = false
check_for_updates = false
```

- [ ] **Step 2: Коммит**

```bash
git add monitoring/grafana.ini
git commit -m "feat(monitoring): add Grafana config (loopback, /grafana/ subpath)"
```

---

## Task 6: Провижининг датасорсов и дашбордов

**Files:**
- Create: `monitoring/grafana/provisioning/datasources/meno.yml`
- Create: `monitoring/grafana/provisioning/dashboards/meno.yml`
- Create: `monitoring/grafana/dashboards/meno-operational.json`
- Create: `monitoring/grafana/dashboards/meno-usage.json`

- [ ] **Step 1: Датасорсы**

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true

  - name: PostgreSQL (usage)
    type: postgres
    access: proxy
    url: 127.0.0.1:5432
    database: meno_rag
    user: meno_grafana
    secureJsonData:
      password: ${GRAFANA_DB_PASSWORD}
    jsonData:
      sslmode: disable
      postgresVersion: 1500
```

- [ ] **Step 2: Подключение дашбордов**

```yaml
apiVersion: 1
providers:
  - name: meno
    orgId: 1
    folder: Meno
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 3: Операционный дашборд**

Полный JSON дашборда Grafana — несколько тысяч строк машинного формата, и писать его руками в плане бессмысленно: он не читается при ревью и мгновенно расходится с тем, что реально нарисовано. Рабочий порядок другой:

1. собрать панели в UI Grafana по запросам из таблицы ниже;
2. **Dashboard settings → JSON Model → Copy to clipboard**;
3. сохранить в `monitoring/grafana/dashboards/meno-operational.json`;
4. закоммитить — дальше файл поедет через провижининг и станет воспроизводимым.

Панели (датасорс Prometheus):

| Панель | Запрос |
|---|---|
| Запросов в секунду по провайдерам | `sum by (provider) (rate(meno_chat_requests_total[5m]))` |
| Латентность p50/p95/p99 | `histogram_quantile(0.95, sum by (le) (rate(meno_chat_request_seconds_bucket[5m])))` (и 0.5, 0.99) |
| Латентность по этапам | `histogram_quantile(0.95, sum by (le, stage) (rate(meno_llm_latency_seconds_bucket[5m])))` |
| Ошибки по кодам | `sum by (code) (rate(meno_errors_total[5m]))` |
| Насыщение admission | `meno_admission_active / meno_admission_limit` |
| Запросов в полёте | `meno_chat_in_flight` |
| Bench-прогоны | `sum by (status) (rate(meno_bench_requests_total[5m]))` |
| HTTP по роутам | `sum by (path, status) (rate(meno_http_requests_total[5m]))` |
| Диск, CPU, RAM | `node_filesystem_avail_bytes`, `rate(node_cpu_seconds_total[5m])`, `node_memory_MemAvailable_bytes` |

Панель bench-прогонов важна для интерпретации: во время прогона GPU занят, а продовые ряды пусты — без этой панели картина выглядит аномалией без объяснения.

- [ ] **Step 4: Продуктовый дашборд**

Тем же порядком: собрать в UI, выгрузить JSON в `monitoring/grafana/dashboards/meno-usage.json`, закоммитить. Запросы (датасорс PostgreSQL):

```sql
-- DAU: уникальные пользователи и гости по дням
SELECT
    date_trunc('day', created_at) AS time,
    count(DISTINCT coalesce(user_id, guest_session_id)) AS "активные"
FROM usage_conversations
WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1;

-- Доля зарегистрированных против гостей
SELECT
    date_trunc('day', created_at) AS time,
    count(DISTINCT user_id) AS "зарегистрированные",
    count(DISTINCT guest_session_id) AS "гости"
FROM usage_conversations
WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1;

-- Диалоги по дням
SELECT date_trunc('day', created_at) AS time, count(*) AS "диалоги"
FROM usage_conversations
WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1;

-- Сообщений на диалог
SELECT
    date_trunc('day', c.created_at) AS time,
    count(m.id)::float / greatest(count(DISTINCT c.id), 1) AS "сообщений на диалог"
FROM usage_conversations c
LEFT JOIN usage_messages m ON m.conversation_id = c.id
WHERE $__timeFilter(c.created_at)
GROUP BY 1 ORDER BY 1;
```

- [ ] **Step 5: Коммит**

```bash
git add monitoring/grafana/
git commit -m "feat(monitoring): provision datasources and the two dashboards"
```

---

## Task 7: Алерты

**Files:**
- Create: `monitoring/prometheus-rules.yml`
- Modify: `monitoring/prometheus.yml` (подключить правила)

- [ ] **Step 1: Правила**

```yaml
groups:
  - name: meno
    rules:
      - alert: BackendDown
        expr: up{job="meno-rag-api"} == 0
        for: 2m
        annotations:
          summary: "Бэкенд не отвечает на скрейп более 2 минут"

      - alert: ErrorRateHigh
        expr: sum(rate(meno_errors_total[5m])) > 0.5
        for: 5m
        annotations:
          summary: "Ошибок больше 0.5/с в течение 5 минут"

      - alert: LatencyP95High
        expr: histogram_quantile(0.95, sum by (le) (rate(meno_chat_request_seconds_bucket[5m]))) > 60
        for: 10m
        annotations:
          summary: "p95 времени ответа выше 60 с"

      - alert: AdmissionSaturated
        expr: meno_admission_active / meno_admission_limit > 0.8
        for: 5m
        annotations:
          summary: "Пул admission заполнен более чем на 80%"

      - alert: DiskFilling
        expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.15
        for: 10m
        annotations:
          summary: "Свободного места на / меньше 15%"
```

Порог латентности в 60 с подобран под RAG с генерацией, а не под обычный веб-сервис. После первой недели наблюдений его нужно пересмотреть по фактическому p95 — алерт, который срабатывает постоянно, перестают читать.

- [ ] **Step 2: Подключить в prometheus.yml**

```yaml
rule_files:
  - /etc/prometheus/rules.yml
```

- [ ] **Step 3: Коммит**

```bash
git add monitoring/prometheus-rules.yml monitoring/prometheus.yml
git commit -m "feat(monitoring): add alerting rules"
```

---

## Task 8: nginx — локация /grafana/ и скрипт доступа

**Files:**
- Modify: `nginx/meno.nsu.ru.conf`
- Create: `scripts/set-grafana-token.sh`

- [ ] **Step 1: Локация**

```nginx
    # ── Grafana ───────────────────────────────────────────────────────────
    # Two independent barriers: nginx Basic Auth (outer) and Grafana's own
    # login (inner). Basic Auth rather than the bench token because a browser
    # cannot be told to send `Authorization: Bearer`, while it handles a Basic
    # realm natively.
    #
    # Its own realm and its own htpasswd file — unrelated to the removed
    # closed-pilot gate.
    location /grafana/ {
        auth_basic           "Meno monitoring";
        auth_basic_user_file /etc/nginx/.meno_grafana_htpasswd;
        proxy_pass http://127.0.0.1:3000;
        include snippets/meno-proxy.conf;
    }

    # Grafana's live-tailing and alerting use websockets.
    location /grafana/api/live/ {
        auth_basic           "Meno monitoring";
        auth_basic_user_file /etc/nginx/.meno_grafana_htpasswd;
        proxy_pass http://127.0.0.1:3000;
        include snippets/meno-proxy.conf;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
```

**Внимание:** эта локация ссылается на `/etc/nginx/.meno_grafana_htpasswd`. В отличие от `map` из B1, отсутствующий `auth_basic_user_file` **не** роняет `nginx -t` — nginx проверяет файл только при запросе и отдаёт 500. Поэтому `deploy.sh` должен отказываться устанавливать эту локацию без файла, либо файл создаётся до первого деплоя. Выбрать первое и добавить проверку в `deploy.sh` рядом с существующими.

- [ ] **Step 2: Скрипт**

```bash
#!/usr/bin/env bash
# Create or rotate the Basic Auth credential for /grafana/.
#
#   sudo ./scripts/set-grafana-token.sh            # first time (refuses if set)
#   sudo ./scripts/set-grafana-token.sh --rotate   # replace it
#
# Mirrors scripts/set-gate-token.sh. Note the file mode differs from the
# benchmark token map: nginx WORKERS read an htpasswd on every request, so the
# file must be readable by www-data. A `map` is compiled into the config at
# load time by the master process, so that one stays root-only.
#
# Requires: htpasswd + openssl  (sudo apt-get install -y apache2-utils openssl).
set -euo pipefail

GRAFANA_GATE_USER="${GRAFANA_GATE_USER:-meno-monitoring}"
HTPASSWD=/etc/nginx/.meno_grafana_htpasswd

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./scripts/set-grafana-token.sh" >&2
    exit 1
fi

if [[ -f "$HTPASSWD" && "${1:-}" != "--rotate" ]]; then
    echo "$HTPASSWD already exists. Re-run with --rotate to replace it." >&2
    exit 1
fi

TOKEN="$(openssl rand -base64 32)"

# -B bcrypt, -c (re)create, -i read from stdin so the secret never enters argv.
printf '%s' "$TOKEN" | htpasswd -B -c -i "$HTPASSWD" "$GRAFANA_GATE_USER"
chown root:www-data "$HTPASSWD"
chmod 640 "$HTPASSWD"

echo "[set-grafana-token] wrote $HTPASSWD for user '$GRAFANA_GATE_USER'"
echo
echo "  ===== GRAFANA ACCESS (shown once) ====="
echo "  user:  $GRAFANA_GATE_USER"
echo "  token: $TOKEN"
echo "  ======================================="
echo
echo "This is only the OUTER gate. Grafana still asks for its own login."
echo "Next: sudo ./scripts/deploy.sh"
```

- [ ] **Step 3: Коммит**

```bash
git add nginx/meno.nsu.ru.conf scripts/set-grafana-token.sh
git commit -m "feat(monitoring): expose Grafana under /grafana/ behind Basic Auth"
```

---

## Task 9: Скрипт установки

**Files:**
- Create: `scripts/install-monitoring.sh`

Идемпотентный, по образцу `deploy.sh`.

- [ ] **Step 1: Написать скрипт**

```bash
#!/usr/bin/env bash
# Idempotent install of the Meno monitoring stack. Safe to re-run.
#
#   sudo ./scripts/install-monitoring.sh
#
# Installs Prometheus + node_exporter from the official release tarballs and
# Grafana from the official apt repo. Every service binds loopback only.
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

# Pinned, not "latest": a deploy must be reproducible. CHECK THESE AGAINST THE
# CURRENT RELEASES before the first run and bump deliberately.
PROM_VERSION="2.53.2"
NODE_EXPORTER_VERSION="1.8.2"
ARCH="linux-amd64"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch_and_verify <name> <version> <url-base>
# Verifies the tarball against the release's own sha256sums file. That catches
# corruption and truncated downloads; it does NOT protect against a compromised
# release, since both files come from the same origin. TLS to github is the
# trust anchor here — worth knowing rather than assuming.
fetch_and_verify() {
    local name="$1" version="$2" base="$3"
    local tarball="${name}-${version}.${ARCH}.tar.gz"
    echo "[install] fetching $tarball"
    curl -fsSL -o "$TMP/$tarball"  "$base/$tarball"
    curl -fsSL -o "$TMP/sha.txt"   "$base/sha256sums.txt"
    ( cd "$TMP" && grep " $tarball\$" sha.txt | sha256sum -c - )
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

# Do not clobber a config edited on the host: re-running the installer must
# never silently discard a hand-tuned scrape config.
if [[ -f /etc/prometheus/prometheus.yml ]] \
   && ! cmp -s "$REPO_DIR/monitoring/prometheus.yml" /etc/prometheus/prometheus.yml; then
    echo "[install] /etc/prometheus/prometheus.yml differs from the repo copy — leaving it alone."
    echo "[install] to adopt the repo version: rm it and re-run."
else
    install -m 0644 "$REPO_DIR/monitoring/prometheus.yml" /etc/prometheus/prometheus.yml
fi
install -m 0644 "$REPO_DIR/monitoring/prometheus-rules.yml" /etc/prometheus/rules.yml
promtool check config /etc/prometheus/prometheus.yml

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
    curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
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
GRAFANA_DB_PASSWORD="$GRAFANA_DB_PASSWORD" \
    envsubst '$GRAFANA_DB_PASSWORD' \
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
sleep 2
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

echo
echo "[install] done. Next:"
echo "  1. psql -f monitoring/sql/usage_view.sql   (create the usage views + role)"
echo "  2. sudo ./scripts/set-grafana-token.sh     (Basic Auth for /grafana/)"
echo "  3. sudo ./scripts/deploy.sh                (publish the /grafana/ location)"
```

Проверка биндов в конце не косметическая: ровно эта ошибка ранее выставила в интернет vLLM `:9022`, поэтому скрипт **отказывается отчитаться об успехе**, если хоть один порт ушёл на все интерфейсы.

- [ ] **Step 2: Проверить синтаксис**

```bash
bash -n scripts/install-monitoring.sh && echo "syntax OK"
```

- [ ] **Step 3: Коммит**

```bash
git add scripts/install-monitoring.sh
git commit -m "feat(monitoring): add the idempotent monitoring installer"
```

---

## Выкат и проверка на хосте

- [ ] **1. Установка**

```bash
cd ~/Projects/Meno-Deploy && git pull && sudo ./scripts/install-monitoring.sh
```

- [ ] **2. Всё на петле — обязательная проверка**

```bash
sudo ss -tlnp | grep -E ':(9090|9100|3000)'
```

Expected: все три строки показывают `127.0.0.1`, ни одной с `0.0.0.0` или `*`.

Дополнительно, снаружи (с другой машины):

```bash
nc -zv 84.237.50.35 9090; nc -zv 84.237.50.35 3000; nc -zv 84.237.50.35 9100
```

Expected: все три соединения отвергнуты.

- [ ] **3. Скрейп работает**

```bash
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -m json.tool | grep -E '"health"|"job"'
```

Expected: все цели `"health": "up"`.

- [ ] **4. Изоляция БД проверена фактом**

Выполнить проверку из Task 4 Step 2. `permission denied for table messages` — обязательный результат.

- [ ] **5. SQL Grafana**

```bash
sudo ./scripts/set-grafana-token.sh
sudo ./scripts/deploy.sh
```

Открыть `https://meno.nsu.ru/grafana/`, пройти Basic Auth, затем логин Grafana. Убедиться, что оба дашборда рисуются и продуктовые панели показывают историю задним числом.

- [ ] **6. Публичный сайт цел**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/v1/models
```

Expected: `200`, `200`.

- [ ] **7. Через неделю — пересмотреть пороги алертов**

Сравнить фактические p95 и частоту ошибок с порогами из Task 7. Алерт, срабатывающий постоянно, перестают читать, и тогда он хуже отсутствующего.

## Откат

- отключить мониторинг, не трогая сайт: `sudo systemctl disable --now prometheus node_exporter grafana-server`;
- убрать Grafana снаружи: `git revert` коммита с локацией + `sudo ./scripts/deploy.sh`;
- удалить данные: `sudo rm -rf /var/lib/prometheus` (теряется история).

Роль `meno_grafana` и view можно оставить — они ничего не делают без Grafana и не влияют на приложение.
