import fabric/store
import fabric_postgres
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/time/duration
import pog

pub fn start(database_url: String, node: String) -> store.Store {
  let pool = process.new_name("db")
  let assert Ok(config) = pog.url_config(pool, database_url)
  let settings =
    fabric_postgres.settings(pog.named_connection(pool), node:)
    |> fabric_postgres.with_lease(duration.seconds(30))
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("runs"), settings)

  // The pool first, the store after it: a rest-for-one supervisor restarts
  // the store when the pool restarts, and stops the store (whose runners
  // drain and commit their handoffs) before the pool.
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(pog.supervised(config |> pog.pool_size(10)))
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
  let assert Ok(Nil) = fabric_postgres.migrate(settings)
  runs
}
