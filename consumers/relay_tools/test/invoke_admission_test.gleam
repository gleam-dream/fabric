//// Public consumer: a backend commits admission but loses its acknowledgement.
//// A separate process owns real retained bytes and an explicit readback barrier.

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/invoke
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/tool
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

type Command {
  Get(String, process.Subject(Result(backend.Stored, backend.StoreError)))
  Insert(String, String, process.Subject(Result(Nil, backend.StoreError)))
  Commit(String, Int, String, process.Subject(Result(Nil, backend.StoreError)))
  ReadBarrier(Int, process.Subject(Nil))
  Count(process.Subject(Int))
}

fn backend_loop(
  commands: process.Subject(Command),
  records: dict.Dict(String, backend.Stored),
  reads: Int,
) -> Nil {
  case process.receive_forever(commands) {
    Get(id, reply) -> {
      let found = case reads {
        0 -> Error(backend.Unavailable("readback barrier"))
        _ ->
          case dict.get(records, id) {
            Ok(record) -> Ok(record)
            Error(_) -> Error(backend.NotFound)
          }
      }
      process.send(reply, found)
      backend_loop(commands, records, case reads {
        n if n > 0 -> n - 1
        _ -> reads
      })
    }
    Insert(id, record, reply) ->
      case dict.has_key(records, id) {
        True -> {
          process.send(reply, Error(backend.AlreadyExists))
          backend_loop(commands, records, reads)
        }
        False -> {
          // The bytes are retained before acknowledging failure. Readback is
          // blocked independently; duplicate insertion never replaces them.
          let records = dict.insert(records, id, backend.Stored(1, record))
          process.send(reply, Error(backend.Unavailable("insert reply lost")))
          backend_loop(commands, records, reads)
        }
      }
    Commit(id, expected, record, reply) ->
      case dict.get(records, id) {
        Error(_) -> {
          process.send(reply, Error(backend.NotFound))
          backend_loop(commands, records, reads)
        }
        Ok(saved) if saved.revision != expected -> {
          process.send(reply, Error(backend.Conflict(saved.revision)))
          backend_loop(commands, records, reads)
        }
        Ok(_) -> {
          let records =
            dict.insert(records, id, backend.Stored(expected + 1, record))
          process.send(reply, Ok(Nil))
          backend_loop(commands, records, reads)
        }
      }
    ReadBarrier(remaining, reply) -> {
      process.send(reply, Nil)
      backend_loop(commands, records, remaining)
    }
    Count(reply) -> {
      process.send(reply, dict.size(records))
      backend_loop(commands, records, reads)
    }
  }
}

fn with_backend(
  check: fn(store.Store, process.Subject(Command)) -> Nil,
) -> Nil {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      process.send(ready, commands)
      backend_loop(commands, dict.new(), 0)
    })
  let commands = process.receive(ready, 1000) |> should.be_ok
  let runs =
    store.new(
      process.new_name("admission-consumer"),
      get: fn(id) { process.call(commands, 1000, Get(id, _)) },
      insert: fn(id, record) {
        process.call(commands, 1000, Insert(id, record, _))
      },
      compare_and_set: fn(id, revision, record) {
        process.call(commands, 1000, Commit(id, revision, record, _))
      },
    )
  store.start(runs) |> should.equal(Ok(Nil))
  check(runs, commands)
  store.stop(runs) |> should.equal(Ok(Nil))
  process.kill(pid)
}

fn request(input) {
  invoke.request(Nil, input)
  |> invoke.with_principal("requester")
  |> invoke.with_key(Some("order"))
}

fn open_reads(commands, count) {
  process.call(commands, 1000, ReadBarrier(count, _))
}

fn assert_unknown(response, expected) {
  invoke.id(response) |> should.equal(expected)
  invoke.response_kind(response) |> should.equal(invoke.OutcomeUnknown)
}

fn assert_refused(response, code) {
  invoke.response_kind(response) |> should.equal(invoke.Refused)
  invoke.code(response) |> should.equal(code)
}

fn desk(effects) {
  let operation =
    tool.bind(
      tool.define(
        "effect",
        "Record one effect",
        codec.success(Nil),
        codec.int(),
      ),
      fn(_, _, _) {
        process.send(effects, Nil)
        Ok(1)
      },
      fn(_: Nil) { tool.Explain("infallible") },
    )
  let model =
    model.new(fn(request) {
      case list.last(request.messages) {
        Ok(model.UserMessage(_)) ->
          Ok(model.ToolRequest(
            model.AssistantTurn(
              "",
              [model.tool_call("effect-1", "effect", "{}")],
              None,
            ),
            None,
          ))
        _ -> Ok(model.FinalAnswer("done", None))
      }
    })
  agent.new("admission", model, [operation], policy.always_allow())
  |> agent.build
  |> should.be_ok
}

pub fn agent_unknown_admission_keeps_one_run_and_effect_test() {
  use runs, commands <- with_backend
  let effects = process.new_subject()
  let agent = desk(effects)
  let service = invoke.agent("desk", runs, agent)
  let id = invoke.keyed_id(service, "requester", "order")
  let first = invoke.call(service, request("hello"))
  assert_unknown(first, id)
  invoke.code(first) |> should.equal("start_failed")
  process.call(commands, 1000, Count) |> should.equal(1)
  process.receive(effects, 0) |> should.equal(Error(Nil))
  // Same-key retries also stay unknown while the committed record is hidden.
  assert_unknown(invoke.call(service, request("hello")), id)
  // Read counts target the current public admission paths: launch readback,
  // same-input comparison, open, then snapshot. This is fault-path coverage,
  // not a claim about a stable internal read schedule.
  list.each(
    [#(1, "start_failed"), #(2, "unavailable"), #(3, "unavailable")],
    fn(path) {
      open_reads(commands, path.0)
      let response = invoke.call(service, request("hello"))
      assert_unknown(response, id)
      invoke.code(response) |> should.equal(path.1)
    },
  )
  open_reads(commands, -1)
  let handle = fabric.recover(runs, agent, Nil, id) |> should.be_ok
  fabric.await(handle, duration.seconds(2))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  let retry = invoke.call(service, request("hello"))
  invoke.id(retry) |> should.equal(id)
  invoke.answer(retry) |> should.equal(Some("done"))
  process.call(commands, 1000, Count) |> should.equal(1)
  process.receive(effects, 0) |> should.equal(Ok(Nil))
  process.receive(effects, 0) |> should.equal(Error(Nil))
  assert_refused(invoke.call(service, request("changed")), "key_reused")
  assert_refused(
    invoke.call(
      service |> invoke.with_wait(duration.seconds(0)),
      request("hello"),
    ),
    "invalid_config",
  )
}

fn graph_runtime(runs, effects, reject) {
  let node = definition.node_id("effect")
  let op =
    operation.new(
      run.DefinitionId("effect", 1),
      codec.int(),
      codec.int(),
      fn(_, _, input) {
        process.send(effects, Nil)
        Ok(input + 1)
      },
      fn(_: Nil) { tool.Explain("infallible") },
    )
  let node =
    definition.node(
      node,
      op,
      fn(input) {
        case reject {
          True -> panic as "pre-insert callback"
          False -> Ok(input)
        }
      },
      fn(state, answer) { Ok(definition.Finish(state, answer)) },
      [],
    )
  let spec =
    definition.new(
      run.DefinitionId("admission-graph", 1),
      definition.node_id("effect"),
      [node],
      codec.int(),
      codec.int(),
    )
    |> definition.build
    |> should.be_ok
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  |> graph.build
  |> should.be_ok
}

pub fn graph_unknown_admission_keeps_one_run_and_effect_test() {
  use runs, commands <- with_backend
  let effects = process.new_subject()
  let runtime = graph_runtime(runs, effects, False)
  let service = invoke.graph("graph", runtime)
  let id = invoke.keyed_id(service, "requester", "order")
  let first = invoke.call(service, request(1))
  assert_unknown(first, id)
  invoke.code(first) |> should.equal("start_failed")
  process.call(commands, 1000, Count) |> should.equal(1)
  process.receive(effects, 0) |> should.equal(Error(Nil))
  assert_unknown(invoke.call(service, request(1)), id)
  list.each([1, 2], fn(reads) {
    open_reads(commands, reads)
    let response = invoke.call(service, request(1))
    assert_unknown(response, id)
    invoke.code(response) |> should.equal("unavailable")
  })
  open_reads(commands, -1)
  let handle = graph.open(runtime, id) |> should.be_ok
  graph.recover(handle) |> should.be_ok
  graph.await(handle, duration.seconds(2))
  |> should.equal(Ok(graph.Completed(2)))
  let retry = invoke.call(service, request(1))
  invoke.id(retry) |> should.equal(id)
  invoke.answer(retry) |> should.equal(Some(2))
  process.call(commands, 1000, Count) |> should.equal(1)
  process.receive(effects, 0) |> should.equal(Ok(Nil))
  process.receive(effects, 0) |> should.equal(Error(Nil))
  assert_refused(invoke.call(service, request(2)), "key_reused")
  assert_refused(
    invoke.call(service |> invoke.with_wait(duration.seconds(0)), request(1)),
    "invalid_config",
  )
}

pub fn graph_preparation_failure_remains_a_refusal_test() {
  use runs, commands <- with_backend
  let effects = process.new_subject()
  let runtime = graph_runtime(runs, effects, True)
  assert_refused(
    invoke.call(invoke.graph("graph", runtime), request(1)),
    "start_failed",
  )
  process.call(commands, 1000, Count) |> should.equal(0)
  process.receive(effects, 0) |> should.equal(Error(Nil))
}
