--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

DROP INDEX fabric_runs_discovery;

ALTER TABLE fabric_runs DROP COLUMN dependency_id, DROP COLUMN observed_revision, ADD COLUMN dependency_ids jsonb GENERATED ALWAYS AS (discovery #> '{wait,dependencies}') STORED, ADD COLUMN observed_dependencies jsonb;

CREATE INDEX fabric_runs_discovery ON fabric_runs (discovery_checked_at, run_id) WHERE lease_owner IS NULL AND (dependency_ids IS NOT NULL OR discovery #>> '{wait,every}' IS NOT NULL OR discovery #>> '{wait,due}' IS NOT NULL);

INSERT INTO fabric_schema_migrations (version) VALUES (6);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

DROP INDEX fabric_runs_discovery;

ALTER TABLE fabric_runs DROP COLUMN dependency_ids, DROP COLUMN observed_dependencies, ADD COLUMN dependency_id text GENERATED ALWAYS AS (discovery #>> '{wait,dependency}') STORED, ADD COLUMN observed_revision bigint;

CREATE INDEX fabric_runs_discovery ON fabric_runs (discovery_checked_at, run_id) WHERE lease_owner IS NULL AND (dependency_id IS NOT NULL OR discovery #>> '{wait,every}' IS NOT NULL OR discovery #>> '{wait,due}' IS NOT NULL);

DELETE FROM fabric_schema_migrations WHERE version = 6;

--- migration:end
