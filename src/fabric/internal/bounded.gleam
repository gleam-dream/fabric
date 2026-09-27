//// Runs a function in its own process with a deadline, so that neither a
//// crash (including an exit signal from a process it linked) nor a hang
//// reaches the caller.

import fabric/internal/executor
import gleam/erlang/process
import gleam/string

pub type Failure {
  TimedOut
  Crashed(reason: String)
}

/// Runs `body` in a fresh unlinked process and waits at most `timeout`
/// milliseconds for its result. On timeout the process is killed.
pub fn call(timeout: Int, body: fn() -> a) -> Result(a, Failure) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() { process.send(reply, executor.rescue(body)) })
  let monitor = process.monitor(pid)
  let outcome =
    process.new_selector()
    |> process.select_map(reply, fn(result) {
      case result {
        Ok(value) -> Ok(value)
        Error(crash) -> Error(Crashed(crash))
      }
    })
    |> process.select_specific_monitor(monitor, fn(down) {
      Error(Crashed(string.inspect(down.reason)))
    })
    |> process.selector_receive(timeout)
  process.demonitor_process(monitor)
  case outcome {
    Ok(result) -> result
    Error(Nil) -> {
      process.kill(pid)
      Error(TimedOut)
    }
  }
}
