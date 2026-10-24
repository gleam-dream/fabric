//// The pool's password never prints: Fabric keeps only the application's
//// `pog.Connection`, which names the pool, so `string.inspect` of settings,
//// a store, a backend or a failure shows no credential.

import fabric_postgres
import fabric_postgres/support
import gleam/erlang/process
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import pog

const secret = "postgres-inspect-secret-5d0e"

fn hidden(value: a) -> Nil {
  string.contains(string.inspect(value), secret) |> should.be_false
}

pub fn inspecting_settings_and_stores_never_prints_the_password_test() {
  // The throwaway cluster trusts every connection, so it accepts any
  // password; the pool still holds this one in its configuration.
  let connection =
    support.pool_with(1, fn(config) { pog.password(config, Some(secret)) })
  let schema = support.schema()
  let settings = support.migrated(connection, "a", schema)
  hidden(connection)
  hidden(settings)
  hidden(fabric_postgres.backend(settings))
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("credentials"), settings)
  hidden(runs)
}

pub fn inspecting_a_migration_failure_never_prints_the_password_test() {
  let connection =
    support.pool_with(1, fn(config) {
      config |> pog.database("nowhere") |> pog.password(Some(secret))
    })
  let settings = fabric_postgres.settings(connection, node: "a")
  let assert Error(failure) = fabric_postgres.migrate(settings)
  hidden(failure)
}
