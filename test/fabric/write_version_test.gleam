//// A rolling upgrade reads every supported format while writing the
//// previous format until all old readers have been replaced.

import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/probe
import fabric/support/scripted
import fabric/support/v2/record as old_record
import fabric/sweeper
import fabric/testing
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

pub fn unsupported_write_versions_are_refused_before_startup_test() {
  let runs = store.in_memory(process.new_name("version-window"))
  list.each([-1, 0, 1, 9], fn(version) {
    store.with_record_version(runs, version)
    |> should.equal(Error(store.UnwritableVersion(version, 2, 8)))
  })
}

fn writes(backend: backend.LeasedBackend, id: run.RunId, version: Int) {
  let assert Ok(row) = backend.get(run.id_to_string(id))
  string.contains(row.record, "\"version\":" <> int.to_string(version) <> ",")
  |> should.be_true
  case version {
    2 -> {
      let assert Ok(decoded) = old_record.decode(row.record)
      decoded.run |> should.equal(run.id_to_string(id))
    }
    _ ->
      old_record.decode(row.record)
      |> should.equal(Error(old_record.UnsupportedVersion(version)))
  }
}

import gleam/int

fn node(backend, version) {
  let assert Ok(runs) =
    store.leased(
      process.new_name("version-window"),
      node: "test",
      lease: duration.milliseconds(60_000),
      backend:,
    )
  let assert Ok(runs) = store.with_record_version(runs, version)
  support.started(runs)
}

fn reviewed(body) {
  agent.new(
    "worker",
    scripted.plan([scripted.slow("w", "work")]),
    [scripted.gated_tool(body)],
    fn(_: Nil, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
  )
  |> support.agent
}

pub fn configured_writes_remain_readable_by_the_version_2_decoder_test() {
  let memory = conformance.leased_memory()
  let runs = node(memory.backend, 2)
  let body = probe.new()
  let agent = reviewed(body)
  let assert Ok(started) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(started, within: duration.milliseconds(5000))
  writes(memory.backend, fabric.id(started), 2)
  let assert Ok(_) =
    fabric.approve(
      started,
      pending.reference,
      proof: support.proof(
        pending.reference.requirement,
        support.reviewer("reviewer"),
      ),
      context: Nil,
    )
  let running = probe.arrival(body)
  writes(memory.backend, fabric.id(started), 2)
  probe.release(running)
  fabric.await(started, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"work\""))))
  writes(memory.backend, fabric.id(started), 2)
}

pub fn the_write_target_does_not_restrict_what_can_be_read_test() {
  list.each(
    [#(6, 2), #(2, 6), #(6, 3), #(3, 6), #(6, 4), #(4, 6), #(6, 5), #(5, 6)],
    fn(versions) {
      let memory = conformance.leased_memory()
      let body = probe.new()
      let agent = reviewed(body)
      let first = node(memory.backend, versions.0)
      let second = node(memory.backend, versions.1)
      let assert Ok(started) =
        fabric.start(
          first,
          agent,
          id: run.new_id(),
          context: Nil,
          prompt: "go",
          correlation: None,
        )
      let assert Ok(run.Suspended([pending], [])) =
        fabric.await(started, within: duration.milliseconds(5000))
      writes(memory.backend, fabric.id(started), versions.0)
      let assert Ok(opened) =
        fabric.open(second, agent, Nil, fabric.id(started))
      let assert Ok(_) =
        fabric.approve(
          opened,
          pending.reference,
          proof: support.proof(
            pending.reference.requirement,
            support.reviewer("reviewer"),
          ),
          context: Nil,
        )
      let running = probe.arrival(body)
      probe.release(running)
      fabric.await(opened, within: duration.milliseconds(5000))
      |> should.equal(Ok(run.Finished(run.Completed("final: \"work\""))))
      writes(memory.backend, fabric.id(opened), versions.1)
    },
  )
}

import fabric/model
import fabric/support/restart
import fabric/support/v2/controller as old_controller
import fabric/support/v2/run as old_run
import fabric/tool
import gleam/time/duration
import json/blueprint/codec

pub fn a_child_cancelled_before_storage_is_a_version_2_tombstone_test() {
  let memory = conformance.leased_memory()
  let runs = node(memory.backend, 2)
  let prompt = probe.new()
  let child_calls = probe.new()
  let child =
    agent.new(
      "child",
      scripted.model(fn(_) {
        probe.record(child_calls, "model")
        model.FinalAnswer("done", None)
      }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let research =
    tool.define("research", "Research", codec.string(), codec.string())
  let assert Ok(call) = testing.call(research, "r", "topic")
  let parent =
    agent.new("parent", scripted.plan([call]), [], policy.always_allow())
    |> agent.with_sub_agent(research, to: child, prompt: fn(topic) {
      probe.gate(prompt, "prompt")
      topic
    })
    |> support.agent
  let assert Ok(root) =
    fabric.start(
      runs,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let held = probe.arrival(prompt)
  let assert Ok(_) = fabric.cancel(root)
  fabric.await(root, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let child_id = support.child_id(fabric.id(root), 1)
  writes(memory.backend, child_id, 2)
  let assert Ok(row) = memory.backend.get(run.id_to_string(child_id))
  let assert Ok(decoded) = old_record.decode(row.record)
  decoded.phase |> should.equal(old_controller.Ended(old_run.Cancelled))
  decoded.transcript |> should.equal([])
  writes(memory.backend, fabric.id(root), 2)
  probe.release(held)
  probe.count(child_calls, "model") |> should.equal(0)
}

pub fn a_drained_run_keeps_version_2_through_handoff_and_recovery_test() {
  let memory = conformance.leased_memory()
  let assert Ok(runs) =
    store.leased(
      process.new_name("version-drain"),
      node: "a",
      lease: duration.milliseconds(60_000),
      backend: memory.backend,
    )
  let assert Ok(runs) = store.with_record_version(runs, 2)
  let body = probe.new()
  let agent =
    agent.new(
      "worker",
      scripted.plan([scripted.slow("w", "work")]),
      [scripted.gated_tool(body)],
      policy.always_allow(),
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(started) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(body)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(running)
  restart.stopped(app)
  writes(memory.backend, fabric.id(started), 2)
  let app = restart.application(runs)
  let assert Ok(recovered) =
    fabric.recover(runs, agent, Nil, fabric.id(started))
  fabric.await(recovered, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"work\""))))
  writes(memory.backend, fabric.id(recovered), 2)
  probe.count(body, "start:work") |> should.equal(1)
  restart.stop(app)
}

pub fn automatic_crash_recovery_and_reconciliation_keep_version_2_test() {
  let memory = conformance.leased_memory()
  let a = node(memory.backend, 2)
  let b = node(memory.backend, 2)
  let body = probe.new()
  let agent =
    agent.new(
      "worker",
      scripted.plan([scripted.slow("w", "work")]),
      [scripted.gated_tool(body)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(started) =
    fabric.start(
      a,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(body)
  let assert Ok(runner) = restart.runner(a, fabric.id(started))
  restart.kill(runner)
  let assert Ok(row) = memory.backend.get(run.id_to_string(fabric.id(started)))
  let assert backend.Held(owner, True) = row.holder
  let assert Ok(_) =
    memory.backend.renew(owner, [run.id_to_string(fabric.id(started))], 0)
  let assert Ok(sweeper_pid) =
    sweeper.start(
      b,
      [sweeper.agent(agent, fn(_) { Nil })],
      every: duration.milliseconds(10),
    )
  let assert Ok(opened) = fabric.open(b, agent, Nil, fabric.id(started))
  let uncertain = await_uncertain(opened, 3000)
  writes(memory.backend, fabric.id(opened), 2)
  let assert Ok(_) = fabric.reconcile(opened, uncertain.reference, "\"work\"")
  fabric.await(opened, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"work\""))))
  writes(memory.backend, fabric.id(opened), 2)
  probe.count(body, "start:work") |> should.equal(1)
  process.unlink(sweeper_pid)
  restart.kill(sweeper_pid)
}

fn await_uncertain(run, tries) {
  case fabric.await(run, within: duration.milliseconds(0)) {
    Ok(run.Suspended([], [effect])) -> effect
    _ if tries > 0 -> {
      process.sleep(10)
      await_uncertain(run, tries - 1)
    }
    _ -> panic as "automatic recovery did not finish"
  }
}

pub fn cancelling_without_an_agent_keeps_the_selected_write_version_test() {
  let memory = conformance.leased_memory()
  let runs = node(memory.backend, 2)
  let body = probe.new()
  let assert Ok(started) =
    fabric.start(
      runs,
      reviewed(body),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended(_, _)) =
    fabric.await(started, within: duration.milliseconds(5000))
  fabric.cancel_stored(runs, fabric.id(started))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  writes(memory.backend, fabric.id(started), 2)
  probe.count(body, "start:work") |> should.equal(0)
}

pub fn an_old_writer_stops_before_effects_and_recovery_with_the_new_writer_runs_once_test() {
  list.each([2, 3], fn(version) {
    let memory = conformance.leased_memory()
    let old = node(memory.backend, version)
    let assert Ok(current) = store.with_record_version(old, 4)
    let body = probe.new()
    let agent =
      agent.new(
        "metadata",
        scripted.model(fn(request) {
          case scripted.results(request) {
            [] ->
              model.ToolRequest(
                model.AssistantTurn(
                  "",
                  [scripted.slow("w", "work")],
                  option.Some(model.ProviderData("example.v1", "opaque")),
                ),
                None,
              )
            _ -> model.FinalAnswer("done", None)
          }
        }),
        [scripted.gated_tool(body)],
        policy.always_allow(),
      )
      |> support.agent
    let assert Ok(started) =
      fabric.start(
        old,
        agent,
        id: run.new_id(),
        context: Nil,
        prompt: "go",
        correlation: None,
      )
    fabric.await(started, within: duration.milliseconds(5000))
    |> should.equal(Ok(run.Unattended))
    probe.count(body, "start:work") |> should.equal(0)
    writes(memory.backend, fabric.id(started), version)
    let assert Ok(recovered) =
      fabric.recover(current, agent, Nil, fabric.id(started))
    let running = probe.arrival(body)
    probe.release(running)
    fabric.await(recovered, within: duration.milliseconds(5000))
    |> should.equal(Ok(run.Finished(run.Completed("done"))))
    probe.count(body, "start:work") |> should.equal(1)
    writes(memory.backend, fabric.id(recovered), 4)
    let assert Ok(snapshot) = fabric.snapshot(recovered)
    let assert [
      _,
      model.AssistantMessage(model.AssistantTurn(data: option.Some(data), ..)),
      ..
    ] = snapshot.transcript
    data |> should.equal(model.ProviderData("example.v1", "opaque"))
  })
}
