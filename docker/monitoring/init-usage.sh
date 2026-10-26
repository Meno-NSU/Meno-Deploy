#!/bin/sh
set -eu
psql -v ON_ERROR_STOP=1 -U meno -d meno <<'SQL'
CREATE OR REPLACE VIEW usage_conversations AS SELECT id, user_id, guest_session_id, created_at FROM conversations;
CREATE OR REPLACE VIEW usage_messages AS SELECT id, conversation_id, role, model, turn_kind, created_at FROM messages;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='meno_grafana') THEN CREATE ROLE meno_grafana; END IF; END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM meno_grafana;
GRANT CONNECT ON DATABASE meno TO meno_grafana;
GRANT USAGE ON SCHEMA public TO meno_grafana;
GRANT SELECT ON usage_conversations, usage_messages TO meno_grafana;
SQL
case "$GRAFANA_DB_PASSWORD" in
    *[!a-fA-F0-9]*|'') echo 'GRAFANA_DB_PASSWORD must be hexadecimal' >&2; exit 1 ;;
esac
printf "ALTER ROLE meno_grafana WITH LOGIN PASSWORD '%s';\n" "$GRAFANA_DB_PASSWORD" | psql -v ON_ERROR_STOP=1 -U meno -d meno
if PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h postgres -U meno_grafana -d meno -c 'SELECT content FROM messages LIMIT 0' >/dev/null 2>&1; then
    echo 'Grafana can read message content' >&2; exit 1
fi
PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h postgres -U meno_grafana -d meno -c 'SELECT count(*) FROM usage_messages'
