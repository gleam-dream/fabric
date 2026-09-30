//// The schema's forward-only migrations, numbered from 1. `migrate` runs
//// these statements; `priv/migrations/*.sql` holds the same statements in
//// cigogne's format (`--- migration:up` ... `--- migration:down` ...
//// `--- migration:end`), so an application that applies its migrations
//// with cigogne installs the same schema, serialised by the same advisory
//// lock. `migrations_test` checks that the two agree statement for
//// statement.
////
//// Each step's statements run with `search_path` set to the target schema
//// only, so they name no schema. The first statement of every step takes
//// the migration lock of that schema; the last records the step in
//// `fabric_schema_migrations`.
////
//// Adding a step: append a `Migration` with the next version, add its
//// cigogne file, and never change a released step.

pub type Migration {
  Migration(version: Int, file: String, statements: List(String))
}

/// The advisory lock key text of a schema's migrations, which the lock
/// statement below computes from `current_schema()`.
pub const lock_prefix = "fabric-postgres-migrate:"

const lock = "SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('fabric-postgres-migrate:' || current_schema(), 0))) AS l"

pub fn all() -> List(Migration) {
  [
    Migration(1, "20260928000000-fabric_postgres_v1.sql", [
      lock,
      "CREATE TABLE fabric_schema_migrations (version integer PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT clock_timestamp())",
      "CREATE TABLE fabric_runs (run_id text PRIMARY KEY CHECK (run_id ~ '^[A-Za-z0-9_-]{1,128}$'), revision bigint NOT NULL CHECK (revision >= 1), record text NOT NULL, phase text, root_id text GENERATED ALWAYS AS (substring(run_id from '^run-[0-9a-f]+')) STORED, lease_owner text, lease_until timestamptz, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(), CHECK ((lease_owner IS NULL) = (lease_until IS NULL)))",
      "CREATE INDEX fabric_runs_expired ON fabric_runs (lease_until) WHERE lease_owner IS NOT NULL",
      "CREATE INDEX fabric_runs_ended ON fabric_runs (updated_at) WHERE phase = 'ended'",
      "CREATE INDEX fabric_runs_family ON fabric_runs (root_id)",
      "INSERT INTO fabric_schema_migrations (version) VALUES (1)",
    ]),
    Migration(2, "20260929000000-fabric_postgres_v2.sql", [
      lock,
      "ALTER TABLE fabric_runs DROP COLUMN root_id",
      "ALTER TABLE fabric_runs ADD COLUMN retention jsonb, ADD COLUMN retention_revision bigint, ADD COLUMN parent_id text GENERATED ALWAYS AS (retention ->> 'parent') STORED REFERENCES fabric_runs(run_id) DEFERRABLE INITIALLY IMMEDIATE",
      "CREATE INDEX fabric_runs_parent ON fabric_runs (parent_id)",
      "DROP INDEX fabric_runs_ended",
      "CREATE INDEX fabric_runs_retention ON fabric_runs (updated_at, run_id) WHERE parent_id IS NULL AND retention_revision = revision AND retention->>'settled' = 'true'",
      "INSERT INTO fabric_schema_migrations (version) VALUES (2)",
    ]),
  ]
}
