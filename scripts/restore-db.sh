#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup_file="${1:?Usage: restore-db.sh /path/to/backup.dump}"
[[ -f "$backup_file" ]] || { echo "Backup not found: $backup_file" >&2; exit 1; }
table_count="$("$repo_root/scripts/compose.sh" exec -T postgres psql -U meno -d meno -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")"
if [[ "$table_count" != 0 ]]; then
    echo "Restore requires an empty target database; existing data were not changed." >&2
    exit 1
fi
"$repo_root/scripts/compose.sh" exec -T postgres pg_restore -U meno -d meno --no-owner --no-acl --exit-on-error --single-transaction < "$backup_file"
echo "Restore complete. Run migrations before starting core."
