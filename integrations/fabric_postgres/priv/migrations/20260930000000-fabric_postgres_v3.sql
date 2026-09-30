--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

ALTER TABLE fabric_runs ADD COLUMN discovery jsonb, ADD COLUMN discovery_revision bigint, ADD COLUMN dependency_id text GENERATED ALWAYS AS (discovery #>> '{wait,dependency}') STORED, ADD COLUMN observed_key text, ADD COLUMN observed_revision bigint, ADD COLUMN discovery_checked_at timestamptz NOT NULL DEFAULT '-infinity';

CREATE INDEX fabric_runs_discovery ON fabric_runs (discovery_checked_at, run_id) WHERE lease_owner IS NULL AND dependency_id IS NOT NULL;

INSERT INTO fabric_schema_migrations (version) VALUES (3);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

ALTER TABLE fabric_runs DROP COLUMN dependency_id, DROP COLUMN discovery, DROP COLUMN discovery_revision, DROP COLUMN observed_key, DROP COLUMN observed_revision, DROP COLUMN discovery_checked_at;

DELETE FROM fabric_schema_migrations WHERE version = 3;

--- migration:end
