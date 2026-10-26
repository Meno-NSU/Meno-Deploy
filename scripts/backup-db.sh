#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup_file="${1:?Usage: backup-db.sh /path/to/backup.dump}"
umask 077
if [[ -e "$backup_file" ]]; then
    echo "Backup already exists: $backup_file" >&2
    exit 1
fi
temporary_file="$(mktemp "${backup_file}.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT
"$repo_root/scripts/compose.sh" exec -T postgres pg_dump -U meno -d meno --format=custom --no-owner > "$temporary_file"
mv "$temporary_file" "$backup_file"
echo "Backup written: $backup_file"
