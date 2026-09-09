-- Usage metrics for Grafana. Idempotent: safe to re-run as written.
--
-- The DROP before each CREATE is deliberate: CREATE OR REPLACE VIEW cannot
-- remove a column, so editing a view to expose LESS would fail on an existing
-- database ("cannot drop columns from view") — exactly the direction of change
-- this file should always make easy.
--
-- Grafana reads product metrics (how many people, how many dialogues) straight
-- from PostgreSQL rather than through a bespoke API endpoint. History is then
-- available retroactively, unlike Prometheus which only starts counting at
-- install time.
--
-- IMPORTANT — what this deliberately does NOT expose: messages.content. The
-- Grafana role is granted SELECT on these views only, never on the base tables,
-- so the dashboard cannot read what anyone actually asked or was told. That is
-- a database-enforced boundary, not a convention, and it is the form of the
-- claim that can be shown to InfoSec.
--
-- Basing usage on `conversations` is deliberate: it is written unconditionally.
-- `pipeline_runs` is written only under the improvement consent gate, so any
-- metric built on it is a biased sample of unknown size.
--
-- This file carries NO password. The role is created without login; the
-- installer grants LOGIN with a password piped over stdin, so the secret
-- reaches neither git nor the process list.

DROP VIEW IF EXISTS usage_conversations;
CREATE VIEW usage_conversations AS
    SELECT
        id,
        user_id,
        guest_session_id,
        created_at
    FROM conversations;

DROP VIEW IF EXISTS usage_messages;
CREATE VIEW usage_messages AS
    SELECT
        id,
        conversation_id,
        role,
        model,
        turn_kind,
        created_at
    FROM messages;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meno_grafana') THEN
        -- No LOGIN and no password here on purpose; the installer grants both.
        CREATE ROLE meno_grafana;
    END IF;
END
$$;

-- Revoke first, then grant exactly two views. A freshly created role has no
-- table privileges anyway, so this is belt-and-braces for a role that already
-- existed and had been granted something by hand. The installer does not trust
-- this reasoning: it enumerates what the role can actually read and fails if it
-- is anything other than these two views.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM meno_grafana;
GRANT CONNECT ON DATABASE meno_rag TO meno_grafana;
GRANT USAGE ON SCHEMA public TO meno_grafana;
GRANT SELECT ON usage_conversations, usage_messages TO meno_grafana;
