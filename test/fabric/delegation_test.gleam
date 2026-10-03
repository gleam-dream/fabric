//// Sub-agents through the public API: starting a child run is an action
//// behind the parent's policy gate, a child's own approvals surface to the
//// parent, cancelling the parent cancels its children through the store,
//// and recovering the parent recovers its children. Includes BeamWeaver
//// anti-oracle row B1: a child's pause is never swallowed as a tool result.
//// Tests wait on barriers and committed statuses, never on sleeps.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/record
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run.{ActionId, Requirement}
import fabric/store.{type Store}
import fabric/support
import fabric/support/apps
import fabric/support/codecs
import fabric/support/flaky
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

// --- the application -----------------------------------------------------------

pub type Topic {
  Topic(topic: String)
}

pub type Summary {
  Summary(summary: String)
}

fn research() -> tool.Definition(Topic, Summary) {
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
        summary.summary
      })
      codec.success(Summary(summary))
    },
  )
}

fn research_call(id: String, topic: String) -> model.ToolCall {
  let assert Ok(call) = testing.call(research(), id, Topic(topic))
  call
}

/// A model that records each call in the ledger before replying.
fn recorded(
  probe: Probe,
  name: String,
  reply: fn(List(model.Message)) -> model.Reply,
) -> model.Model {
  model.new(fn(request: model.Request) {
    probe.record(probe, name <> ":model")
    Ok(reply(request.messages))
  })
}

/// The prompt a run was started with.
fn prompt(messages: List(model.Message)) -> String {
  case messages {
    [model.UserMessage(text), ..] -> text
    _ -> ""
  }
}

/// A researcher that answers at once.
fn quick_researcher_spec(probe: Probe) -> agent.Spec(Nil) {
  agent.new(
    "researcher",
    recorded(probe, "child", fn(messages) {
      model.FinalAnswer("found " <> prompt(messages), None)
    }),
    [],
    policy.always_allow(),
  )
}

fn quick_researcher(probe: Probe) -> Agent(Nil) {
  support.agent(quick_researcher_spec(probe))
}

/// A researcher that calls `tools` first (as `plan` does), then answers.
fn working_researcher(
  probe: Probe,
  calls: List(model.ToolCall),
  tools: List(tool.Tool(Nil)),
  policy: policy.Policy(Nil),
) -> Agent(Nil) {
  agent.new(
    "researcher",
    recorded(probe, "child", fn(messages) {
      case scripted.results(messages) {
        [] -> model.ToolRequest(model.AssistantTurn("", calls, None), None)
        seen -> model.FinalAnswer("found " <> string.join(seen, ","), None)
      }
    }),
    tools,
    policy,
  )
  |> support.agent
}

fn delegating_spec(
  probe: Probe,
  calls: List(model.ToolCall),
  child: Agent(Nil),
  policy: policy.Policy(Nil),
) -> agent.Spec(Nil) {
  named_delegating_spec("agent", probe, calls, child, policy)
}

fn named_delegating_spec(
  name: String,
  probe: Probe,
  calls: List(model.ToolCall),
  child: Agent(Nil),
  policy: policy.Policy(Nil),
) -> agent.Spec(Nil) {
  agent.new(
    name,
    recorded(probe, "parent", fn(messages) {
      case scripted.results(messages) {
        [] -> model.ToolRequest(model.AssistantTurn("", calls, None), None)
        seen -> model.FinalAnswer("final: " <> string.join(seen, " | "), None)
      }
    }),
    [],
    policy,
  )
  |> agent.with_sub_agent(
    research(),
    to: child,
    prompt: fn(topic: Topic) { topic.topic },
    output: fn(text) { Ok(Summary(text)) },
  )
}

fn delegating(
  probe: Probe,
  calls: List(model.ToolCall),
  child: Agent(Nil),
  policy: policy.Policy(Nil),
) -> Agent(Nil) {
  support.agent(delegating_spec(probe, calls, child, policy))
}

/// Starting a sub-agent needs an approval; tools do not.
fn review_delegation(
  probe: Probe,
) -> fn(Nil, policy.Action) -> Result(policy.Decision, String) {
  fn(_, action: policy.Action) {
    case action.target {
      policy.StartAgent(name, version) -> {
        probe.record(
          probe,
          "gate:"
            <> name
            <> "/"
            <> string.inspect(version)
            <> ":"
            <> action.tool,
        )
        Ok(policy.RequireApproval(Requirement("delegate", 1)))
      }
      policy.InvokeTool -> Ok(policy.Allow)
    }
  }
}

fn transfers_need_approval(
  _: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.tool {
    "transfer_funds" -> Ok(policy.RequireApproval(Requirement("transfer", 1)))
    _ -> Ok(policy.Allow)
  }
}

/// A transfer tool that records each payment.
fn paying_tool(probe: Probe) -> tool.Tool(Nil) {
  tool.bind(
    apps.transfer_definition(),
    fn(_, _call, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay:" <> transfer.to)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn transfer_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

// --- instruments ---------------------------------------------------------------

fn start_owned(
  dir: String,
  agent: Agent(Nil),
  prompt: String,
) -> #(Pid, Store, fabric.Run(Nil)) {
  let #(owner, #(store, run)) =
    restart.owned(fn() {
      let store = support.directory(dir)
      let assert Ok(run) =
        fabric.start(
          store,
          agent,
          id: run.new_id(),
          context: Nil,
          prompt: prompt,
          correlation: None,
        )
      #(store, run)
    })
  #(owner, store, run)
}

fn crash(owner: Pid, store: Store) -> Nil {
  restart.crash(owner, store)
}

fn reopen(dir: String) -> Store {
  let store = support.directory(dir)
  store
}

fn only_action(run: fabric.Run(Nil)) -> run.ActionRecord {
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [action] = snapshot.actions
  action
}

fn child_of(run: fabric.Run(Nil)) -> fabric.Run(Nil) {
  let assert Some(id) = only_action(run).child
  let assert Ok(child) = fabric.child(run, id)
  child
}

fn child_states(child: fabric.Run(Nil)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(child)
  list.map(snapshot.actions, fn(action) { action.state })
}

const lost = "the runner was lost while the tool ran; its effect may have happened"

// --- approval before start -----------------------------------------------------

/// The parent's policy sees the start of a sub-agent as an action with its
/// target, and requires an approval. Until it is approved no child record
/// exists, also across a restart; once approved, the child runs as its own
/// run and its result is the parent's tool result.
pub fn a_sub_agent_starts_only_after_approval_even_across_a_restart_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let parent =
    delegating(
      probe,
      [research_call("r", "gleam")],
      quick_researcher(probe),
      review_delegation(probe),
    )
  let #(owner, old, run) = start_owned(dir, parent, "look it up")
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  pending.tool |> should.equal("research")
  pending.reference.run |> should.equal(fabric.id(run))
  only_action(run).child |> should.equal(None)
  restart.list_dir(dir) |> should.equal(Ok([support.text(fabric.id(run))]))
  crash(owner, old)

  let assert Ok(run) = fabric.recover(reopen(dir), parent, Nil, fabric.id(run))
  fabric.pending(run) |> should.equal(Ok([pending]))
  restart.list_dir(dir) |> should.equal(Ok([support.text(fabric.id(run))]))
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: reviewer.new("reviewer"),
      context: Nil,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"found gleam\"}"))),
  )

  let action = only_action(run)
  action.state |> should.equal(run.Succeeded("{\"summary\":\"found gleam\"}"))
  let assert Some(child_id) = action.child
  let assert Ok(child) = fabric.child(run, child_id)
  let assert Ok(snapshot) = fabric.snapshot(child)
  snapshot.agent |> should.equal(run.DefinitionId("researcher", 1))
  snapshot.parent
  |> should.equal(Some(run.AgentParent(fabric.id(run), ActionId(1, "r"))))
  snapshot.status |> should.equal(run.Finished(run.Completed("found gleam")))
  probe.entries(probe)
  |> should.equal([
    "parent:model", "gate:researcher/1:research", "gate:researcher/1:research",
    "child:model", "parent:model",
  ])
  restart.remove_dir(dir)
}

/// A rejected start never creates the child; the model sees the rejection.
pub fn a_rejected_sub_agent_never_starts_test() {
  let probe = probe.new()
  let parent =
    delegating(
      probe,
      [research_call("r", "gleam")],
      quick_researcher(probe),
      review_delegation(probe),
    )
  let assert Ok(run) =
    fabric.start(
      support.store(),
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) =
    fabric.reject(
      run,
      pending.reference,
      reason: "not today",
      reviewer: reviewer.new("ann"),
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "final: {\"error\":\"rejected\",\"detail\":\"not today\"}",
      )),
    ),
  )
  only_action(run).child |> should.equal(None)
  probe.count(probe, "child:model") |> should.equal(0)
}

// --- a child's own approvals ----------------------------------------------------

/// A parent whose researcher pays, and the researcher's payments need an
/// approval.
fn paying_family(probe: Probe) -> Agent(Nil) {
  delegating(
    probe,
    [research_call("r", "gleam")],
    working_researcher(
      probe,
      [transfer_call()],
      [paying_tool(probe)],
      transfers_need_approval,
    ),
    policy.always_allow(),
  )
}

/// Anti-oracle B1: BeamWeaver turns a sub-agent's pause into a tool result
/// and lets the parent finish. Here the child's pending approval is the
/// parent's pending approval, with a reference that names the child run;
/// the parent does not continue until it is answered through the parent,
/// and the child's completion then feeds the parent's waiting action.
pub fn a_child_pause_surfaces_to_the_parent_and_is_answered_through_it_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      paying_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Some(child_id) = only_action(run).child
  pending.reference.run |> should.equal(child_id)
  pending.tool |> should.equal("transfer_funds")
  fabric.pending(run) |> should.equal(Ok([pending]))
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Suspended([pending], [])))
  only_action(run).state |> should.equal(run.Delegated)
  probe.count(probe, "parent:model") |> should.equal(1)
  probe.count(probe, "pay:bob") |> should.equal(0)

  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: reviewer.new("reviewer"),
      context: Nil,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "final: {\"summary\":\"found {\\\"receipt\\\":\\\"r-bob\\\"}\"}",
      )),
    ),
  )
  probe.count(probe, "pay:bob") |> should.equal(1)
  fabric.approve(
    run,
    pending.reference,
    reviewer: reviewer.new("reviewer"),
    context: Nil,
  )
  |> should.equal(Error(fabric.AlreadyAnswered))
}

// --- cancellation ---------------------------------------------------------------

/// Cancelling the parent cancels its paused child through the store: no
/// process holds either run. The child's pending approval is void.
pub fn cancelling_the_parent_cancels_a_paused_child_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      paying_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let child = child_of(run)

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  child_states(child) |> should.equal([run.NotStarted])
  only_action(run).state
  |> should.equal(run.ToolFailed("{\"error\":\"the sub-agent was cancelled\"}"))
  fabric.approve(
    run,
    pending.reference,
    reviewer: reviewer.new("reviewer"),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// Cancelling the parent while its child runs a tool stops that tool; the
/// child's effect is unknown, so the parent's action is uncertain whatever
/// the application's mapping would say.
pub fn cancelling_the_parent_stops_an_active_child_test() {
  let probe = probe.new()
  let parent =
    delegating(
      probe,
      [research_call("r", "gleam")],
      working_researcher(
        probe,
        [scripted.slow("s", "s")],
        [scripted.gated_tool(probe)],
        policy.always_allow(),
      ),
      policy.always_allow(),
    )
  let assert Ok(run) =
    fabric.start(
      support.store(),
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  running.name |> should.equal("s")
  let child = child_of(run)

  let assert Ok(run.Working) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  child_states(child) |> should.equal([run.Uncertain("stopped while running")])
  let assert run.Uncertain(evidence) = only_action(run).state
  string.contains(evidence, support.text(fabric.id(child))) |> should.be_true
  probe.count(probe, "end:s") |> should.equal(0)
}

/// A child's model reply that would arrive after the parent was cancelled
/// is never recorded: the child ends cancelled, its model call aborted, and
/// the parent's model is not called again.
pub fn a_child_reply_after_the_parent_was_cancelled_is_discarded_test() {
  let probe = probe.new()
  let slow_child =
    agent.new(
      "agent",
      model.new(fn(_) {
        probe.gate(probe, "child-model")
        Ok(model.FinalAnswer("too late", None))
      }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let parent =
    delegating(
      probe,
      [research_call("r", "gleam")],
      slow_child,
      policy.always_allow(),
    )
  let assert Ok(run) =
    fabric.start(
      support.store(),
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let replying = probe.arrival(probe)
  let child = child_of(run)
  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.release(replying)
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  only_action(run).state
  |> should.equal(run.ToolFailed("{\"error\":\"the sub-agent was cancelled\"}"))
  probe.count(probe, "parent:model") |> should.equal(1)
}

// --- restart --------------------------------------------------------------------

/// Every process is lost while the child runs a tool. Recovering the parent
/// recovers the child: its running tool is an uncertain effect of the
/// child, reported through the parent and reconciled on the child's handle;
/// the child then completes and feeds the parent.
pub fn recovering_the_parent_recovers_its_child_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let parent =
    delegating(
      probe,
      [research_call("r", "gleam")],
      working_researcher(
        probe,
        [scripted.slow("s", "s")],
        [scripted.gated_tool(probe)],
        policy.always_allow(),
      ),
      policy.always_allow(),
    )
  let #(owner, old, run) = start_owned(dir, parent, "go")
  let _ = probe.arrival(probe)
  let child_id = case only_action(run).child {
    Some(id) -> id
    None -> panic as "the child was not linked"
  }
  crash(owner, old)

  let assert Ok(run) = fabric.recover(reopen(dir), parent, Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(
    Ok(
      run.Suspended([], [
        run.UncertainAction(
          run.ActionRef(child_id, ActionId(1, "s")),
          "slow",
          lost,
        ),
      ]),
    ),
  )
  let assert Ok(child) = fabric.child(run, child_id)
  let assert Ok(_) =
    fabric.reconcile(
      child,
      run.ActionRef(fabric.id(child), ActionId(1, "s")),
      "\"s\"",
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"found \\\"s\\\"\"}"))),
  )
  probe.count(probe, "start:s") |> should.equal(1)
  restart.remove_dir(dir)
}

/// A child's uncertain effect surfaces in the parent's status with a
/// reference naming the child, and is reconciled through the parent's
/// handle.
pub fn a_child_effect_is_reconciled_through_the_parent_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let parent =
    delegating(
      probe,
      [research_call("r", "gleam")],
      working_researcher(
        probe,
        [scripted.slow("s", "s")],
        [scripted.gated_tool(probe)],
        policy.always_allow(),
      ),
      policy.always_allow(),
    )
  let #(owner, old, run) = start_owned(dir, parent, "go")
  let _ = probe.arrival(probe)
  crash(owner, old)

  let assert Ok(run) = fabric.recover(reopen(dir), parent, Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(0))
  { uncertain.reference.run != fabric.id(run) } |> should.be_true
  let assert Ok(_) = fabric.reconcile(run, uncertain.reference, "\"s\"")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"found \\\"s\\\"\"}"))),
  )
  probe.count(probe, "start:s") |> should.equal(1)
  restart.remove_dir(dir)
}

/// A child record that cannot be read after a restart has an unknown
/// effect: the parent's action becomes uncertain and is reconciled on the
/// parent.
pub fn an_unreadable_child_is_an_uncertain_effect_of_the_parent_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(owner, old, run) = start_owned(dir, paying_family(probe), "go")
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  crash(owner, old)
  let assert Ok(Nil) =
    restart.write_file(
      dir
        <> "/"
        <> support.text(pending.reference.run)
        <> "/99999999999999999999.json",
      "{\"format\":\"fabric.run\",\"version\":2,\"run\":",
    )

  let assert Ok(run) =
    fabric.recover(reopen(dir), paying_family(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(0))
  uncertain.reference.run |> should.equal(fabric.id(run))
  uncertain.tool |> should.equal("research")
  string.contains(uncertain.evidence, support.text(pending.reference.run))
  |> should.be_true
  let assert Ok(_) =
    fabric.reconcile(run, uncertain.reference, "{\"summary\":\"unknown\"}")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"unknown\"}"))),
  )
  restart.remove_dir(dir)
}

// --- budgets --------------------------------------------------------------------

/// At most `max_children` child runs per run: a delegation beyond it is
/// refused before the policy, and the model sees why.
pub fn delegations_beyond_the_child_limit_are_refused_test() {
  let probe = probe.new()
  let parent =
    delegating_spec(
      probe,
      [
        research_call("a", "one"),
        research_call("b", "two"),
        research_call("c", "three"),
      ],
      quick_researcher(probe),
      policy.always_allow(),
    )
    |> agent.with_max_children(2)
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
  |> should.equal([
    run.Succeeded("{\"summary\":\"found one\"}"),
    run.Succeeded("{\"summary\":\"found two\"}"),
    run.LimitReached(run.ChildLimit(2)),
  ])
  probe.count(probe, "child:model") |> should.equal(2)
}

/// A child that delegates in turn: by default a run's children may not
/// start their own (depth 1), and a root whose `Limits.max_depth` is 2
/// allows it.
pub fn nested_delegation_is_bounded_by_the_root_depth_test() {
  let probe = probe.new()
  let middle =
    named_delegating_spec(
      "middle",
      probe,
      [research_call("m", "deeper")],
      quick_researcher(probe),
      policy.always_allow(),
    )
    |> support.agent
  let root = fn(max_depth) {
    agent.new(
      "agent",
      scripted.plan([research_call("r", "gleam")]),
      [],
      policy.always_allow(),
    )
    |> agent.with_sub_agent(
      research(),
      to: middle,
      prompt: fn(topic: Topic) { topic.topic },
      output: fn(text) { Ok(Summary(text)) },
    )
    |> agent.with_max_depth(max_depth)
    |> support.agent
  }

  let assert Ok(shallow) =
    fabric.start(
      support.store(),
      root(1),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(shallow, within: duration.milliseconds(5000))
  let assert Ok(snapshot) = fabric.snapshot(child_of(shallow))
  list.map(snapshot.actions, fn(action) { action.state })
  |> should.equal([run.LimitReached(run.DepthLimit(1))])

  let assert Ok(deep) =
    fabric.start(
      support.store(),
      root(2),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(deep, within: duration.milliseconds(5000))
  let assert Ok(snapshot) = fabric.snapshot(child_of(deep))
  list.map(snapshot.actions, fn(action) { action.state })
  |> should.equal([run.Succeeded("{\"summary\":\"found deeper\"}")])
}

// --- configuration --------------------------------------------------------------

pub fn a_delegation_is_validated_with_its_child_test() {
  let probe = probe.new()
  // A sub-agent is checked by its own build, so an invalid one can never
  // be delegated to.
  quick_researcher_spec(probe)
  |> agent.with_max_turns(0)
  |> agent.build
  |> should.equal(
    Error([agent.InvalidLimit(agent.MaxTurns, 0, 1, 9_007_199_254_740_991)]),
  )
  delegating_spec(probe, [], quick_researcher(probe), policy.always_allow())
  |> agent.with_max_children(-1)
  |> agent.build
  |> should.equal(Error([agent.InvalidLimit(agent.MaxChildren, -1, 0, 999)]))
  agent.new(
    "agent",
    scripted.plan([]),
    [apps.weather_tool()],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(
    tool.define(
      "lookup_weather",
      "Clashes with the tool.",
      codecs.one_field("city", codec.string()),
      codec.string(),
    ),
    to: quick_researcher(probe),
    prompt: fn(city) { city },
    output: fn(_) { Ok("") },
  )
  |> agent.build
  |> should.equal(Error([agent.DuplicateToolName("lookup_weather")]))
}

/// A child run's id extends its parent's by a sequence number, and run ids
/// are at most 128 characters: nesting and child counts are bounded so
/// that every child id the limits allow is a valid run id.
pub fn delegation_limits_keep_child_ids_valid_test() {
  let probe = probe.new()
  let limited = fn(max_children, max_depth) {
    delegating_spec(probe, [], quick_researcher(probe), policy.always_allow())
    |> agent.with_max_children(max_children)
    |> agent.with_max_depth(max_depth)
    |> agent.build
  }
  limited(1000, 17)
  |> should.equal(
    Error([
      agent.InvalidLimit(agent.MaxChildren, 1000, 0, 999),
      agent.InvalidLimit(agent.MaxDepth, 17, 0, 16),
    ]),
  )
  let assert Ok(_) = limited(999, 16)
}

/// With no agent, `cancel_stored` cancels a paused child first and then its
/// parent in one commit; the delegation is recorded uncertain, since no
/// agent maps the child's outcome.
pub fn cancel_stored_cancels_the_children_first_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(run) =
    fabric.start(
      store,
      paying_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let child = child_of(run)
  fabric.cancel_stored(store, fabric.id(run))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(_) = only_action(run).state
  fabric.approve(
    run,
    pending.reference,
    reviewer: reviewer.new("reviewer"),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
}

// --- cancellation under store faults ------------------------------------------

/// The child's cancellation commit fails once: the parent's cancellation
/// tries again, so the child still ends cancelled, the parent ends, and the
/// child's approval can no longer be answered.
pub fn a_transient_store_failure_does_not_leave_a_child_uncancelled_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      paying_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let child = child_of(run)
  flaky.arm_run(backend, fabric.id(child), [flaky.FailBefore])

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.pending(run) |> should.equal(Ok([]))
  fabric.approve(
    run,
    pending.reference,
    reviewer: reviewer.new("reviewer"),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// The child cannot be cancelled at all: the parent still ends, its
/// delegation is an uncertain effect naming the failure, and the child's
/// approval is refused through the parent and through the child's own
/// handle, because cancelling an ancestor wins over answering a
/// descendant.
pub fn a_child_that_cannot_be_cancelled_can_no_longer_act_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      paying_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let child = child_of(run)
  flaky.arm_run(backend, fabric.id(child), list.repeat(flaky.FailBefore, 64))

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(evidence) = only_action(run).state
  string.contains(evidence, "could not be cancelled") |> should.be_true
  fabric.approve(
    run,
    pending.reference,
    reviewer: reviewer.new("reviewer"),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
  fabric.approve(
    child,
    pending.reference,
    reviewer: reviewer.new("reviewer"),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// The twin of the approval case for a reconciliation: the child is
/// suspended on an effect of unknown status and cannot be cancelled at
/// all. The parent still ends, and the child's effect is refused through
/// the parent and through the child's own handle with `RunEnded`, because
/// cancelling an ancestor wins over reconciling a descendant.
pub fn a_child_that_cannot_be_cancelled_can_no_longer_be_reconciled_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let family =
    delegating(
      probe,
      [research_call("r", "gleam")],
      working_researcher(
        probe,
        [
          scripted.call(
            "t",
            "transfer_funds",
            "{\"to\":\"bob\",\"amount\":5000}",
          ),
        ],
        [apps.transfer_tool()],
        policy.always_allow(),
      ),
      policy.always_allow(),
    )
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      family,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let child = child_of(run)
  uncertain.reference.run |> should.equal(fabric.id(child))
  flaky.arm_run(backend, fabric.id(child), list.repeat(flaky.FailBefore, 64))

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(evidence) = only_action(run).state
  string.contains(evidence, "could not be cancelled") |> should.be_true
  fabric.reconcile(run, uncertain.reference, "{\"receipt\":\"r-1\"}")
  |> should.equal(Error(fabric.RunEnded))
  fabric.reconcile(child, uncertain.reference, "{\"receipt\":\"r-1\"}")
  |> should.equal(Error(fabric.RunEnded))
}

/// A family whose child pays as soon as it runs.
fn eager_family(probe: Probe) -> Agent(Nil) {
  delegating(
    probe,
    [research_call("r", "gleam")],
    working_researcher(
      probe,
      [transfer_call()],
      [paying_tool(probe)],
      policy.always_allow(),
    ),
    policy.always_allow(),
  )
}

/// Whether `run` is the first child run of some run.
fn first_child(run: String) -> Bool {
  string.ends_with(run, "-1")
}

/// A cancellation through another store while the parent's runner is
/// storing its child finds no child, and leaves a cancelled record in its
/// place: the child the runner stores afterwards is refused and never runs.
pub fn a_child_stored_after_its_parent_was_cancelled_never_runs_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let held = flaky.hold(backend, first_child)
  let owner = flaky.store(backend)
  let assert Ok(run) =
    fabric.start(
      owner,
      eager_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(child_id) = process.receive(held, 5000)
  let assert Ok(runner) = restart.runner(owner, fabric.id(run))
  let runner_exit = process.monitor(runner)

  fabric.cancel_stored(flaky.store(backend), fabric.id(run))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  flaky.release_held(backend)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(runner_exit, fn(down) { down })
    |> process.selector_receive(5000)

  let assert Ok(child) = fabric.child(run, support.id(child_id))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  only_action(run).state |> should.equal(run.NotStarted)
  probe.count(probe, "child:model") |> should.equal(0)
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// Recovery reattaches a delegation whose child was never stored while a
/// cancellation through another store runs: the child recovery stores
/// afterwards finds the canceller's record and never runs.
pub fn recovery_does_not_start_a_child_after_its_parent_was_cancelled_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let held = flaky.hold(backend, first_child)
  let #(owner, #(first, run)) =
    restart.owned(fn() {
      let store = flaky.store(backend)
      let assert Ok(run) =
        fabric.start(
          store,
          eager_family(probe),
          id: run.new_id(),
          context: Nil,
          prompt: "go",
          correlation: None,
        )
      #(store, run)
    })
  let assert Ok(_) = process.receive(held, 5000)
  crash(owner, first)
  flaky.drop_held(backend)

  let held = flaky.hold(backend, first_child)
  let second = flaky.store(backend)
  let id = fabric.id(run)
  let recovering = process.new_subject()
  process.spawn(fn() {
    process.send(
      recovering,
      fabric.recover(second, eager_family(probe), Nil, id),
    )
  })
  let assert Ok(child_id) = process.receive(held, 5000)
  fabric.cancel_stored(flaky.store(backend), id)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  flaky.release_held(backend)
  let assert Ok(Ok(recovered)) = process.receive(recovering, 5000)

  let assert Ok(child) = fabric.child(recovered, support.id(child_id))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  only_action(recovered).state |> should.equal(run.NotStarted)
  probe.count(probe, "child:model") |> should.equal(0)
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// Storing a child fails once: the runner tries again, and the child runs.
pub fn a_child_whose_first_insert_fails_still_starts_test() {
  let probe = probe.new()
  let backend = flaky.new()
  flaky.arm_where(backend, first_child, [flaky.FailBefore])
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      eager_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(run, within: duration.milliseconds(5000))
  probe.count(probe, "pay:bob") |> should.equal(1)
}

/// The child's first insert is reported unavailable and lands only
/// afterwards, so the retried insert finds it already stored: the child has
/// no runner yet, and the start takes it over instead of waiting for a
/// recovery.
pub fn a_child_whose_insert_lands_late_still_runs_test() {
  let probe = probe.new()
  let backend = flaky.new()
  flaky.arm_where(backend, first_child, [flaky.FailLate])
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      eager_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(run, within: duration.milliseconds(5000))
  probe.count(probe, "pay:bob") |> should.equal(1)
}

/// Another writer stored the child's identical first record, with its own
/// write token: the start does not take that record for its own, and
/// recovers it as a new incarnation rather than making its first model
/// call as the same one.
pub fn an_identical_child_record_by_another_writer_is_recovered_test() {
  let probe = probe.new()
  let backend = flaky.new()
  flaky.arm_where(backend, first_child, [flaky.StoredByAnother])
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      eager_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(store_core.Entry(record: stored, ..)) =
    store_core.get(flaky.store(backend), support.text(fabric.id(run)) <> "-1")
  let assert Ok(child) = record.decode(stored)
  child.incarnation |> should.equal(2)
  probe.count(probe, "pay:bob") |> should.equal(1)
}

/// A child that cannot be stored at all is not reported started: the
/// delegation is an uncertain effect naming the failure.
pub fn a_child_that_cannot_be_stored_is_uncertain_test() {
  let probe = probe.new()
  let backend = flaky.new()
  flaky.arm_where(backend, first_child, list.repeat(flaky.FailBefore, 64))
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      eager_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(5000))
  string.contains(uncertain.evidence, "could not be stored")
  |> should.be_true
  probe.count(probe, "child:model") |> should.equal(0)
}

/// The run is reopened under an agent whose `research` is a plain tool, not
/// a delegation. Cancelling it still cancels the child it started: the
/// child's end is applied with no delegation to map it, so the action is
/// uncertain, and the family ends.
pub fn cancelling_does_not_depend_on_the_current_delegations_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(run) =
    fabric.start(
      store,
      paying_family(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let child = child_of(run)
  let plain =
    agent.new(
      "agent",
      scripted.plan([]),
      [
        research()
        |> tool.bind(
          fn(_, _call, topic: Topic) { Ok(Summary(topic.topic)) },
          fn(_: Nil) { tool.Explain("no") },
        ),
      ],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(reopened) = fabric.recover(store, plain, Nil, fabric.id(run))

  let assert Ok(_) = fabric.cancel(reopened)
  fabric.await(reopened, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(child, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(_) = only_action(run).state
  probe.count(probe, "pay:bob") |> should.equal(0)
}
