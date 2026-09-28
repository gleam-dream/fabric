--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

CREATE TABLE fabric_schema_migrations (version integer PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT clock_timestamp());

CREATE TABLE fabric_runs (run_id text PRIMARY KEY CHECK (run_id ~ '^[A-Za-z0-9_-]{1,128}$'), revision bigint NOT NULL CHECK (revision >= 1), record text NOT NULL, phase text, root_id text GENERATED ALWAYS AS (substring(run_id from '^run-[0-9a-f]+')) STORED, lease_owner text, lease_until timestamptz, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(), CHECK ((lease_owner IS NULL) = (lease_until IS NULL)));

CREATE INDEX fabric_runs_expired ON fabric_runs (lease_until) WHERE lease_owner IS NOT NULL;

CREATE INDEX fabric_runs_ended ON fabric_runs (updated_at) WHERE phase = 'ended';

CREATE INDEX fabric_runs_family ON fabric_runs (root_id);

INSERT INTO fabric_schema_migrations (version) VALUES (1);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

DROP TABLE fabric_runs;

DROP TABLE fabric_schema_migrations;

--- migration:end
