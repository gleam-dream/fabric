//// The identity of a sub-agent run. A delegation's child run id cannot be
//// chosen by a caller by accident, and a record stored under a child id
//// counts as the child only when it names the delegation as its parent:
//// a start that finds another run there, a recovery that reattaches it, a
//// cancellation and a lookup through the parent all refuse it, and the
//// delegation becomes an uncertain effect instead of adopting, driving or
//// cancelling an unrelated run.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/checked_agent
import fabric/internal/controller
import fabric/internal/runner
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run.{Requirement}
import fabric/store.{type Store}
import fabric/support
import fabric/support/apps
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

// --- the application -----------------------------------------------------------

pub type Topic {
  Topic(topic: String)
}

fn research() -> tool.Definition(Topic, String) {
  tool.define(
    "research",
    "Delegate research on a topic to a researcher.",
    {
      use topic <- codec.field("topic", codec.string(), get: fn(topic) {
        topic.topic
      })
      codec.success(Topic(topic))
    },
    {
      use summary <- codec.field("summary", codec.string(), get: fn(summary) {
        summary
      })
      codec.success(summary)
    },
  )
}

fn research_call() -> model.ToolCall {
  let assert Ok(call) = testing.call(research(), "r", Topic("gleam"))
  call
}

fn prompt(messages: List(model.Message)) -> String {
  case messages {
    [model.UserMessage(text), ..] -> text
    _ -> ""
  }
}

/// A researcher that answers at once with what it was asked.
fn researcher() -> Agent(Nil, String) {
  agent.new(
    "researcher",
    scripted.model(fn(messages) {
      model.FinalAnswer("found " <> prompt(messages), None)
    }),
    [],
    policy.always_allow(),
  )
  |> support.agent
}

/// Another tenant's run of the same researcher definition.
fn foreign_answer() -> Agent(Nil, String) {
  agent.new(
    "researcher",
    scripted.model(fn(_) { model.FinalAnswer("foreign secret", None) }),
    [],
    policy.always_allow(),
  )
  |> support.agent
}

fn transfer_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

fn transfers_need_approval(
  _: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.name {
    "transfer_funds" -> Ok(policy.RequireApproval(Requirement("transfer", 1)))
    _ -> Ok(policy.Allow)
  }
}

/// A researcher that pauses on an approval before answering.
fn paying_researcher() -> Agent(Nil, String) {
  agent.new(
    "researcher",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn("", [transfer_call()], None),
            None,
          )
        seen -> model.FinalAnswer("paid " <> string.join(seen, ","), None)
      }
    }),
    [apps.transfer_tool()],
    transfers_need_approval,
  )
  |> support.agent
}

fn delegating(child: Agent(Nil, String)) -> Agent(Nil, String) {
  agent.new(
    "agent",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn("", [research_call()], None),
            None,
          )
        seen -> model.FinalAnswer("final: " <> string.join(seen, " | "), None)
      }
    }),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(research(), to: child, prompt: fn(topic: Topic) {
    topic.topic
  })
  |> support.agent
}

// --- instruments ---------------------------------------------------------------

/// An in-memory store that writes agent records with the numbered child
/// ids of record version 8.
fn numbered_store() -> Store {
  let assert Ok(runs) = store.with_record_version(support.store(), 8)
  runs
}

fn numbered_directory(dir: String) -> Store {
  let assert Ok(runs) = store.with_record_version(support.directory(dir), 8)
  runs
}

fn finish(runs: Store, agent: Agent(Nil, String), id: String) -> Nil {
  let assert Ok(run) =
    fabric.start(
      runs,
      agent,
      id: support.id(id),
      context: Nil,
      prompt: "other tenant",
      correlation: None,
    )
  let assert Ok(run.Finished(_)) =
    fabric.await(run, within: duration.milliseconds(5000))
  Nil
}

/// A parent whose delegation waits on a paused child, in a directory store
/// whose owner then crashed. Returns the parent's id and its child's id.
fn paused_family(dir: String) -> #(run.RunId, String) {
  let #(owner, #(runs, parent)) =
    restart.owned(fn() {
      let runs = numbered_directory(dir)
      let assert Ok(parent) =
        fabric.start(
          runs,
          delegating(paying_researcher()),
          id: run.new_id(),
          context: Nil,
          prompt: "go",
          correlation: None,
        )
      #(runs, parent)
    })
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(parent, within: duration.milliseconds(5000))
  let assert Ok(snapshot) = fabric.snapshot(parent)
  let assert [run.ActionRecord(child: Some(child), ..)] = snapshot.actions
  restart.crash(owner, runs)
  #(fabric.id(parent), support.text(child))
}

/// Replaces the record under `child` in `runs` with the record of an
/// unrelated root run of `agent` stored under the same id elsewhere.
fn replace_with_foreign(
  runs: Store,
  child: String,
  agent: Agent(Nil, String),
  finished: Bool,
) -> Nil {
  let elsewhere = numbered_store()
  let assert Ok(run) =
    fabric.start(
      elsewhere,
      agent,
      id: support.id(child),
      context: Nil,
      prompt: "other tenant",
      correlation: None,
    )
  let _ = case finished {
    True -> {
      let assert Ok(run.Finished(_)) =
        fabric.await(run, within: duration.milliseconds(5000))
      Nil
    }
    False -> {
      let assert Ok(run.Suspended([_], [])) =
        fabric.await(run, within: duration.milliseconds(5000))
      Nil
    }
  }
  let assert Ok(foreign) = store_core.get(elsewhere, child)
  let assert Ok(current) = store_core.get(runs, child)
  let assert Ok(_) =
    store_core.commit(
      runs,
      child,
      current.revision,
      foreign.record,
      store_core.Detached(in_flight: False, seize: True),
    )
  Nil
}

// --- tests ---------------------------------------------------------------------

/// A caller-chosen id shaped like the old numbered child id does not alias
/// the first delegation of `job-42`: the delegation runs its own child.
pub fn a_caller_run_id_does_not_alias_a_delegation_child_test() {
  let runs = support.store()
  finish(runs, foreign_answer(), "job-42-1")
  let assert Ok(parent) =
    fabric.start(
      runs,
      delegating(researcher()),
      id: support.id("job-42"),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  fabric.await(parent, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"found gleam\"}"))),
  )
  let assert Ok(snapshot) = fabric.snapshot(parent)
  let assert [run.ActionRecord(child: Some(child), ..)] = snapshot.actions
  string.starts_with(support.text(child), "job-42-") |> should.be_false
}

/// With numbered child ids, a start that finds an unrelated run under the
/// reserved id does not adopt its answer: the delegation is uncertain.
pub fn a_foreign_run_under_a_child_id_is_not_adopted_test() {
  let runs = numbered_store()
  finish(runs, foreign_answer(), "job-7-1")
  let assert Ok(parent) =
    fabric.start(
      runs,
      delegating(researcher()),
      id: support.id("job-7"),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(parent, within: duration.milliseconds(5000))
  uncertain.reference.run |> should.equal(support.id("job-7"))
  string.contains(uncertain.evidence, "not the child") |> should.be_true
  string.contains(uncertain.evidence, "foreign secret") |> should.be_false
}

/// Recovering a parent whose child record was replaced by an unrelated
/// finished run does not apply that run's answer to the delegation.
pub fn recovery_does_not_reattach_a_foreign_child_record_test() {
  let dir = restart.temp_dir()
  let #(parent, child) = paused_family(dir)
  let runs = numbered_directory(dir)
  replace_with_foreign(runs, child, foreign_answer(), True)

  let assert Ok(recovered) =
    fabric.recover(runs, delegating(paying_researcher()), Nil, parent)
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(recovered, within: duration.milliseconds(5000))
  uncertain.reference.run |> should.equal(parent)
  string.contains(uncertain.evidence, "not the child") |> should.be_true
  restart.remove_dir(dir)
}

/// Cancelling a parent does not cancel an unrelated run stored under its
/// child id, and a lookup through the parent does not reach it.
pub fn cancellation_and_lookup_refuse_a_foreign_child_record_test() {
  let dir = restart.temp_dir()
  let #(parent, child) = paused_family(dir)
  let runs = numbered_directory(dir)
  replace_with_foreign(runs, child, paying_researcher(), False)

  let assert Ok(opened) =
    fabric.open(runs, delegating(paying_researcher()), Nil, parent)
  fabric.child(opened, support.id(child)) |> should.be_error

  fabric.cancel_stored(runs, parent)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(foreign) =
    fabric.open(runs, paying_researcher(), Nil, support.id(child))
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(foreign, within: duration.milliseconds(0))
  let assert Ok(snapshot) = fabric.snapshot(opened)
  let assert [run.ActionRecord(state: run.Uncertain(evidence), ..)] =
    snapshot.actions
  string.contains(evidence, "not the child") |> should.be_true
  restart.remove_dir(dir)
}

/// A foreign run paused on an approval, stored under a delegation's child
/// id, is not part of the parent's family: its approval is not pending on
/// the parent and the parent's status does not report it.
pub fn family_reads_refuse_a_foreign_child_record_test() {
  let dir = restart.temp_dir()
  let #(parent, child) = paused_family(dir)
  let runs = numbered_directory(dir)
  replace_with_foreign(runs, child, paying_researcher(), False)

  let assert Ok(opened) =
    fabric.open(runs, delegating(paying_researcher()), Nil, parent)
  let pending = fabric.pending(opened)
  { pending == Ok([]) || result.is_error(pending) } |> should.be_true
  let assert Ok(status) = fabric.await(opened, within: duration.milliseconds(0))
  case status {
    run.Suspended([_, ..], _) -> panic as "a foreign approval surfaced"
    _ -> Nil
  }
  restart.remove_dir(dir)
}

/// A command sent through a delegation's child setup, such as the
/// cancellation of a stopping parent, does not reach a foreign run stored
/// under the child id, even when it is read only after the parent checked.
pub fn a_child_command_does_not_reach_a_foreign_record_test() {
  let dir = restart.temp_dir()
  let #(parent, child) = paused_family(dir)
  let runs = numbered_directory(dir)
  replace_with_foreign(runs, child, paying_researcher(), False)

  let setup =
    runner.setup(
      runs,
      checked_agent.admitted(delegating(paying_researcher())),
      Nil,
      None,
    )
  let assert Ok(child_setup) =
    runner.child_setup(
      setup,
      "research",
      support.text(parent),
      run.ActionId(1, "r"),
    )
  let assert Error(runner.Unreadable(runner.Corrupt(_))) =
    runner.command(child_setup, child, child_setup.env, controller.Cancel, 3)
  let assert Ok(foreign) =
    fabric.open(runs, paying_researcher(), Nil, support.id(child))
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(foreign, within: duration.milliseconds(0))
  restart.remove_dir(dir)
}
