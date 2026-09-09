# B1 — Выставление bench-эндпоинта через nginx

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `https://meno.nsu.ru/bench/v1` проксирует в бэкенд `127.0.0.1:9006/v1` только при верном токене; без токена — `404`, неотличимый от несуществующего пути. Публичный сайт не меняется.

**Architecture:** Один `location` на существующем vhost `:443` плюс `map` в http-контексте, сверяющий заголовок `Authorization`. Проксирование идёт напрямую в бэкенд, минуя Express `:9012`, поэтому bench не задевает фронтовую логику сессий.

**Tech Stack:** nginx 1.24, bash, systemd (только reload).

**Спека:** `Meno-Stand-RAG-Core/docs/superpowers/specs/2026-09-09-bench-endpoint-and-monitoring-design.md`, Часть 2.

**Зависимость:** бэкенд должен уже уметь bench-режим — RAG-Core PR #60. Без него локация будет проксировать в эндпоинт, который вернёт обычный ответ без трейса.

---

## Ключевое отступление от спеки

Спека предписывала fail-closed: нет файла с токеном → `nginx -t` падает → reload не происходит. **Так делать нельзя.** Тот приём был правилен для пилотного гейта, где отсутствие токена означало «сайт не должен быть доступен». Здесь наоборот: bench — необязательная функция, и её неготовность не должна блокировать деплой публичного сайта.

Вместо этого: `deploy.sh` кладёт заглушку `map` с единственной строкой `default 0;`, если реального файла нет. Без токена `$bench_ok` всегда `0`, bench всегда отдаёт `404`, сайт деплоится нормально. Fail-closed сохраняется по сути (без токена доступа нет), но перестаёт быть fail-deploy.

## Структура файлов

| Файл | Действие | Ответственность |
|---|---|---|
| `nginx/meno.nsu.ru.conf` | изменить | добавить `location /bench/v1/` и `location = /bench/metrics` |
| `nginx/conf.d/meno-bench-token.placeholder.conf` | создать | заглушка `map`, ставится когда токен не настроен |
| `scripts/set-bench-token.sh` | создать | генерация токена и запись реального `map` |
| `scripts/deploy.sh` | изменить | ставить заглушку, если реального файла нет |
| `.gitignore` | изменить | никогда не коммитить реальный файл с токеном |
| `README.md` | изменить | раздел про bench-эндпоинт |

Реальный файл живёт по пути `/etc/nginx/conf.d/meno-bench-token.conf` и **в git не попадает никогда** — он содержит токен открытым текстом.

**Почему открытым текстом, в отличие от bcrypt у htpasswd:** nginx `map` умеет только точное сравнение строк, хеш он проверить не может. Это осознанный размен: файл принадлежит root с правами 600, и тот же токен всё равно лежит открытым текстом в `.env` бэкенда, потому что бэкенду нужно его сравнивать. Уровень доверия одинаковый — root на хосте.

---

## Task 1: Заглушка map и правка .gitignore

**Files:**
- Create: `nginx/conf.d/meno-bench-token.placeholder.conf`
- Modify: `.gitignore`

- [ ] **Step 1: Создать заглушку**

```nginx
# Placeholder: NO benchmark token is configured on this host.
#
# `map` is an http-context directive, so it cannot live inside the vhost's
# server block — it is installed into /etc/nginx/conf.d/ instead, which the
# distro's nginx.conf includes at http level.
#
# With only `default 0`, $bench_ok is always 0 and /bench/v1/ always answers
# 404. That is the correct state for a host that does not run benchmarks.
#
# To enable the benchmark endpoint:  sudo ./scripts/set-bench-token.sh
# That overwrites /etc/nginx/conf.d/meno-bench-token.conf with the real map.
map $http_authorization $bench_ok {
    default 0;
}
```

- [ ] **Step 2: Запретить коммит реального файла**

Дописать в `.gitignore`:

```gitignore
# Never commit the real benchmark token map (the real one lives at
# /etc/nginx/conf.d/meno-bench-token.conf and holds the token in clear text)
meno-bench-token.conf
```

Обратите внимание: имя заглушки — `meno-bench-token.placeholder.conf`, оно под это правило не подпадает и коммитится штатно.

- [ ] **Step 3: Проверить, что правило работает**

```bash
cd ~/Projects/Meno-Deploy
touch nginx/conf.d/meno-bench-token.conf
git status --short nginx/conf.d/
```

Expected: показан только `meno-bench-token.placeholder.conf`, реальный файл проигнорирован.

```bash
rm nginx/conf.d/meno-bench-token.conf
```

- [ ] **Step 4: Коммит**

```bash
git add nginx/conf.d/meno-bench-token.placeholder.conf .gitignore
git commit -m "feat(bench): add a no-token placeholder map and ignore the real one"
```

---

## Task 2: Локации в vhost

**Files:**
- Modify: `nginx/meno.nsu.ru.conf`

- [ ] **Step 1: Добавить локации**

В блоке `server` для `:443`, **перед** существующим `location /v1/`, вставить:

```nginx
    # ── Hidden benchmark endpoint ─────────────────────────────────────────
    # OpenAI-compatible path for benchmark runs, for developers only. Proxies
    # straight to the backend, bypassing Express, so benchmark traffic never
    # touches the frontend's session logic.
    #
    # $bench_ok comes from the map in /etc/nginx/conf.d/meno-bench-token.conf
    # (a placeholder that is always 0 until scripts/set-bench-token.sh runs).
    #
    # 404, not 401/403: without the token the path must be indistinguishable
    # from one that does not exist, so a scanner finds nothing. `if` + `return`
    # is one of the two officially safe uses of `if` in nginx.
    #
    # No rate limit on purpose: it would fight the benchmark, which is meant to
    # hammer the endpoint. Concurrency is bounded by the backend's separate
    # bench admission budget (BENCH_MAX_CONCURRENT) instead.
    location /bench/v1/ {
        if ($bench_ok = 0) { return 404; }
        proxy_pass http://127.0.0.1:9006/v1/;
        include snippets/meno-proxy.conf;
        include snippets/meno-sse.conf;
    }

    # Raw Prometheus metrics for ad-hoc debugging, same token. Routine
    # collection does NOT go through here — Prometheus scrapes 127.0.0.1:9006
    # over the loopback and never crosses the public edge.
    location = /bench/metrics {
        if ($bench_ok = 0) { return 404; }
        proxy_pass http://127.0.0.1:9006/metrics;
        include snippets/meno-proxy.conf;
    }
```

Трейлинг-слеш в `proxy_pass http://127.0.0.1:9006/v1/;` обязателен: вместе со слешем в `location /bench/v1/` он заменяет совпавший префикс, так что `/bench/v1/chat/completions` уходит в бэкенд как `/v1/chat/completions`.

`proxy_read_timeout` отдельно не нужен — `meno-sse.conf` уже ставит 3600s.

- [ ] **Step 2: Проверить, что публичные локации не задеты**

```bash
git diff nginx/meno.nsu.ru.conf
```

Expected: только добавленные строки. Блоки `location /v1/` и `location /` не изменены ни на символ — публичный сайт должен продолжать работать ровно как раньше.

- [ ] **Step 3: Коммит**

```bash
git add nginx/meno.nsu.ru.conf
git commit -m "feat(bench): proxy /bench/v1/ to the backend behind a token check"
```

---

## Task 3: Скрипт установки токена

**Files:**
- Create: `scripts/set-bench-token.sh`

- [ ] **Step 1: Написать скрипт**

```bash
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
echo "Verify (the X-Bench-Mode header proves the token matched):"
echo "  curl -si https://$(hostname -f 2>/dev/null || echo meno.nsu.ru)/bench/v1/chat/completions \\"
echo "    -H \"Authorization: Bearer $TOKEN\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"meno-lite\",\"messages\":[{\"role\":\"user\",\"content\":\"тест\"}]}' | head -20"
```

- [ ] **Step 2: Сделать исполняемым и проверить синтаксис**

```bash
chmod +x scripts/set-bench-token.sh
bash -n scripts/set-bench-token.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: Проверить, что токен не утекает в список процессов**

Токен пишется через heredoc в файл, а не передаётся аргументом ни одной команде — в `ps` он не виден. Убедиться глазами, что в скрипте нет `echo "$TOKEN" | someprogram --password="$TOKEN"` или подобного.

- [ ] **Step 4: Коммит**

```bash
git add scripts/set-bench-token.sh
git commit -m "feat(bench): add set-bench-token.sh (generate, install map, reload)"
```

---

## Task 4: deploy.sh ставит заглушку

**Files:**
- Modify: `scripts/deploy.sh`

- [ ] **Step 1: Добавить установку заглушки**

В `scripts/deploy.sh`, в секции 1 (там где ставятся сниппеты), после двух `install` для сниппетов добавить:

```bash
# Benchmark token map. The real file is created by scripts/set-bench-token.sh
# and is never in git; install a no-token placeholder if it is absent, so that
# $bench_ok is always defined. Referencing an undefined variable would make
# `nginx -t` fail and block this deploy entirely — and the benchmark endpoint
# is optional, so its absence must never stop the public site from deploying.
install -d /etc/nginx/conf.d
if [[ ! -f /etc/nginx/conf.d/meno-bench-token.conf ]]; then
    echo "[deploy] no benchmark token configured — installing the no-token placeholder"
    install -m 0600 -o root -g root \
        "$REPO_DIR/nginx/conf.d/meno-bench-token.placeholder.conf" \
        /etc/nginx/conf.d/meno-bench-token.conf
fi
```

Условие `if [[ ! -f ... ]]` обязательно: без него повторный деплой затёр бы настроенный токен заглушкой и молча выключил bench.

- [ ] **Step 2: Проверить синтаксис**

```bash
bash -n scripts/deploy.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: Убедиться в идемпотентности по чтению кода**

Пройти глазами: повторный запуск `deploy.sh` при существующем настроенном `/etc/nginx/conf.d/meno-bench-token.conf` не должен его трогать. Это главный риск задачи — молчаливое выключение работающего bench.

- [ ] **Step 4: Коммит**

```bash
git add scripts/deploy.sh
git commit -m "feat(bench): install the token-map placeholder during deploy"
```

---

## Task 5: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Добавить раздел**

```markdown
## Benchmark endpoint (developers only)

`https://meno.nsu.ru/bench/v1` is an OpenAI-compatible path for benchmark runs.
It returns the full RAG pipeline trace inline and writes nothing to the
production tables. Without a valid token it answers `404`, so it is
indistinguishable from a path that does not exist.

Enable it:

```bash
sudo ./scripts/set-bench-token.sh
```

The script prints the token once and tells you to put the same value in the
backend's `.env` as `BENCH_API_TOKEN`, then restart the backend. **Both sides
must carry it.** nginx alone decides who gets through; the backend decides what
they get — with the token missing on the backend side, a request that passed
nginx is served as an ordinary one, with no trace and every question written to
the production tables.

Use it with any OpenAI client:

```python
client = OpenAI(base_url="https://meno.nsu.ru/bench/v1", api_key="<token>")
```

A bench response carries `X-Bench-Mode: 1`. Assert on that header before a long
run — its absence means the token did not match and you are writing to
production.

Rotate with `sudo ./scripts/set-bench-token.sh --rotate` (then update the
backend `.env` and restart it).

Raw Prometheus metrics are also reachable at `/bench/metrics` behind the same
token, for ad-hoc debugging.
```

- [ ] **Step 2: Коммит**

```bash
git add README.md
git commit -m "docs(bench): document the benchmark endpoint and its token"
```

---

## Выкат и проверка на хосте

Локально проверить конфиг nginx нельзя — нужен установленный nginx с реальными сертификатами. Всё ниже выполняется на хосте `meno`.

- [ ] **1. Предусловие: бэкенд умеет bench**

RAG-Core PR #60 смёржен и выкачен:

```bash
cd ~/Meno-Stand/Meno-Stand-RAG-Core && git pull && ./scripts/run_backend.sh restart
```

- [ ] **2. Выкатить nginx-часть**

```bash
cd ~/Projects/Meno-Deploy && git pull && sudo ./scripts/deploy.sh
```

Expected: `nginx -t` проходит, reload выполняется, в выводе строка про установку заглушки.

- [ ] **3. Убедиться, что публичный сайт цел — ДО включения bench**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/v1/models
```

Expected: `200` и `200`. Если что-то сломалось — откатываться здесь, до включения bench.

- [ ] **4. Bench пока закрыт**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/bench/v1/chat/completions
```

Expected: `404`.

- [ ] **5. Включить токен**

```bash
sudo ./scripts/set-bench-token.sh
```

Скопировать напечатанный токен, дописать `BENCH_API_TOKEN=<токен>` в `.env` бэкенда, затем:

```bash
cd ~/Meno-Stand/Meno-Stand-RAG-Core && ./scripts/run_backend.sh restart
```

- [ ] **6. Проверить обе стороны**

```bash
curl -si https://meno.nsu.ru/bench/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"meno-lite","messages":[{"role":"user","content":"Когда начинается сессия?"}]}' \
  | head -25
```

Expected: `200`, заголовок `X-Bench-Mode: 1`, в теле непустой `pipeline_trace`.

**Если `X-Bench-Mode` отсутствует** — nginx пропустил, а бэкенд токен не признал (разошлись значения, или бэкенд не перезапущен). Запрос при этом записан в прод как обычный. Исправить до любого настоящего прогона.

- [ ] **7. Проверить, что без токена по-прежнему 404**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/bench/v1/chat/completions
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer wrong" https://meno.nsu.ru/bench/v1/chat/completions
```

Expected: `404` и `404`.

- [ ] **8. Ещё раз убедиться, что публичный сайт цел**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://meno.nsu.ru/
```

Expected: `200`.

## Откат

Каждый шаг обратим:

- выключить bench, оставив всё остальное: `sudo rm /etc/nginx/conf.d/meno-bench-token.conf && sudo ./scripts/deploy.sh` (вернётся заглушка → 404);
- откатить nginx-часть целиком: `git revert` коммита с локациями, затем `sudo ./scripts/deploy.sh`;
- аварийно: `sudo systemctl stop nginx` — но это уронит и публичный сайт.
