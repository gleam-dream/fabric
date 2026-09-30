--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

ALTER TABLE fabric_runs DROP COLUMN root_id;

ALTER TABLE fabric_runs ADD COLUMN retention jsonb, ADD COLUMN retention_revision bigint, ADD COLUMN parent_id text GENERATED ALWAYS AS (retention ->> 'parent') STORED REFERENCES fabric_runs(run_id) DEFERRABLE INITIALLY IMMEDIATE;

CREATE INDEX fabric_runs_parent ON fabric_runs (parent_id);

DROP INDEX fabric_runs_ended;

CREATE INDEX fabric_runs_retention ON fabric_runs (updated_at, run_id) WHERE parent_id IS NULL AND retention_revision = revision AND retention->>'settled' = 'true';

INSERT INTO fabric_schema_migrations (version) VALUES (2);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

ALTER TABLE fabric_runs DROP COLUMN parent_id, DROP COLUMN retention_revision, DROP COLUMN retention;

ALTER TABLE fabric_runs ADD COLUMN root_id text GENERATED ALWAYS AS (substring(run_id from '^run-[0-9a-f]+')) STORED;

CREATE INDEX fabric_runs_family ON fabric_runs (root_id);

CREATE INDEX fabric_runs_ended ON fabric_runs (updated_at) WHERE phase = 'ended';

DELETE FROM fabric_schema_migrations WHERE version = 2;

--- migration:end
