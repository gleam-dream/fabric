//// The PostgreSQL backend passes Fabric's leased backend conformance
//// checks (`fabric/testing.leased_backend_checks`), each in a schema of
//// its own.

import fabric/testing
import fabric_postgres
import fabric_postgres/support
import gleam/list
import gleeunit/should

pub fn the_postgres_backend_conforms_test() {
  let connection = support.pool(20)
  testing.leased_backend_checks(fn() {
    fabric_postgres.backend(support.migrated(connection, "a", support.schema()))
  })
  |> list.filter_map(fn(check) {
    case check.run() {
      Ok(Nil) -> Error(Nil)
      Error(problem) -> Ok(#(check.name, problem))
    }
  })
  |> should.equal([])
}
