import fabric/store
import gleam/erlang/process.{type Pid}

pub fn url() -> String {
  let assert Ok(url) = getenv("FABRIC_JOBS_URL")
  url
}

pub fn directory(path: String) -> store.Store {
  let runs = store.directory(process.new_name("job-restart"), path)
  let assert Ok(Nil) = store.start(runs)
  runs
}

pub fn owned(body: fn() -> a) -> #(Pid, a) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(reply, body())
      let hold: process.Subject(Nil) = process.new_subject()
      process.receive_forever(hold)
    })
  #(pid, process.receive_forever(reply))
}

fn gone(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
}

pub fn crash(owner: Pid, runs: store.Store) -> Nil {
  let assert Ok(pid) = store.pid(runs)
  process.kill(owner)
  gone(owner)
  gone(pid)
}

@external(erlang, "fabric_jobs_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "fabric_jobs_test_ffi", "temp_dir")
pub fn temp_dir() -> String

@external(erlang, "fabric_jobs_test_ffi", "remove_dir")
pub fn remove_dir(path: String) -> Nil

@external(erlang, "fabric_jobs_test_ffi", "sha256")
pub fn sha256(text: String) -> String
