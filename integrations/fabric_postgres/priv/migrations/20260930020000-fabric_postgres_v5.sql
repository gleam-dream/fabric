--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

DROP INDEX fabric_runs_discovery;

CREATE INDEX fabric_runs_discovery ON fabric_runs (discovery_checked_at, run_id) WHERE lease_owner IS NULL AND (dependency_id IS NOT NULL OR discovery #>> '{wait,every}' IS NOT NULL OR discovery #>> '{wait,due}' IS NOT NULL);

INSERT INTO fabric_schema_migrations (version) VALUES (5);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

DROP INDEX fabric_runs_discovery;

CREATE INDEX fabric_runs_discovery ON fabric_runs (discovery_checked_at, run_id) WHERE lease_owner IS NULL AND (dependency_id IS NOT NULL OR discovery #>> '{wait,every}' IS NOT NULL);

DELETE FROM fabric_schema_migrations WHERE version = 5;

--- migration:end
