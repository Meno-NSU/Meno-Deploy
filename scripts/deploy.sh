#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
flags=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu|--tls|--monitoring|--bench) flags+=("$1"); shift ;;
        *) echo "Usage: $0 [--gpu] [--tls] [--monitoring] [--bench]" >&2; exit 2 ;;
    esac
done
"$repo_root/scripts/compose.sh" "${flags[@]}" config --quiet
"$repo_root/scripts/compose.sh" "${flags[@]}" up -d --build --wait
