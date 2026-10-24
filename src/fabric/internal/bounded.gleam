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

/// Runs `body` behind a guardian unlinked from the caller. The guardian
/// gives it `timeout` milliseconds and kills it directly on timeout or
/// caller death, even when the body traps exit signals.
pub fn call(timeout: Int, body: fn() -> a) -> Result(a, Failure) {
  let reply = process.new_subject()
  let caller = process.self()
  let pid =
    process.spawn_unlinked(fn() {
      let parent = process.monitor(caller)
      let done = process.new_subject()
      let worker =
        process.spawn(fn() { process.send(done, executor.rescue(body)) })
      let outcome =
        process.new_selector()
        |> process.select_map(done, Ok)
        |> process.select_specific_monitor(parent, fn(_) { Error(Nil) })
        |> process.selector_receive(timeout)
      case outcome {
        Ok(Ok(result)) -> {
          let result = case result {
            Ok(value) -> Ok(value)
            Error(crash) -> Error(Crashed(crash))
          }
          process.send(reply, result)
        }
        Ok(Error(Nil)) -> {
          process.unlink(worker)
          process.kill(worker)
        }
        Error(Nil) -> {
          // Kill the body directly: it may trap linked exit signals.
          process.unlink(worker)
          process.kill(worker)
          process.send(reply, Error(TimedOut))
        }
      }
    })
  let monitor = process.monitor(pid)
  let outcome =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(down) {
      Error(Crashed(string.inspect(down.reason)))
    })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  outcome
}
