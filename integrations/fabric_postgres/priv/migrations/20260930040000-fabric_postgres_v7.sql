--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

ALTER TABLE fabric_runs ADD COLUMN statistics jsonb, ADD COLUMN statistics_revision bigint;

INSERT INTO fabric_schema_migrations (version) VALUES (7);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l;

ALTER TABLE fabric_runs DROP COLUMN statistics, DROP COLUMN statistics_revision;

DELETE FROM fabric_schema_migrations WHERE version = 7;

--- migration:end
