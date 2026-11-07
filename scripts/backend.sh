#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${BACKEND_ENV_FILE:-$repo_root/.env.backend}"
if [[ "$env_file" != /* ]]; then
    env_file="$PWD/$env_file"
fi
if [[ "${1:-}" == init ]]; then
    python3 - "$env_file" "$repo_root/.env.backend.example" <<'PY'
import os
import secrets
import sys
from pathlib import Path

destination, template = map(Path, sys.argv[1:])
text = template.read_text()
for key in ("BACKEND_POSTGRES_PASSWORD", "AUTH_JWT_SECRET", "BENCH_API_TOKEN"):
    text = text.replace(f"{key}=\n", f"{key}={secrets.token_hex(32)}\n")
try:
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    print(f"Настройки уже существуют: {destination}")
else:
    with os.fdopen(descriptor, "w") as stream:
        stream.write(text)
    print(f"Настройки отдельного backend созданы: {destination}")
PY
    exit 0
fi
if [[ "${1:-}" == bench-token ]]; then
    python3 - "$env_file" <<'PY'
import os
import re
import secrets
import shlex
import sys
import tempfile
from pathlib import Path

destination = Path(sys.argv[1])
if not destination.is_file():
    raise SystemExit('Сначала выполните ./scripts/backend.sh init')
text = destination.read_text()
pattern = re.compile(r'^[ \t]*(?:export[ \t]+)?BENCH_API_TOKEN[ \t]*=[ \t]*(.*)$', re.MULTILINE)
matches = list(pattern.finditer(text))
value = shlex.split(matches[-1].group(1), comments=True) if matches else []
if value and any(value):
    destination.chmod(0o600)
    print(f'Токен бенчмарка уже задан в {destination}')
else:
    token = secrets.token_hex(32)
    if matches:
        text = pattern.sub(f'BENCH_API_TOKEN={token}', text)
    else:
        text += ('' if text.endswith('\n') else '\n') + f'BENCH_API_TOKEN={token}\n'
    descriptor, temporary = tempfile.mkstemp(prefix='.env.backend.', dir=destination.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Токен бенчмарка записан в {destination}')
PY
    exit 0
fi
if [[ ! -f "$env_file" ]]; then
    echo 'Сначала выполните ./scripts/backend.sh init' >&2
    exit 2
fi
if docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
else
    compose=(docker-compose)
fi
export BACKEND_ENV_FILE="$env_file"
exec "${compose[@]}" --project-name meno-ragu-backend --project-directory "$repo_root" --env-file "$env_file" \
    -f "$repo_root/compose.backend.yaml" "$@"
