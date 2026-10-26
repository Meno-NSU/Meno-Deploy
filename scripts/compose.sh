#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
else
    compose=(docker-compose)
fi
files=(-f "$repo_root/compose.yaml")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu) files+=(-f "$repo_root/compose.gpu.yaml"); shift ;;
        --tls) files+=(-f "$repo_root/compose.tls.yaml"); shift ;;
        --bench) files+=(-f "$repo_root/compose.bench.yaml"); shift ;;
        --monitoring) files+=(-f "$repo_root/compose.monitoring.yaml"); shift ;;
        *) break ;;
    esac
done
exec "${compose[@]}" --project-directory "$repo_root" --env-file "${MENO_ENV_FILE:-$repo_root/.env}" "${files[@]}" "$@"
