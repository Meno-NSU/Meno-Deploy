# Docker и Qdrant на сервере Ubuntu

Команды выполняются под root на целевом Ubuntu-сервере. Они устанавливают Docker
Engine, Compose и tmux и запускают только Qdrant. GPU-службы моделей уже работают
на хосте и не требуют NVIDIA Container Toolkit для этого варианта развёртывания.

## Установка

Проверьте дистрибутив командой `cat /etc/os-release`. Для Ubuntu используется
[официальный apt-репозиторий Docker](https://docs.docker.com/engine/install/ubuntu/):

```bash
apt-get update
apt-get install -y ca-certificates curl git openssl tmux
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker version
docker compose version
```

## Файлы окружения

```bash
cd /home/rsolikhov/Meno-Deploy
git pull --ff-only
test -e .env || cp .env.example .env
test -e .env.core || cp .env.core.example .env.core
chmod 600 .env .env.core
openssl rand -hex 32
```

В существующем `.env` задайте следующие значения. В `POSTGRES_PASSWORD` вставьте
результат `openssl rand -hex 32`; при повторной настройке сохраните существующий
пароль. Он нужен для разбора Compose, хотя PostgreSQL сейчас не запускается.

```dotenv
SERVER_NAME=meno.nsu.ru
POSTGRES_PASSWORD=REPLACE_WITH_GENERATED_HEX_PASSWORD
CORE_SOURCE_DIR=/home/rsolikhov/meno_ragu_stand
WEB_SOURCE_DIR=/home/rsolikhov/Meno-Web
KNOWLEDGE_DIR=/home/rsolikhov/knowledge/nsu-v1
QDRANT_HTTP_PORT=6333
```

Другие значения из примера можно оставить: GPU-профиль сейчас не используется.
Для одного Qdrant содержимое `.env.core` пока не требуется менять, но сам файл
должен существовать. Перед запуском backend перенесите в него прежний production
`AUTH_JWT_SECRET` и настройте адреса моделей; не создавайте новый JWT-секрет для
существующих сессий. Адрес Gemma для сборки задаётся отдельно в CLI нового core.

## Запуск и проверка Qdrant

```bash
./scripts/compose.sh --indexing up -d qdrant
./scripts/compose.sh --indexing ps qdrant
curl -fsS --retry 15 --retry-connrefused --retry-delay 2 http://127.0.0.1:6333/collections
```

Для нового хранилища ответ содержит пустой список коллекций. Вариант `--indexing`
открывает REST API только на loopback. Файлы Qdrant сохраняются в томе
`meno_qdrant-data`; контейнер backend будет использовать это же хранилище.

Журнал Qdrant:

```bash
./scripts/compose.sh --indexing logs -f --tail 100 qdrant
```

Далее запускайте `scripts/build_knowledge.py --log-level DEBUG` из нового core
в tmux с сохранением stdout и stderr через `tee`. Полная команда, отключение
от сессии и повторное подключение приведены в разделе «Длительная сборка в tmux
и журналы» README нового core. Установка `uv` описана в
[официальном руководстве](https://docs.astral.sh/uv/getting-started/installation/).
