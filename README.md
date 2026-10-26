# Meno: контейнерное развёртывание

Репозиторий связывает новый `Meno-RAGU-Core` (локально `meno_ragu_stand`) и
существующий `Meno-Web`. Исходный production-core не используется при сборке
и не изменяется. Контейнер web собирается из его текущих исходников; Dockerfile
находится здесь, в `docker/web.Dockerfile`.

Основной вариант — один Linux-сервер с RTX 6000 48 ГБ и NVIDIA Container Toolkit.
Локально запускать стек не требуется. Внешняя H100 80 ГБ подключается отдельным
HTTP-адресом Everest после его уточнения.

```text
nginx :80/:443 → web:9012 (страницы)
              → core:9006 /v1 (API и SSE)
                     ├ PostgreSQL + Redis
                     ├ RAGU: файлы графа + Qdrant
                     ├ Meno: переписывание, второй этап переранжирования, ответ
                     ├ bge-m3: векторные представления
                     └ bge-reranker-v2-m3: первый этап переранжирования
```

Наружу опубликованы только порты nginx. API, БД, Qdrant, Redis, модели и
мониторинг доступны в сети Compose. Данные БД, Qdrant, моделей и мониторинга
сохраняются в отдельных томах. Корпус и файлы графа подключаются к core только
для чтения. Основная схема БД и ревизии Alembic совпадают с production-core.

## Подготовка на сервере

Нужны Docker Engine и Compose не ниже 2.24, драйвер NVIDIA и NVIDIA Container
Toolkit. `nvidia-smi` проверяет драйвер на сервере; доступ GPU из контейнера
проверяется отдельно после установки Toolkit. Описание GPU reservations:
[документация Docker](https://docs.docker.com/compose/how-tos/gpu-support/).

Разместите репозитории рядом:

```text
meno/
  Meno-Deploy/
  Meno-Web/
  meno_ragu_stand/   # https://github.com/Meno-NSU/Meno-RAGU-Core
```

В `Meno-Deploy`:

```bash
cp .env.example .env
cp .env.core.example .env.core
chmod 600 .env .env.core
```

Заполните `.env`: `POSTGRES_PASSWORD`, `MODEL_API_KEY`, домен и пути. Для новых
паролей подходит `openssl rand -hex 32` — шестнадцатеричные значения не требуют
дополнительного кодирования в URL PostgreSQL. В `.env.core` **перенесите точное
значение production `AUTH_JWT_SECRET`**, дату юридических документов и остальные
используемые настройки, включая ключи OpenRouter и benchmark. Не генерируйте
новый JWT-секрет при переносе действующих сессий. Эти файлы исключены из git.

Настройки GPU по умолчанию: устройство `0`, доли памяти 0.55 для Meno, 0.15 для
bge-m3 и 0.15 для bge-reranker; остальные 15% оставлены свободными. Это начальные
параметры для 48 ГБ, а не результат испытания на вашей карте. `*_GPU_ID`,
`*_GPU_MEMORY`, `LLM_MODEL`, `LLM_MAX_MODEL_LEN` и `VLLM_IMAGE` можно изменить.
Флаги служб соответствуют закреплённой версии vLLM 0.11.0; для векторизации и
оценки используется `--runner pooling`:
[документация vLLM](https://docs.vllm.ai/en/v0.11.0/models/pooling_models.html).

## Перенос production-БД

Сначала подготовьте новую систему отдельно от действующей. Все команды ниже
выполняются на целевом Linux-сервере. Они не переключают публичный адрес сами.
Не используйте `meno-rag-reset`, `--fresh`, `docker compose down -v` или
`pg_restore --clean` при переносе данных.

1. Сохраните резервную копию старой БД в формате custom с помощью `pg_dump -Fc`.
   Для окончательной копии остановите запись старого backend, чтобы не потерять
   новые сообщения между копированием и переключением. Исходную БД оставьте
   доступной для возврата. Для нового стека используйте PostgreSQL той же
   основной версии или новее; здесь закреплена версия 16.
2. Запустите только хранилища:

   ```bash
   ./scripts/compose.sh up -d postgres redis qdrant
   ```

3. Восстановите копию в пустую БД:

   ```bash
   ./scripts/restore-db.sh /absolute/path/production.dump
   ```

   Скрипт отказывается работать с непустой БД. Восстановление выполняется одной
   транзакцией, без удаления существующих объектов. Сохраняются аккаунты, хеши
   паролей, история, голоса арены, источники, согласия и Alembic revision.
4. Примените миграции перед запуском API:

   ```bash
   ./scripts/compose.sh build migrate
   ./scripts/compose.sh run --rm migrate
   ```

   Если обнаружены таблицы без Alembic revision, запуск прерывается. Сначала
   выясните фактическую ревизию и восстановите учёт миграций; автоматического
   удаления таблиц нет.
5. После запуска сравните число записей и проверьте вход существующего
   пользователя, восстановление истории и арены. Только затем переключайте
   домен/внешний nginx. Если старый nginx уже занимает :80/:443 на этом сервере,
   сначала остановите его в согласованное окно переключения; новый стек не
   останавливает host-службы автоматически.

Резервная копия контейнерной БД создаётся так:

```bash
./scripts/backup-db.sh /absolute/path/meno-2026-10-26.dump
```

Если требуется подключение к существующей БД вместо переноса, задайте в `.env`
`DATABASE_URL=postgresql+asyncpg://...`; адрес должен быть доступен из контейнера.
`127.0.0.1` внутри контейнера указывает на сам контейнер. Для такого варианта
адаптируйте также PostgreSQL datasource и `usage-init` мониторинга.

## База знаний и Qdrant

До запуска API разместите итоговый корпус, отображение фрагментов, словарь
сокращений и каталог графа в `KNOWLEDGE_DIR`. Точный состав файлов указан в
README нового core. В репозитории лежат исходные материалы, а не полная
production-база; старые FAISS/BM25-индексы не заменяют новый граф.

Если граф уже построен, перенесите все его файлы **и снимки трёх коллекций
Qdrant**. Файл `qdrant_collections.json` содержит фактические имена коллекций
`vdb_entity`, `vdb_relation`, `vdb_chunk`. Он нужен, потому что исходный RAGU
выводит имена из пути к графу, а путь в контейнере меняется. Для старого графа
без манифеста укажите реальные имена из исходного Qdrant; не используйте имена,
вычисленные из нового пути.

Для восстановления снимков можно использовать одноразовый контейнер curl в
сети проекта, не публикуя Qdrant наружу. Имя сети при стандартном project name —
`meno_meno`:

```bash
docker run --rm --network meno_meno \
  -v /absolute/path/snapshots:/snapshots:ro curlimages/curl:8.12.1 \
  --fail-with-body -X POST \
  'http://qdrant:6333/collections/ACTUAL_COLLECTION_NAME/snapshots/upload?priority=snapshot' \
  -F 'snapshot=@/snapshots/collection.snapshot'
```

Повторите для всех коллекций с именами из манифеста. Формат снимков и версия
Qdrant должны быть совместимы. Core проверяет наличие и непустоту коллекций при
старте; вместо незаметного пустого поиска `/readyz` вернёт 503.

Если готового графа нет, соберите его на сервере средствами нового core:
сначала корпус и `prepare_chunk_mapping.py`, затем `prepare_graph_index.py`.
Можно использовать отдельный одноразовый контейнер индексирования; пример:

```bash
./scripts/compose.sh --gpu build core
./scripts/compose.sh --gpu up -d postgres redis qdrant llm embedder reranker
./scripts/compose.sh --gpu run --rm --no-deps --user 0 \
  -e EMBEDDER_URL=http://embedder:8000/v1 \
  -v /absolute/path/knowledge:/app/data \
  -w /app/code core python prepare_graph_index.py \
  -i /app/data/chunked_texts_about_nsu_with_metadata_and_scores.jsonl \
  -r /app/data/chunk_mapping_to_texts.json \
  -o /app/data/knowledge/ragu_graph -e BAAI/bge-m3 \
  --embedder_url http://embedder:8000/v1 --embedder_key YOUR_MODEL_API_KEY \
  --llm bond005/meno-lite-0.2 --url http://llm:8000/v1 --key YOUR_MODEL_API_KEY \
  --qdrant_location http://qdrant:6333 \
  --chunk_header title --chunk_header_sources base,news \
  -a /app/data/knowledge/abbreviations.json
```

Перед этим дождитесь здорового состояния моделей. Каталог для сборки должен
быть отдельным от используемой production-базы: индексирование записывает файлы
и коллекции. Сделайте итоговые файлы доступными для чтения UID 10001. Не кладите
ключи в историю команд: для постоянной эксплуатации используйте скрипт
индексирования, читающий значения из переменных окружения.

## Запуск и HTTPS

Для GPU-варианта:

```bash
./scripts/compose.sh --gpu config --quiet
./scripts/deploy.sh --gpu
./scripts/compose.sh --gpu ps
```

Запуск `core` ожидает успешной миграции и готовности моделей, запуск `web` —
успешной проверки `/readyz`. При ошибке ресурсов читайте
`./scripts/compose.sh --gpu logs core`. Если модели уже работают как внешние
HTTP-службы, запускайте без `--gpu` и укажите их URL и ключи в `.env.core`.

Для получения сертификата сначала используйте HTTP-вариант; порт 80 и DNS
должны вести на сервер:

```bash
./scripts/compose.sh --gpu run --rm certbot certonly --webroot \
  -w /var/www/certbot -d meno.nsu.ru --email ADMIN_EMAIL --agree-tos --no-eff-email
./scripts/deploy.sh --gpu --tls
```

При наличии сертификатов укажите `LETSENCRYPT_DIR` на существующий каталог
Let’s Encrypt и сразу используйте `--tls`. Домен в `SERVER_NAME` должен
совпадать с именем каталога сертификата. Для продления:

```bash
./scripts/compose.sh --gpu --tls run --rm certbot renew --webroot -w /var/www/certbot
./scripts/compose.sh --gpu --tls exec edge nginx -s reload
```

Продление нужно поставить в серверный таймер. Флаги `--gpu`, `--tls`,
`--monitoring`, `--bench` задают набор Compose-файлов; при дальнейших командах
используйте тот же набор. `deploy.sh` выполняет проверку конфигурации и
`up -d --build --wait`, не использует systemd/PM2 и не удаляет тома.

## Everest и несколько моделей

`EVEREST_ENDPOINT` в `.env` намеренно пуст. После уточнения укажите URL внешней
H100 с портом 9022 — GPU-вариант добавит его в `VLLM_ENDPOINTS` рядом с локальной
Meno. Для отдельного ключа задайте в `.env.core` JSON-словарь
`VLLM_ENDPOINT_API_KEYS` с реальным адресом в качестве ключа; значение `""`
означает отсутствие заголовка Authorization. Ключ local-моделей берётся из
`MODEL_API_KEY`. Переписывание и переранжирование остаются на локальной Meno,
а пользователь может выбрать внешнюю модель для ответа и арены. Недоступность
внешнего адреса не убирает доступные локальные модели из реестра.

## Benchmark и мониторинг

Benchmark по умолчанию скрыт: неизвестный токен получает ту же SPA-страницу,
что и любой неизвестный путь. Чтобы включить режим, задайте 64-символьный
шестнадцатеричный `BENCH_API_TOKEN` в `.env.core`, затем:

```bash
python3 scripts/configure-bench.py
./scripts/deploy.sh --gpu --tls --bench
```

Карта nginx формируется из того же токена, который читает backend. Проверяйте
`X-Bench-Mode: 1` на ответе `/bench/v1/models` перед измерениями.

Для мониторинга заполните `GRAFANA_ADMIN_PASSWORD` и шестнадцатеричный
`GRAFANA_DB_PASSWORD` в `.env`, затем добавьте `--monitoring` к запуску.
Prometheus сохраняет метрики 90 дней, Grafana доступна на `/grafana/` после
входа. Пароль администратора применяется при первом создании тома Grafana.
Гостевой доступ и самостоятельная регистрация отключены. PostgreSQL-роль
Grafana читает только две агрегируемые проекции; скрипт проверяет, что доступ к
`messages.content` запрещён. Дашборды сохранены из прежнего деплоя. Панели
host CPU/RAM/disk потребуют отдельного node_exporter и пока не получают данных;
сбор метрик приложения работает через `core:9006/metrics`. Правила Prometheus
сохранены, отправка уведомлений не настроена.

## Проверки и возврат

```bash
python3 -m unittest discover -s tests -v
./scripts/compose.sh --gpu --tls config --quiet
```

Тесты проверяют все 16 сочетаний дополнительных Compose-файлов, приватность
портов, порядок миграций, настройки GPU и внешний endpoint. CI также проверяет
nginx в контейнере. Это не заменяет проверку образов, моделей и TLS на целевом
сервере. На рабочем компьютере контейнеры не запускались.

При ошибке до переключения production продолжает работать на старом стеке.
После переключения остановите новый core, верните старый маршрут и запустите
прежний backend с его исходной БД. Записи, сделанные после переключения в новую
БД, потребуют отдельного переноса: автоматического двустороннего объединения
баз нет. Перед обновлением сохраняйте дамп и идентификаторы образов; при
возврате оставляйте тома и файлы базы знаний.

Старая инструкция host-nginx/PM2 сохранена в `docs/legacy-host-deployment.md`,
старый установщик — `scripts/deploy-host-legacy.sh`. Остальные host-скрипты
(`install-monitoring.sh`, `issue-cert.sh`, `set-*-token.sh`) относятся к прежнему
способу развёртывания; для нового стека используйте команды выше.
