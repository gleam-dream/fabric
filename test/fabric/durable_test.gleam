//// Restart and runner loss through the public API: runs in a directory
//// store whose every Fabric process is killed, then reopened and
//// recovered. Tests wait on barriers, monitors, and committed statuses,
//// never on sleeps.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/controller
import fabric/internal/family
import fabric/internal/record
import fabric/model
import fabric/policy
import fabric/run.{type RunId, ActionId}
import fabric/store.{type Store}
import fabric/support
import fabric/support/apps
import fabric/support/flaky
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleeunit/should
import json/blueprint/codec

// --- instruments ---------------------------------------------------------------

/// Starts a run in a directory store owned by a new process, so killing
/// that process takes the store and, through it, the runner down.
fn start_owned(
  dir: String,
  agent: Agent(context),
  context: context,
  prompt: String,
) -> #(Pid, Store, fabric.Run(context)) {
  let #(owner, #(store, run)) =
    restart.owned(fn() {
      let store = support.directory(dir)
      let assert Ok(run) = fabric.start(store, agent, context, prompt)
      #(store, run)
    })
  #(owner, store, run)
}

/// Kills the owner and waits until its store and the run's runner are gone:
/// only the files remain.
fn crash(owner: Pid, store: Store, id: RunId) -> Nil {
  let runner = restart.runner(store, id)
  restart.crash(owner, store)
  case runner {
    Ok(pid) -> restart.gone(pid)
    Error(Nil) -> Nil
  }
}

fn reopen(dir: String) -> Store {
  let store = support.directory(dir)
  store
}

fn states(run: fabric.Run(context)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

fn incarnation(run: fabric.Run(context)) -> Int {
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.incarnation
}

/// Three calls to the gated tool, run one at a time.
fn three_slow(probe: Probe) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([
      scripted.slow("c", "c"),
      scripted.slow("a", "a"),
      scripted.slow("b", "b"),
    ]),
    [scripted.gated_tool(probe)],
    policy.always_allow(),
  )
  |> agent.with_limits(
    agent.Limits(..agent.default_limits(), max_concurrency: 1),
  )
  |> support.agent
}

const lost = "the runner was lost while the tool ran; its effect may have happened"

// --- restart -------------------------------------------------------------------

/// `c` completed, `a` was running (its effect happened: `start:a`), `b`
/// was queued. After the restart `c`'s result is kept, `a` is an uncertain
/// effect that is never run again, and `b` is dispatched again.
pub fn restart_keeps_results_and_takes_over_running_and_queued_tools_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(owner, old, run) = start_owned(dir, three_slow(probe), Nil, "go")
  probe.release(probe.arrival(probe))
  let running = probe.arrival(probe)
  running.name |> should.equal("a")
  crash(owner, old, fabric.id(run))

  let store = reopen(dir)
  let assert Ok(run) =
    fabric.recover(store, three_slow(probe), Nil, fabric.id(run))
  let queued = probe.arrival(probe)
  queued.name |> should.equal("b")
  probe.release(queued)
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Suspended([], [
        run.UncertainAction(
          run.ActionRef(fabric.id(run), ActionId(1, "a")),
          "slow",
          lost,
        ),
      ]),
    ),
  )
  states(run)
  |> should.equal([
    run.Succeeded("\"c\""),
    run.Uncertain(lost),
    run.Succeeded("\"b\""),
  ])
  incarnation(run) |> should.equal(2)

  let assert Ok(_) =
    fabric.reconcile(
      run,
      run.ActionRef(fabric.id(run), ActionId(1, "a")),
      "\"a\"",
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: \"c\" | \"a\" | \"b\""))),
  )
  probe.entries(probe)
  |> list.filter(fn(entry) { entry != "end:c" && entry != "end:b" })
  |> should.equal(["start:c", "start:a", "start:b"])
  restart.remove_dir(dir)
}

/// The crash window: the tool's effect happened, then every process died
/// before its result was committed. Fabric cannot know whether the effect
/// happened, so it says so and waits for the application.
pub fn an_effect_whose_result_was_never_committed_is_uncertain_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let #(owner, old, run) = start_owned(dir, agent, Nil, "go")
  let _effect_done = probe.arrival(probe)
  crash(owner, old, fabric.id(run))

  let assert Ok(run) = fabric.recover(reopen(dir), agent, Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  uncertain.reference.id |> should.equal(ActionId(1, "a"))
  // The model is not called until the effect is reconciled.
  fabric.await(run, 0)
  |> should.equal(Ok(run.Suspended([], [uncertain])))
  probe.count(probe, "start:a") |> should.equal(1)
  restart.remove_dir(dir)
}

pub fn restart_during_a_model_call_issues_it_again_against_the_turn_budget_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let blocking =
    model.new(fn(_request) {
      probe.gate(probe, "model")
      Ok(model.FinalAnswer("never committed", None))
    })
  let #(owner, old, run) =
    start_owned(
      dir,
      agent.new("agent", blocking, [], policy.always_allow())
        |> support.agent,
      Nil,
      "hi",
    )
  let _ = probe.arrival(probe)
  crash(owner, old, fabric.id(run))

  let answering = scripted.model(fn(_) { model.FinalAnswer("hello", None) })
  let assert Ok(run) =
    fabric.recover(
      reopen(dir),
      agent.new("agent", answering, [], policy.always_allow())
        |> support.agent,
      Nil,
      fabric.id(run),
    )
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("hello"))))
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.turns_used |> should.equal(2)
  snapshot.incarnation |> should.equal(2)
  restart.remove_dir(dir)
}

pub fn a_lost_model_call_is_not_issued_again_beyond_the_turn_budget_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let blocking =
    model.new(fn(_request) {
      probe.gate(probe, "model")
      Ok(model.FinalAnswer("never committed", None))
    })
  let limited = fn(model) {
    agent.new("agent", model, [], policy.always_allow())
    |> agent.with_limits(agent.Limits(..agent.default_limits(), max_turns: 1))
    |> support.agent
  }
  let #(owner, old, run) = start_owned(dir, limited(blocking), Nil, "hi")
  let _ = probe.arrival(probe)
  crash(owner, old, fabric.id(run))

  let answering = scripted.model(fn(_) { model.FinalAnswer("hello", None) })
  let assert Ok(run) =
    fabric.recover(reopen(dir), limited(answering), Nil, fabric.id(run))
  fabric.await(run, 0)
  |> should.equal(Ok(run.Finished(run.BudgetExhausted(run.TurnLimit(1)))))
  restart.remove_dir(dir)
}

/// Eight recoveries through one store race; exactly one takes the run
/// over and the queued tool is dispatched once.
pub fn concurrent_recoveries_take_the_run_over_once_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), max_concurrency: 1),
    )
    |> support.agent
  let #(owner, old, run) = start_owned(dir, agent, Nil, "go")
  let _ = probe.arrival(probe)
  crash(owner, old, fabric.id(run))

  let store = reopen(dir)
  let results = process.new_subject()
  list.each(list.repeat(Nil, 8), fn(_) {
    process.spawn(fn() {
      process.send(
        results,
        fabric.recover(store, agent, Nil, fabric.id(run))
          |> should.be_ok
          |> fabric.id,
      )
    })
  })
  list.each(list.repeat(Nil, 8), fn(_) {
    process.receive(results, 5000) |> should.equal(Ok(fabric.id(run)))
  })
  let assert Ok(run) = fabric.recover(store, agent, Nil, fabric.id(run))
  incarnation(run) |> should.equal(2)
  probe.release(probe.arrival(probe))
  let assert Ok(run.Suspended([], [_])) = fabric.await(run, 5000)
  probe.count(probe, "start:b") |> should.equal(1)
  incarnation(run) |> should.equal(2)
  restart.remove_dir(dir)
}

pub fn recovering_a_finished_run_opens_it_unchanged_test() {
  let dir = restart.temp_dir()
  let agent =
    agent.new(
      "agent",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let #(owner, old, run) = start_owned(dir, agent, Nil, "hi")
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  crash(owner, old, fabric.id(run))

  let assert Ok(run) = fabric.recover(reopen(dir), agent, Nil, fabric.id(run))
  fabric.await(run, 0) |> should.equal(Ok(run.Finished(run.Completed("done"))))
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.incarnation |> should.equal(1)
  snapshot.turns_used |> should.equal(1)
  fabric.cancel(run) |> should.equal(Error(fabric.RunEnded))
  restart.remove_dir(dir)
}

/// A runner of an older incarnation keeps running after another store over
/// the same directory took the run over. Its tool's effect happens, but
/// its commit fails: the result it carries is never committed, the tool
/// stays an uncertain effect, and the old runner stops.
pub fn a_runner_of_an_older_incarnation_cannot_commit_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let old_store = reopen(dir)
  let assert Ok(run) = fabric.start(old_store, agent, Nil, "go")
  let held = probe.arrival(probe)
  let assert Ok(old_runner) = restart.runner(old_store, fabric.id(run))

  let assert Ok(taken) = fabric.recover(reopen(dir), agent, Nil, fabric.id(run))
  incarnation(taken) |> should.equal(2)
  probe.release(held)
  restart.gone(old_runner)

  probe.count(probe, "end:a") |> should.equal(1)
  states(taken) |> should.equal([run.Uncertain(lost)])
  fabric.await(taken, 0)
  |> should.equal(
    Ok(
      run.Suspended([], [
        run.UncertainAction(
          run.ActionRef(fabric.id(run), ActionId(1, "a")),
          "slow",
          lost,
        ),
      ]),
    ),
  )
  restart.remove_dir(dir)
}

// --- incompatible records ------------------------------------------------------

fn transfers_need_approval(
  _context: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.tool {
    "transfer_funds" ->
      Ok(policy.RequireApproval(run.Requirement("transfer", 1)))
    _ -> Ok(policy.Allow)
  }
}

fn transfer_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

fn paying_agent(tools: List(tool.Tool(Nil))) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([transfer_call()]),
    tools,
    transfers_need_approval,
  )
  |> support.agent
}

/// A run suspended on a transfer approval, with every process gone.
fn suspended_on_disk(dir: String) -> RunId {
  let #(owner, old, run) =
    start_owned(dir, paying_agent([apps.transfer_tool()]), Nil, "pay bob")
  let assert Ok(run.Suspended([_], [])) = fabric.await(run, 5000)
  crash(owner, old, fabric.id(run))
  fabric.id(run)
}

pub fn recovery_refuses_another_agent_definition_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  let renamed =
    agent.new(
      "payments",
      scripted.plan([transfer_call()]),
      [apps.transfer_tool()],
      transfers_need_approval,
    )
    |> agent.with_version(2)
    |> support.agent
  fabric.recover(reopen(dir), renamed, Nil, id)
  |> should.equal(
    Error(
      fabric.Unreadable(
        fabric.IncompatibleAgent([run.OtherAgent(run.Identity("agent", 1))]),
      ),
    ),
  )
  restart.remove_dir(dir)
}

pub fn recovery_refuses_an_agent_without_a_pending_tool_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  fabric.recover(reopen(dir), paying_agent([apps.weather_tool()]), Nil, id)
  |> should.equal(
    Error(
      fabric.Unreadable(
        fabric.IncompatibleAgent([
          run.ToolNotRegistered(ActionId(1, "t"), "transfer_funds"),
        ]),
      ),
    ),
  )
  restart.remove_dir(dir)
}

/// The pending call's arguments no longer decode under the tool now
/// registered under its name: recovery refuses before anything runs.
pub fn recovery_refuses_a_tool_that_no_longer_accepts_pending_arguments_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  let stricter =
    tool.define(
      "transfer_funds",
      "Transfer with a memo.",
      codec.field("memo", codec.string()),
      codec.string(),
    )
    |> tool.bind(fn(_, memo) { Ok(memo) }, fn(_: Nil) { tool.Explain("no") })
  let assert Error(fabric.Unreadable(fabric.IncompatibleAgent([
    run.ArgumentsNotAccepted(id: ActionId(1, "t"), tool: "transfer_funds", ..),
  ]))) = fabric.recover(reopen(dir), paying_agent([stricter]), Nil, id)
  restart.remove_dir(dir)
}

pub fn recovery_reports_an_unsupported_record_version_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  let assert Ok(Nil) =
    restart.write_file(
      dir <> "/" <> support.text(id) <> "/99999999999999999999.json",
      "{\"format\":\"fabric.run\",\"version\":99}",
    )
  fabric.recover(reopen(dir), paying_agent([apps.transfer_tool()]), Nil, id)
  |> should.equal(Error(fabric.Unreadable(fabric.UnsupportedVersion(99))))
  restart.remove_dir(dir)
}

pub fn recovery_reports_a_corrupt_record_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  let assert Ok(Nil) =
    restart.write_file(
      dir <> "/" <> support.text(id) <> "/99999999999999999999.json",
      "{\"format\":\"fabric.run\",\"version\":1,\"run\":",
    )
  let assert Error(fabric.Unreadable(fabric.CorruptRecord(_))) =
    fabric.recover(reopen(dir), paying_agent([apps.transfer_tool()]), Nil, id)
  restart.remove_dir(dir)
}

pub fn recovery_reports_a_run_that_does_not_exist_test() {
  let dir = restart.temp_dir()
  fabric.recover(
    reopen(dir),
    paying_agent([apps.transfer_tool()]),
    Nil,
    support.id("run-nope"),
  )
  |> should.equal(Error(fabric.Unreadable(fabric.RunNotFound)))
  restart.remove_dir(dir)
}

// --- runner loss ---------------------------------------------------------------

fn one_slow(probe: Probe) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.slow("a", "a")]),
    [scripted.gated_tool(probe)],
    policy.always_allow(),
  )
  |> support.agent
}

/// Anti-oracle B5: BeamWeaver wedges a thread whose process died mid-tool.
/// Fabric reports that no runner drives the run instead of waiting, and
/// commands that would start work ask for recovery first.
pub fn a_killed_runner_is_reported_and_its_run_recovered_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(run) = fabric.start(store, one_slow(probe), Nil, "go")
  let _ = probe.arrival(probe)
  let assert Ok(runner) = restart.runner(store, fabric.id(run))
  restart.kill(runner)

  fabric.await(run, 5000) |> should.equal(Ok(run.Unattended))
  // The snapshot does not report the orphaned work as working.
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.status |> should.equal(run.Unattended)
  // The stored action is still running, so it is not reconcilable yet.
  fabric.reconcile(
    run,
    run.ActionRef(fabric.id(run), ActionId(1, "a")),
    "\"a\"",
  )
  |> should.equal(Error(fabric.NotReconcilable))

  let assert Ok(run) =
    fabric.recover(store, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [_])) = fabric.await(run, 0)
  let assert Ok(_) =
    fabric.reconcile(
      run,
      run.ActionRef(fabric.id(run), ActionId(1, "a")),
      "\"a\"",
    )
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
}

pub fn a_run_whose_runner_was_killed_can_be_cancelled_without_recovery_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(run) = fabric.start(store, one_slow(probe), Nil, "go")
  let _ = probe.arrival(probe)
  let assert Ok(runner) = restart.runner(store, fabric.id(run))
  restart.kill(runner)
  fabric.await(run, 5000) |> should.equal(Ok(run.Unattended))

  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(run) |> should.equal([run.Uncertain(lost)])
}

/// A store process that stops and is not started again within the wait is
/// `StoreUnavailable`.
pub fn await_reports_a_stopped_store_test() {
  let probe = probe.new()
  let #(owner, store) = restart.owned(support.store)
  let assert Ok(run) = fabric.start(store, one_slow(probe), Nil, "go")
  let _ = probe.arrival(probe)
  let awaited = process.new_subject()
  process.spawn(fn() { process.send(awaited, fabric.await(run, 200)) })
  restart.crash(owner, store)
  let assert Ok(Error(fabric.StoreUnavailable(_))) =
    process.receive(awaited, 5000)
}

// --- several stores over one directory ------------------------------------------

/// Both calls need an approval.
fn two_reviewed(probe: Probe) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.slow("p", "p"), scripted.slow("q", "q")]),
    [scripted.gated_tool(probe)],
    fn(_, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
  )
  |> support.agent
}

/// Store A drives the run; store B opened the same directory, and the run
/// through it. A command through B is checked against the stored record
/// first: an answer A already applied is `AlreadyAnswered`, and a valid
/// answer that B cannot apply because A's runner drives the work is
/// `RunUnattended`, not a takeover.
pub fn a_second_store_checks_commands_before_reporting_an_unknown_owner_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let a = support.directory(dir)
  let assert Ok(run_a) = fabric.start(a, two_reviewed(probe), Nil, "go")
  let assert Ok(run.Suspended([p, q], [])) = fabric.await(run_a, 5000)

  let b = reopen(dir)
  let assert Ok(run_b) =
    fabric.open(b, two_reviewed(probe), Nil, fabric.id(run_a))
  let assert Ok(run.Working) =
    fabric.approve(run_a, p.reference, reviewer: None, context: Nil)
  let started = probe.arrival(probe)
  started.name |> should.equal("p")

  fabric.approve(run_b, p.reference, reviewer: None, context: Nil)
  |> should.equal(Error(fabric.AlreadyAnswered))
  fabric.approve(run_b, q.reference, reviewer: None, context: Nil)
  |> should.equal(Error(fabric.RunUnattended))

  probe.release(started)
  let assert Ok(run.Suspended([_], [])) = fabric.await(run_a, 5000)
  let assert Ok(run.Working) =
    fabric.approve(run_b, q.reference, reviewer: None, context: Nil)
  probe.release(probe.arrival(probe))
  fabric.await(run_b, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"p\" | \"q\""))))
  probe.count(probe, "start:p") |> should.equal(1)
  restart.remove_dir(dir)
}

/// Store A drives the run; store B opens it, as a request handler would.
/// Opening takes nothing over: A's runner keeps its running tool, which
/// finishes with a definite result, and the run's incarnation is
/// unchanged. Through B the work reads `Unattended`, since B knows no
/// runner of it.
pub fn opening_a_live_run_through_another_store_leaves_it_running_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let a = support.directory(dir)
  let assert Ok(run_a) = fabric.start(a, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)

  let b = reopen(dir)
  let assert Ok(run_b) = fabric.open(b, one_slow(probe), Nil, fabric.id(run_a))
  fabric.await(run_b, 0) |> should.equal(Ok(run.Unattended))
  fabric.await(run_a, 0) |> should.equal(Ok(run.Working))
  incarnation(run_b) |> should.equal(incarnation(run_a))

  probe.release(running)
  fabric.await(run_a, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  states(run_b) |> should.equal([run.Succeeded("\"a\"")])
  probe.count(probe, "start:a") |> should.equal(1)
  restart.remove_dir(dir)
}

/// A family read as `Unattended` is read again before it is reported so:
/// here store B, which knows no runner, read the run while A's runner
/// drove it, and the run finished before the second read, which reports
/// the finished run. Only a second read that finds the family unchanged
/// is unattended (`snapshot` and command results use this rule).
pub fn a_family_that_moved_on_since_it_read_unattended_is_read_again_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let a = support.directory(dir)
  let assert Ok(run_a) = fabric.start(a, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  let b = reopen(dir)
  let id = support.text(fabric.id(run_a))
  let assert Ok(first) = family.load(b, id)
  family.status(first) |> should.equal(run.Unattended)
  let assert Ok(same) = family.settle(b, first, 3)
  family.status(same) |> should.equal(run.Unattended)

  probe.release(running)
  let assert Ok(run.Finished(_)) = fabric.await(run_a, 5000)
  let assert Ok(again) = family.settle(b, first, 3)
  family.status(again)
  |> should.equal(run.Finished(run.Completed("final: \"a\"")))
  restart.remove_dir(dir)
}

/// An id that names no stored run is `RunNotFound`, and a run of another
/// agent is `IncompatibleAgent`, as for `recover`.
pub fn opening_checks_the_run_and_its_agent_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  let store = reopen(dir)
  fabric.open(
    store,
    paying_agent([apps.transfer_tool()]),
    Nil,
    support.id("run-nope"),
  )
  |> should.equal(Error(fabric.RunNotFound))
  let assert Error(fabric.IncompatibleAgent(_)) =
    fabric.open(store, paying_agent([apps.weather_tool()]), Nil, id)
  let assert Ok(_) =
    fabric.open(store, paying_agent([apps.transfer_tool()]), Nil, id)
  restart.remove_dir(dir)
}

/// A suspended run opened after a restart is approved through the opened
/// handle: the answer is committed to the stored record and the approved
/// tool runs.
pub fn an_approval_through_an_opened_handle_runs_the_action_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(started) = fabric.start(store, two_reviewed(probe), Nil, "go")
  let assert Ok(run.Suspended([p, q], [])) = fabric.await(started, 5000)

  let assert Ok(opened) =
    fabric.open(store, two_reviewed(probe), Nil, fabric.id(started))
  let assert Ok(run.Working) =
    fabric.approve(opened, p.reference, reviewer: None, context: Nil)
  probe.release(probe.arrival(probe))
  let assert Ok(run.Suspended([_], [])) = fabric.await(opened, 5000)
  let assert Ok(_) =
    fabric.reject(opened, q.reference, reason: "no", reviewer: None)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(opened, 5000)
  probe.count(probe, "start:p") |> should.equal(1)
  probe.count(probe, "start:q") |> should.equal(0)
}

/// A run paused on a tool the current agent no longer has, or started by
/// an agent whose identity changed, cannot be recovered; it can still be
/// cancelled through the store, with no agent.
pub fn a_stranded_run_is_cancelled_without_an_agent_test() {
  let dir = restart.temp_dir()
  let id = suspended_on_disk(dir)
  let store = reopen(dir)
  let assert Error(fabric.Unreadable(fabric.IncompatibleAgent(_))) =
    fabric.recover(store, paying_agent([apps.weather_tool()]), Nil, id)

  fabric.cancel_stored(store, id)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.cancel_stored(store, id) |> should.equal(Error(fabric.RunEnded))
  fabric.cancel_stored(store, support.id("run-nope"))
  |> should.equal(Error(fabric.Unreadable(fabric.RunNotFound)))

  let assert Ok(run) =
    fabric.recover(store, paying_agent([apps.transfer_tool()]), Nil, id)
  states(run) |> should.equal([run.NotStarted])
  restart.remove_dir(dir)
}

/// A run whose runner is live in this store is cancelled through it.
pub fn cancel_stored_stops_a_live_run_through_its_runner_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(run) = fabric.start(store, one_slow(probe), Nil, "go")
  let _ = probe.arrival(probe)
  let assert Ok(run.Working) = fabric.cancel_stored(store, fabric.id(run))
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(run) |> should.equal([run.Uncertain("stopped while running")])
}

/// A record left stopping by a lost runner (a cancel was committed, then
/// the runner died before its tools were confirmed stopped): cancelling it
/// commits the ended run instead of refusing because it already ended.
pub fn cancelling_a_record_a_lost_runner_left_stopping_ends_it_test() {
  let store = support.store()
  let call = scripted.slow("a", "a")
  let stopping =
    controller.State(
      run: "run-stopping",
      agent: run.Identity("agent", 1),
      incarnation: 1,
      parent: None,
      depth: 0,
      limits: controller.Limits(
        max_turns: 8,
        token_budget: None,
        max_children: 0,
        max_depth: 0,
      ),
      turns_used: 1,
      usage: run.TokenUsage(0, 0, 0),
      transcript: [model.UserMessage("go"), model.AssistantMessage("", [call])],
      history: [],
      approvals_issued: 0,
      phase: controller.Stopping(
        1,
        [run.ActionRecord(ActionId(1, "a"), call, run.Running, [], None)],
        controller.CancelRequested,
        False,
      ),
    )
  let assert Ok(1) =
    store.insert(store, "run-stopping", record.encode(stopping), store.Keep)
  fabric.cancel_stored(store, support.id("run-stopping"))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(store.Entry(record: stored, ..)) =
    store.get(store, "run-stopping")
  let assert Ok(controller.State(phase: controller.Ended(run.Cancelled), ..)) =
    record.decode(stored)
}

/// A backend over `memory` whose insert breaks the contract: it reports
/// every run taken. With `stores` it stores the record first (a driver
/// that retried an insert whose reply was lost); without, it stores
/// nothing, and every read finds a record of someone else's.
fn taken_backend(memory: Store, stores: Bool) -> Store {
  store.new(
    process.new_name("taken-store"),
    get: fn(id) {
      case stores {
        False -> Ok(store.Stored(1, "someone else's run"))
        True ->
          store.get(memory, id)
          |> result.map(fn(entry) { store.Stored(entry.revision, entry.record) })
      }
    },
    insert: fn(id, record) {
      case stores {
        True -> {
          let _ = store.insert(memory, id, record, store.Keep)
          Nil
        }
        False -> Nil
      }
      Error(store.AlreadyExists)
    },
    compare_and_set: fn(id, expected, record) {
      store.commit(memory, id, expected, record, store.Keep)
      |> result.replace(Nil)
    },
  )
  |> support.started
}

/// A backend that stored the first record and still reported the run
/// taken: the start reads it back, finds its own record, and runs it.
pub fn a_start_the_backend_stored_despite_reporting_it_taken_runs_test() {
  let probe = probe.new()
  let runs = taken_backend(support.store(), True)
  let assert Ok(run) = fabric.start(runs, one_slow(probe), Nil, "go")
  probe.release(probe.arrival(probe))
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

/// A first write reported taken by a record the start did not write is
/// refused: the id is someone else's run, so the error does not name it,
/// and nothing of this start was stored.
pub fn a_start_whose_id_holds_another_record_is_refused_test() {
  let runs = taken_backend(support.store(), False)
  let assert Error(fabric.StartRefused(_)) =
    fabric.start(runs, one_slow(probe.new()), Nil, "go")
}

/// A start whose first write the store does not confirm names the run it
/// tried to store: the write may land later, as a run with work in flight
/// and no runner, and the caller can then end it.
pub fn an_unconfirmed_start_names_its_run_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  flaky.arm(backend, [flaky.FailLate])
  let assert Error(fabric.StartUnconfirmed(id, reason)) =
    fabric.start(runs, one_slow(probe.new()), Nil, "go")
  reason |> should.equal("the backend blinked")
  fabric.cancel_stored(runs, id)
  |> should.equal(Error(fabric.Unreadable(fabric.RunNotFound)))

  // The write lands late, before the next write of the run.
  let assert Error(store.AlreadyExists) =
    store.insert(runs, support.text(id), "{}", store.Keep)
  fabric.cancel_stored(runs, id)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
}
