//// The throwaway cluster `scripts/test-postgres.sh` starts: its URL, a
//// connection pool per test, and a fresh schema per test.

import fabric_postgres.{type Settings}
import gleam/erlang/process
import gleam/int
import pog

@external(erlang, "fabric_postgres_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "fabric_postgres_test_ffi", "unique")
pub fn unique() -> Int

@external(erlang, "fabric_postgres_test_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, Nil)

/// The throwaway cluster's URL. These tests run only through
/// `scripts/test-postgres.sh`, which sets it; without it they fail rather
/// than pass untested.
pub fn url() -> String {
  case getenv("FABRIC_TEST_DATABASE_URL") {
    Ok(url) -> url
    Error(Nil) ->
      panic as "FABRIC_TEST_DATABASE_URL is unset: run scripts/test-postgres.sh"
  }
}

/// A new pool of `size` connections to the cluster, linked to the caller.
pub fn pool(size: Int) -> pog.Connection {
  pool_with(size, fn(config) { config })
}

/// A new pool of `size` connections, its configuration changed by
/// `configure`, linked to the caller.
pub fn pool_with(
  size: Int,
  configure: fn(pog.Config) -> pog.Config,
) -> pog.Connection {
  let assert Ok(config) =
    pog.url_config(process.new_name("fabric_postgres_test_pool"), url())
  let assert Ok(started) =
    config |> pog.pool_size(size) |> configure |> pog.start
  started.data
}

/// A schema name no other test uses.
pub fn schema() -> String {
  "t" <> int.to_string(unique())
}

/// Settings of `node` over `connection` in `schema`, migrated.
pub fn migrated(
  connection: pog.Connection,
  node: String,
  schema: String,
) -> Settings {
  let assert Ok(settings) =
    fabric_postgres.settings(connection, node:)
    |> fabric_postgres.with_schema(schema)
  let assert Ok(Nil) = fabric_postgres.migrate(settings)
  settings
}
