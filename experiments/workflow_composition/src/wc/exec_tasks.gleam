//// THROWAWAY (workflow composition experiment). Variant A's executor: plain
//// linked tasks with one concurrency budget per run, shared by every batch
//// the run dispatches (initial tools and later approvals alike).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import wc/agent.{type ActionId}
import wc/ffi
import wc/model.{type ToolCall}
import wc/runtime.{type ExecutorHandle, type Hooks, ExecutorHandle}
import wc/tool

type Msg {
  Submit(List(#(ActionId, ToolCall)))
  Stop
  Done(ActionId, tool.Outcome)
  Down(Pid)
}

type Task {
  Task(id: ActionId, monitor: Monitor)
}

pub fn executor() -> runtime.Executor {
  fn(hooks: Hooks) -> ExecutorHandle {
    let ready = process.new_subject()
    process.spawn(fn() {
      let self = process.new_subject()
      process.send(ready, self)
      loop(hooks, self, [], dict.new())
    })
    let assert Ok(subject) = process.receive(ready, 1000)
    ExecutorHandle(
      submit: fn(actions) { process.send(subject, Submit(actions)) },
      stop: fn() { process.send(subject, Stop) },
    )
  }
}

fn selector(self: Subject(Msg)) -> process.Selector(Msg) {
  process.new_selector()
  |> process.select(self)
  |> process.select_monitors(fn(down) {
    case down {
      process.ProcessDown(pid:, ..) -> Down(pid)
      process.PortDown(..) -> Down(process.self())
    }
  })
}

fn loop(
  hooks: Hooks,
  self: Subject(Msg),
  queue: List(#(ActionId, ToolCall)),
  running: Dict(Pid, Task),
) -> Nil {
  let #(queue, running) = fill(hooks, self, queue, running)
  case process.selector_receive_forever(selector(self)) {
    Submit(actions) -> loop(hooks, self, list.append(queue, actions), running)
    Done(id, outcome) -> {
      hooks.emit(runtime.Reported(id, outcome))
      loop(hooks, self, queue, running)
    }
    Down(pid) -> loop(hooks, self, queue, dict.delete(running, pid))
    Stop -> {
      // Kill every task, then wait for each DOWN: a report sent before a
      // task died is already in this mailbox and is forwarded first.
      dict.each(running, fn(pid, _) {
        process.unlink(pid)
        process.kill(pid)
      })
      drain(hooks, self, running)
      hooks.emit(runtime.Stopped)
    }
  }
}

fn drain(hooks: Hooks, self: Subject(Msg), running: Dict(Pid, Task)) -> Nil {
  case dict.is_empty(running) {
    True -> Nil
    False ->
      case process.selector_receive_forever(selector(self)) {
        Done(id, outcome) -> {
          hooks.emit(runtime.Reported(id, outcome))
          drain(hooks, self, running)
        }
        Down(pid) -> drain(hooks, self, dict.delete(running, pid))
        Submit(_) | Stop -> drain(hooks, self, running)
      }
  }
}

fn fill(
  hooks: Hooks,
  self: Subject(Msg),
  queue: List(#(ActionId, ToolCall)),
  running: Dict(Pid, Task),
) -> #(List(#(ActionId, ToolCall)), Dict(Pid, Task)) {
  case queue, dict.size(running) < hooks.max_in_flight {
    [#(id, call), ..rest], True -> {
      let pid =
        process.spawn(fn() {
          case hooks.fence(id) {
            False -> Nil
            True -> process.send(self, Done(id, invoke(hooks, call)))
          }
        })
      let task = Task(id, process.monitor(pid))
      fill(hooks, self, rest, dict.insert(running, pid, task))
    }
    _, _ -> #(queue, running)
  }
}

/// A crashing tool body may already have caused its effect: uncertain.
pub fn invoke(hooks: Hooks, call: ToolCall) -> tool.Outcome {
  case tool.lookup(hooks.tools, call.name) {
    Error(Nil) -> tool.BoundaryFailure("tool vanished: " <> call.name)
    Ok(t) ->
      case ffi.rescue(fn() { tool.invoke(t, call.arguments) }) {
        Ok(outcome) -> outcome
        Error(crash) -> tool.Uncertain("tool crashed: " <> crash)
      }
  }
}
