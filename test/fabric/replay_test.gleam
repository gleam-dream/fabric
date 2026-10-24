//// A replayable tool (`tool.with_replay`) is started again after a crash,
//// a timeout or a lost runner, up to its attempts, instead of becoming an
//// uncertain effect. Its handler's own failures are never replayed.

import fabric
import fabric/agent
import fabric/policy
import fabric/run.{After}
import fabric/support
import fabric/support/codecs
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

/// A read whose body crashes on its first `failures` attempts.
fn flaky_read(probe: Probe, failures: Int) -> tool.Tool(Nil) {
  tool.define(
    "read",
    "Reads a value.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_, _call, x: String) -> Result(String, Nil) {
      probe.record(probe, "read")
      case probe.count(probe, "read") <= failures {
        True -> panic as "the read crashed"
        False -> Ok(x)
      }
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn read_call() {
  scripted.call("r", "read", "{\"x\":\"value\"}")
}

fn run(desk: agent.Agent(Nil, String)) -> fabric.Run(Nil, String) {
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "read",
      correlation: None,
    )
  handle
}

fn desk(tool: tool.Tool(Nil)) -> agent.Agent(Nil, String) {
  agent.new(
    "reader",
    scripted.plan([read_call()]),
    [tool],
    policy.always_allow(),
  )
  |> support.agent
}

fn replays(handle: fabric.Run(Nil, String)) -> List(Int) {
  let assert Ok(snapshot) = fabric.snapshot(handle)
  list.map(snapshot.actions, fn(action) { action.replays })
}

pub fn a_crashed_replayable_body_is_started_again_test() {
  let probe = probe.new()
  let handle = run(desk(flaky_read(probe, 2) |> tool.with_replay(3)))
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"value\""))))
  probe.count(probe, "read") |> should.equal(3)
  replays(handle) |> should.equal([2])
}

/// Out of attempts, the action is an uncertain effect as without replay.
pub fn a_body_out_of_attempts_is_uncertain_test() {
  let probe = probe.new()
  let handle = run(desk(flaky_read(probe, 5) |> tool.with_replay(2)))
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(handle, within: duration.seconds(5))
  uncertain.tool |> should.equal("read")
  probe.count(probe, "read") |> should.equal(2)
  replays(handle) |> should.equal([1])
}

/// Without `with_replay` a crash is uncertain at once.
pub fn a_crash_without_replay_is_uncertain_test() {
  let probe = probe.new()
  let handle = run(desk(flaky_read(probe, 1)))
  let assert Ok(run.Suspended([], [_])) =
    fabric.await(handle, within: duration.seconds(5))
  probe.count(probe, "read") |> should.equal(1)
}

/// A body past its timeout is replayed too.
pub fn a_timed_out_replayable_body_is_started_again_test() {
  let probe = probe.new()
  let slow_then_fast =
    tool.define(
      "read",
      "Reads a value.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
    |> tool.bind(
      fn(_, _call, x: String) -> Result(String, Nil) {
        probe.record(probe, "read")
        case probe.count(probe, "read") {
          1 -> {
            // Held until the runtime stops it at its timeout.
            probe.gate(probe, "first")
            Ok(x)
          }
          _ -> Ok(x)
        }
      },
      fn(_) { tool.Explain("failed") },
    )
    |> tool.with_timeout(After(duration.milliseconds(50)))
    |> tool.with_replay(2)
  let handle = run(desk(slow_then_fast))
  let _held = probe.arrival(probe)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"value\""))))
  replays(handle) |> should.equal([1])
}

/// A handler's typed `Uncertain` is its own judgment: never replayed.
pub fn a_handlers_uncertain_failure_is_not_replayed_test() {
  let probe = probe.new()
  let uncertain =
    tool.define(
      "read",
      "Reads a value.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
    |> tool.bind(
      fn(_, _call, _x: String) -> Result(String, Nil) {
        probe.record(probe, "read")
        Error(Nil)
      },
      fn(_) { tool.Uncertain("sent, no reply") },
    )
    |> tool.with_replay(3)
  let handle = run(desk(uncertain))
  let assert Ok(run.Suspended([], [_])) =
    fabric.await(handle, within: duration.seconds(5))
  probe.count(probe, "read") |> should.equal(1)
}

/// After a lost runner, recovery starts a running replayable body again
/// instead of recording an uncertain effect.
pub fn a_replayable_body_is_replayed_after_a_lost_runner_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let gated =
    tool.define(
      "read",
      "Reads a value.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
    |> tool.bind(
      fn(_, _call, x: String) -> Result(String, Nil) {
        probe.record(probe, "read")
        case probe.count(probe, "read") {
          1 -> probe.gate(probe, "held")
          _ -> Nil
        }
        Ok(x)
      },
      fn(_) { tool.Explain("failed") },
    )
    |> tool.with_replay(2)
  let reader = desk(gated)
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(handle) =
        fabric.start(
          runs,
          reader,
          id: run.new_id(),
          context: Nil,
          prompt: "read",
          correlation: None,
        )
      #(runs, handle)
    })
  let _held = probe.arrival(probe)
  restart.crash(owner, runs)
  let assert Ok(recovered) =
    fabric.recover(support.directory(dir), reader, Nil, fabric.id(handle))
  fabric.await(recovered, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"value\""))))
  probe.count(probe, "read") |> should.equal(2)
  replays(recovered) |> should.equal([1])
  restart.remove_dir(dir)
}

pub fn build_bounds_the_attempts_test() {
  let probe = probe.new()
  let built = fn(attempts) {
    agent.new(
      "reader",
      scripted.plan([]),
      [flaky_read(probe, 0) |> tool.with_replay(attempts)],
      policy.always_allow(),
    )
    |> agent.build
  }
  let assert Error([
    agent.InvalidToolLimit("read", agent.ReplayAttempts, 0, 1, 100),
  ]) = built(0)
  let assert Error([
    agent.InvalidToolLimit("read", agent.ReplayAttempts, 101, 1, 100),
  ]) = built(101)
  let assert Ok(_) = built(100)
}
