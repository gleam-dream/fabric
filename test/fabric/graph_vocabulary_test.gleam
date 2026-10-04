//// The graph runtime speaks the agent runtime's vocabulary (wave 5, slice
//// F5): one `policy.Action`, one `tool.Failure`, approvals answered with a
//// typed reviewer and the current context that expire after 7 days by the
//// store's clock, waits bounded by default, the context built from the run
//// id, a correlation carried into operations, children and events, and one
//// classified `graph.Error`.

import fabric
import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/clock
import fabric/internal/graph/compiled
import fabric/internal/graph/runner
import fabric/internal/graph/runtime as graph_runtime
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/store/discovery
import fabric/support
import fabric/support/nodes
import fabric/sweeper
import fabric/telemetry as o
import fabric/testing
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal
import sinal/correlation

const day = 86_400_000

fn publish(
  body: fn(String, operation.Invocation, Int) -> Result(Int, Nil),
) -> definition.Definition(String, Int, Int) {
  let id = definition.node_id("publish")
  let op =
    operation.new(
      run.DefinitionId("publish-post", 2),
      codec.int(),
      codec.int(),
      body,
      fn(_) { tool.Uncertain("the publisher did not answer") },
    )
  let node =
    definition.node(
      id,
      op,
      select: fn(n) { Ok(n) },
      accept: fn(_, n) { Ok(definition.Finish(n, n)) },
      destinations: [],
    )
  let assert Ok(graph) =
    definition.build(definition.new(
      run.DefinitionId("publishing", 1),
      entry: id,
      nodes: [node],
      state: codec.int(),
      answer: codec.int(),
    ))
  graph
}

/// A runtime whose policy reports every action and context it sees and
/// requires the approval `publish` for the operation.
fn gated(
  runs: store.Store,
  seen: Subject(#(policy.Action, String)),
  body: fn(String, operation.Invocation, Int) -> Result(Int, Nil),
) -> graph.Runtime(String, Int, Int) {
  gated_spec(runs, seen, body)
  |> graph.with_approvers(testing.trusting_approvers())
  |> graph.build
  |> should.be_ok
}

fn gated_spec(
  runs: store.Store,
  seen: Subject(#(policy.Action, String)),
  body: fn(String, operation.Invocation, Int) -> Result(Int, Nil),
) -> graph.Spec(String, Int, Int) {
  graph.new(
    publish(body),
    runs,
    context: fn(id) { "runtime:" <> run.id_to_string(id) },
    policy: fn(context, action) {
      process.send(seen, #(action, context))
      Ok(policy.RequireApproval(run.Requirement("publish", 1)))
    },
  )
}

fn doubled(_context, _invocation, n) {
  Ok(n * 2)
}

fn alice() -> reviewer.Reviewer {
  let assert Ok(alice) =
    reviewer.new("alice") |> result.try(reviewer.with_issuer(_, "https://id"))
  alice
}

// --- policy and context ---------------------------------------------------------

pub fn the_policy_sees_one_action_shape_and_the_approver_context_runs_test() {
  let seen = process.new_subject()
  let bodies = process.new_subject()
  let runtime =
    gated(support.store(), seen, fn(context, invocation, n) {
      process.send(bodies, #(context, invocation))
      Ok(n * 2)
    })
  let id = support.id("vocabulary-policy")
  let assert Ok(handle) =
    graph.start(runtime, id: id, initial: 21, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingApproval(pending) = waiting.status
  let assert Ok(#(action, context)) = process.receive(seen, 30_000)
  action
  |> should.equal(policy.Action(
    run: id,
    step: policy.Activation(1, 1),
    name: "publish-post",
    arguments_json: "21",
    target: policy.RunOperation(
      "publish",
      run.DefinitionId("publish-post", 2),
      policy.Activity,
    ),
  ))
  context |> should.equal("runtime:vocabulary-policy")
  waiting.current |> should.equal(Some(action))
  // The answer is checked again, and runs, with the approver's context.
  let assert Ok(_) =
    graph.approve(
      handle,
      pending,
      proof: support.proof(pending.requirement, alice()),
      context: "approver",
    )
  let assert Ok(#(_, recheck)) = process.receive(seen, 30_000)
  recheck |> should.equal("approver")
  let assert Ok(#(body_context, invocation)) = process.receive(bodies, 30_000)
  body_context |> should.equal("approver")
  invocation.correlation
  |> should.equal(correlation.from_key("vocabulary-policy"))
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(42))
  // Who approved is stored with the activation's receipt.
  let assert [receipt] = done.receipts
  let assert [run.Approval(answer: run.Approve, reviewer: Some(who), ..)] =
    receipt.approvals
  who |> should.equal(alice())
}

pub fn a_rejection_records_its_reviewer_and_a_second_answer_is_refused_test() {
  let seen = process.new_subject()
  let handle = started(support.store(), seen, "vocabulary-reject")
  let assert Ok(waiting) = graph.await(handle, within: duration.seconds(5))
  let assert graph.AwaitingApproval(pending) = waiting
  let assert Ok(_) =
    graph.reject(
      handle,
      pending,
      proof: support.proof(pending.requirement, alice()),
      reason: "not today",
    )
  let assert Ok(rejected) = graph.snapshot(handle)
  rejected.status |> should.equal(graph.Failed(graph.Denied("not today")))
  let assert [
    run.Approval(answer: run.Reject("not today"), reviewer: Some(_), ..),
  ] = rejected.approvals
  graph.approve(
    handle,
    pending,
    proof: support.proof(pending.requirement, alice()),
    context: "late",
  )
  |> should.equal(Error(graph.AlreadyAnswered))
  graph.reject(
    handle,
    graph.ApprovalRef(..pending, run: support.id("other")),
    proof: support.proof(
      graph.ApprovalRef(..pending, run: support.id("other")).requirement,
      alice(),
    ),
    reason: "x",
  )
  |> should.equal(Error(graph.WrongReference))
}

fn started(
  runs: store.Store,
  seen: Subject(#(policy.Action, String)),
  name: String,
) -> graph.Handle(String, Int, Int) {
  let assert Ok(handle) =
    graph.start(
      gated(runs, seen, doubled),
      id: support.id(name),
      initial: 21,
      correlation: None,
    )
  handle
}

// --- approval expiry ------------------------------------------------------------

pub fn approval_requests_expire_after_seven_days_by_the_store_clock_test() {
  let memory = conformance.leased_memory()
  // The store's clock runs a day ahead of this node's.
  memory.advance(day)
  let runs = nodes.node(memory.backend, "graph-expiry", nodes.long)
  let seen = process.new_subject()
  let handle = started(runs, seen, "vocabulary-default-expiry")
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingApproval(pending) = waiting.status
  let assert Some(expires) = waiting.deadline
  { expires >= clock.now() + 8 * day - 60_000 } |> should.be_true
  // The sweeper finds it when it is due.
  let assert Ok(row) = memory.backend.get("vocabulary-default-expiry")
  let assert Ok(Some(discovery.Wait(trigger: discovery.At(due), ..))) =
    discovery.inspect(row.record)
  due |> should.equal(expires)
  // Past the store's deadline, an answer is refused and the run fails.
  memory.advance(7 * day)
  graph.approve(
    handle,
    pending,
    proof: support.proof(pending.requirement, alice()),
    context: "late",
  )
  |> should.equal(Error(graph.ApprovalExpired))
  let assert Ok(failed) = graph.snapshot(handle)
  failed.status |> should.equal(graph.Failed(graph.ExpiredApproval(expires)))
  let assert [run.Approval(answer: run.Expired, reviewer: None, ..)] =
    failed.approvals
}

pub fn await_and_recovery_expire_a_due_request_and_infinity_never_does_test() {
  let seen = process.new_subject()
  let runs = support.store()
  let quick =
    gated_spec(runs, seen, doubled)
    |> graph.with_approval_expiry(run.After(duration.milliseconds(20)))
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  let assert Ok(handle) =
    graph.start(
      quick,
      id: support.id("vocabulary-quick"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(waiting) = graph.await(handle, within: duration.seconds(5))
  let assert graph.AwaitingApproval(_) = waiting
  process.sleep(30)
  let assert Ok(expired) = graph.await(handle, within: duration.seconds(5))
  let assert graph.Failed(graph.ExpiredApproval(_)) = expired
  // A second run expires through recovery.
  let assert Ok(second) =
    graph.start(
      quick,
      id: support.id("vocabulary-quick-2"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(second, within: duration.seconds(5))
  process.sleep(30)
  let assert Ok(recovered) = graph.recover(second)
  let assert graph.Failed(graph.ExpiredApproval(_)) = recovered
  // Without a deadline the request waits.
  let forever =
    gated_spec(runs, seen, doubled)
    |> graph.with_approval_expiry(run.Infinity)
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  let assert Ok(patient) =
    graph.start(
      forever,
      id: support.id("vocabulary-forever"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(patient, within: duration.seconds(5))
  let assert Ok(waiting) = graph.snapshot(patient)
  let assert graph.AwaitingApproval(_) = waiting.status
  waiting.deadline |> should.equal(None)
}

pub fn the_sweeper_expires_a_due_graph_approval_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "graph-sweeper-expiry", nodes.long)
  let seen = process.new_subject()
  let build = fn(runs) {
    gated_spec(runs, seen, doubled)
    |> graph.with_approval_expiry(run.After(duration.minutes(1)))
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  }
  let assert Ok(handle) =
    graph.start(
      build(runs),
      id: support.id("vocabulary-swept"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(waiting) = graph.await(handle, within: duration.seconds(5))
  let assert graph.AwaitingApproval(_) = waiting
  memory.advance(61_000)
  let assert Ok(pid) =
    sweeper.start(
      runs,
      [sweeper.graph(run.DefinitionId("publishing", 1), build:)],
      every: duration.milliseconds(20),
    )
  let assert Ok(failed) = until_failed(handle, 1500)
  let assert graph.Failed(graph.ExpiredApproval(_)) = failed.status
  process.unlink(pid)
  process.kill(pid)
}

fn until_failed(handle, tries: Int) {
  let assert Ok(snapshot) = graph.snapshot(handle)
  case snapshot.status, tries {
    graph.Failed(_), _ | _, 0 -> Ok(snapshot)
    _, _ -> {
      process.sleep(20)
      until_failed(handle, tries - 1)
    }
  }
}

// --- waits ----------------------------------------------------------------------

fn waiting(
  within: option.Option(run.Timeout),
) -> definition.Definition(Nil, Int, Int) {
  let id = definition.node_id("wait")
  let wait = operation.await_signal(codec.int(), ready())
  let wait = case within {
    None -> wait
    Some(within) -> operation.with_deadline(wait, within)
  }
  let assert Ok(graph) =
    definition.build(definition.new(
      run.DefinitionId("waiting", 1),
      entry: id,
      nodes: [
        definition.node(
          id,
          wait,
          select: fn(n) { Ok(n) },
          accept: fn(n, _) { Ok(definition.Finish(n, n)) },
          destinations: [],
        ),
      ],
      state: codec.int(),
      answer: codec.int(),
    ))
  graph
}

fn ready() -> signal.Signal(Bool) {
  signal.new(run.DefinitionId("ready", 1), codec.bool())
}

pub fn waits_are_bounded_by_seven_days_unless_infinity_is_asked_test() {
  let runs = support.store()
  let allow = fn(_, _) { Ok(policy.Allow) }
  let assert Ok(now) = store.now(runs)
  let assert Ok(handle) =
    graph.start(
      graph.new(waiting(None), runs, context: fn(_) { Nil }, policy: allow)
        |> graph.with_approvers(testing.trusting_approvers())
        |> graph.build
        |> should.be_ok,
      id: support.id("vocabulary-wait"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(_) = snapshot.status
  let assert Some(due) = snapshot.deadline
  { due >= now + 7 * day && due <= now + 7 * day + 60_000 } |> should.be_true
  let assert Ok(unbounded) =
    graph.start(
      graph.new(
        waiting(Some(run.Infinity)),
        runs,
        context: fn(_) { Nil },
        policy: allow,
      )
        |> graph.with_approvers(testing.trusting_approvers())
        |> graph.build
        |> should.be_ok,
      id: support.id("vocabulary-unbounded"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(unbounded, within: duration.seconds(5))
  let assert Ok(snapshot) = graph.snapshot(unbounded)
  let assert graph.AwaitingSignal(_) = snapshot.status
  snapshot.deadline |> should.equal(None)
  // Seven days set explicitly is the default: the same stored structure.
  compiled.identity(waiting(Some(run.After(duration.hours(7 * 24)))))
  |> should.equal(compiled.identity(waiting(None)))
  compiled.identity(waiting(Some(run.Infinity)))
  |> should.equal(compiled.identity(waiting(None)))
}

// --- correlation and telemetry --------------------------------------------------

fn capture(subject: Subject(String), run: String) -> List(sinal.Attachment) {
  let mine = fn(id: String, line: String) {
    case id == run {
      True -> process.send(subject, line)
      False -> Nil
    }
  }
  [
    sinal.observe(o.graph_started(), fn(_, m: o.GraphRunStarted) {
      mine(
        m.run,
        "started " <> m.graph <> " " <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(o.activation_started(), fn(_, m: o.ActivationStarted) {
      mine(
        m.activation.run,
        "activation " <> m.activation.node <> " " <> string.inspect(m.kind),
      )
    }),
    sinal.observe(
      o.graph_approval_requested(),
      fn(_, m: o.GraphApprovalRequested) {
        mine(
          m.activation.run,
          "requested "
            <> m.requirement
            <> " expires="
            <> string.inspect(option.is_some(m.expires)),
        )
      },
    ),
    sinal.observe(
      o.graph_approval_answered(),
      fn(_, m: o.GraphApprovalAnswered) {
        mine(m.activation.run, "answered " <> string.inspect(m.answer))
      },
    ),
    sinal.observe(o.activation_settled(), fn(_, m: o.ActivationSettled) {
      mine(m.activation.run, "settled " <> string.inspect(m.route))
    }),
    sinal.observe(o.graph_cancelled(), fn(_, m: o.GraphRunCancelled) {
      mine(m.run, "cancelled")
    }),
    sinal.observe(o.graph_finished(), fn(_, m: o.GraphRunFinished) {
      mine(
        m.run,
        "finished " <> string.inspect(m.outcome) <> " root=" <> m.root,
      )
    }),
  ]
}

/// The captured lines up to and including the first that starts with
/// `last`. Events follow the commit that a wait may already have seen, so
/// a quiet period is no sign that they all came.
fn lines(subject: Subject(String), last: String) -> List(String) {
  lines_loop(subject, last, [])
}

fn lines_loop(
  subject: Subject(String),
  last: String,
  found: List(String),
) -> List(String) {
  let assert Ok(line) = process.receive(subject, 30_000)
  case string.starts_with(line, last) {
    True -> list.reverse([line, ..found])
    False -> lines_loop(subject, last, [line, ..found])
  }
}

pub fn a_graph_run_emits_its_lifecycle_with_its_correlation_test() {
  let subject = process.new_subject()
  let attachments = capture(subject, "vocabulary-events")
  let seen = process.new_subject()
  let assert Ok(order) = correlation.from_string("order-42")
  let assert Ok(handle) =
    graph.start(
      gated(support.store(), seen, doubled),
      id: support.id("vocabulary-events"),
      initial: 2,
      correlation: Some(order),
    )
  let assert Ok(waiting) = graph.await(handle, within: duration.seconds(5))
  let assert graph.AwaitingApproval(pending) = waiting
  // The runner emits the request after the commit the await saw, and an
  // approval this process commits emits from here: events of one run
  // through two processes have no order, so the approval waits for it.
  let requested = lines(subject, "requested")
  let assert Ok(_) =
    graph.approve(
      handle,
      pending,
      proof: support.proof(pending.requirement, alice()),
      context: "approver",
    )
  let assert Ok(done) = graph.await(handle, within: duration.seconds(5))
  done |> should.equal(graph.Completed(4))
  list.append(requested, lines(subject, "finished"))
  |> should.equal([
    "started publishing order-42",
    "requested publish expires=True",
    "answered Approved",
    "activation publish Activity",
    "settled Answer",
    "finished GraphCompleted root=vocabulary-events",
  ])
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

pub fn a_cancellation_is_observed_and_returns_the_snapshot_test() {
  let subject = process.new_subject()
  let attachments = capture(subject, "vocabulary-cancel")
  let seen = process.new_subject()
  let handle = started(support.store(), seen, "vocabulary-cancel")
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(cancelled) = graph.snapshot(handle)
  cancelled.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  graph.cancel(handle) |> should.equal(Error(graph.RunEnded))
  let events = lines(subject, "finished")
  list.contains(events, "cancelled") |> should.be_true
  list.contains(events, "finished GraphCancelled root=vocabulary-cancel")
  |> should.be_true
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

pub fn a_child_graph_inherits_its_parent_correlation_and_root_test() {
  let subject = process.new_subject()
  let runs = support.store()
  let allow = fn(_, _) { Ok(policy.Allow) }
  let child =
    graph.new(waiting(None), runs, context: fn(_) { Nil }, policy: allow)
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  let id = definition.node_id("delegate")
  let assert Ok(parent_graph) =
    definition.build(definition.new(
      run.DefinitionId("delegating", 1),
      entry: id,
      nodes: [
        definition.node(
          id,
          graph.as_subgraph(child),
          select: fn(n) { Ok(n) },
          accept: fn(n, _) { Ok(definition.Finish(n, n)) },
          destinations: [],
        ),
      ],
      state: codec.int(),
      answer: codec.int(),
    ))
  let parent =
    graph.new(parent_graph, runs, context: fn(_) { Nil }, policy: allow)
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  let assert Ok(order) = correlation.from_string("order-7")
  let attachment =
    sinal.observe(o.graph_started(), fn(_, m: o.GraphRunStarted) {
      case m.parent {
        Some("vocabulary-parent") ->
          process.send(
            subject,
            correlation.to_string(m.correlation) <> " " <> m.root,
          )
        _ -> Nil
      }
    })
  let assert Ok(handle) =
    graph.start(
      parent,
      id: support.id("vocabulary-parent"),
      initial: 3,
      correlation: Some(order),
    )
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  process.receive(subject, 30_000)
  |> should.equal(Ok("order-7 vocabulary-parent"))
  let _ = sinal.detach(attachment)
  Nil
}

// --- starts, errors and bounds --------------------------------------------------

pub fn a_second_start_says_whether_it_is_the_same_run_test() {
  let runs = support.store()
  let seen = process.new_subject()
  let runtime = gated(runs, seen, doubled)
  let id = support.id("vocabulary-twice")
  let assert Ok(_) = graph.start(runtime, id:, initial: 1, correlation: None)
  graph.start(runtime, id:, initial: 1, correlation: None)
  |> should.equal(Error(graph.AlreadyStarted(id, True)))
  graph.start(runtime, id:, initial: 2, correlation: None)
  |> should.equal(Error(graph.AlreadyStarted(id, False)))
  graph.error_kind(graph.AlreadyStarted(id, True))
  |> should.equal(fabric.Refused)
}

/// A taken id whose record cannot be read is the read's error, not
/// `AlreadyStarted(_, False)`.
pub fn a_start_whose_taken_id_cannot_be_read_says_so_test() {
  let runs =
    store.new(
      process.new_name("vocabulary-unreadable"),
      get: fn(_) { Ok(backend.Stored(1, "not a graph record")) },
      insert: fn(_, _) { Error(backend.AlreadyExists) },
      compare_and_set: fn(_, _, _) { Error(backend.Unavailable("down")) },
    )
    |> support.started
  let seen = process.new_subject()
  let assert Error(graph.CorruptRecord(_)) =
    graph.start(
      gated(runs, seen, doubled),
      id: support.id("vocabulary-unreadable"),
      initial: 1,
      correlation: None,
    )
}

pub fn errors_have_a_stable_kind_and_a_description_test() {
  [
    #(graph.RunNotFound, fabric.NotFound),
    #(graph.WrongReference, fabric.NotFound),
    #(graph.StaleReference, fabric.Refused),
    #(graph.ApprovalExpired, fabric.Refused),
    #(graph.SignalConflict, fabric.Refused),
    #(graph.ReconcileChildFirst, fabric.Refused),
    #(graph.ChildMismatch(graph.DifferentStore), fabric.Refused),
    #(graph.RunnerBusy, fabric.Retry),
    #(graph.Contended, fabric.Retry),
    #(graph.StoreUnavailable("down"), fabric.Unavailable),
    #(graph.RunUnattended, fabric.Unavailable),
    #(graph.CorruptRecord("bad"), fabric.Incompatible),
    #(graph.FamilyBudgetUnsupported, fabric.Incompatible),
  ]
  |> list.each(fn(pair) {
    graph.error_kind(pair.0) |> should.equal(pair.1)
    graph.describe_error(pair.0) |> string.is_empty |> should.be_false
  })
}

pub fn build_reports_every_bound_out_of_range_test() {
  let seen = process.new_subject()
  let spec = gated_spec(support.store(), seen, doubled)
  let assert Error(errors) =
    spec
    |> graph.with_callback_timeout(duration.milliseconds(0))
    |> graph.with_operation_timeout(run.After(duration.milliseconds(-1)))
    |> graph.with_command_timeout(duration.milliseconds(4_294_967_296))
    |> graph.with_approval_expiry(run.After(duration.milliseconds(0)))
    |> graph.with_family_budget(
      budget.limits(work: -1)
      |> budget.with_children(-2)
      |> budget.with_depth(64),
    )
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
  errors
  |> should.equal([
    graph.InvalidLimit(graph.CallbackTimeout, 0, 1, 4_294_967_295),
    graph.InvalidLimit(graph.OperationTimeout, -1, 1, 4_294_967_295),
    graph.InvalidLimit(graph.CommandTimeout, 4_294_967_296, 1, 4_294_967_295),
    graph.InvalidLimit(graph.ApprovalExpiry, 0, 1, 9_007_199_254_740_991),
    graph.InvalidLimit(graph.FamilyWork, -1, 0, 9_007_199_254_740_991),
    graph.InvalidLimit(graph.FamilyChildren, -2, 0, 9_007_199_254_740_991),
    graph.InvalidLimit(graph.FamilyDepth, 64, 0, 63),
  ])
  graph.describe_config_errors(errors)
  |> string.starts_with(
    "graph.with_callback_timeout (ms) is 0, outside 1..4294967295; graph.with_operation_timeout (ms) is -1",
  )
  |> should.be_true
  graph.describe_config_error(graph.InvalidLimit(graph.FamilyDepth, 64, 0, 63))
  |> should.equal("budget.with_depth is 64, outside 0..63")
  // A runtime configured from data is never a panic: an approval expiry of
  // more than a timer's range is a stored deadline, as for agents.
  let assert Ok(_) =
    spec
    |> graph.with_approval_expiry(run.After(duration.hours(24 * 365)))
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
}

pub fn build_applies_every_bound_in_range_test() {
  let seen = process.new_subject()
  let assert Ok(set) =
    gated_spec(support.store(), seen, doubled)
    |> graph.with_callback_timeout(duration.milliseconds(250))
    |> graph.with_operation_timeout(run.Infinity)
    |> graph.with_command_timeout(duration.seconds(2))
    |> graph.with_approval_expiry(run.After(duration.hours(1)))
    |> graph.with_family_budget(budget.limits(work: 3))
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
  let options = graph_runtime.options(set)
  options.callback_timeout |> should.equal(250)
  options.operation_timeout |> should.equal(None)
  options.command_timeout |> should.equal(2000)
  options.approval_expiry |> should.equal(Some(3_600_000))
  graph_runtime.family_budget(set) |> should.equal(Some(budget.limits(work: 3)))
  // The defaults.
  let defaults =
    gated_spec(support.store(), seen, doubled)
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  graph_runtime.options(defaults)
  |> should.equal(runner.Options(
    callback_timeout: 1000,
    operation_timeout: Some(60_000),
    command_timeout: 1000,
    approval_expiry: Some(604_800_000),
  ))
  graph_runtime.family_budget(defaults) |> should.equal(None)
}

pub fn a_definite_and_an_uncertain_body_failure_are_the_tools_test() {
  let allow = fn(_, _) { Ok(policy.Allow) }
  let failing = fn(failure: tool.Failure) {
    let id = definition.node_id("charge")
    let assert Ok(graph) =
      definition.build(definition.new(
        run.DefinitionId("charging", 1),
        entry: id,
        nodes: [
          definition.node(
            id,
            operation.new(
              run.DefinitionId("charge", 1),
              codec.int(),
              codec.int(),
              fn(_, _, _) { Error(failure) },
              fn(failure) { failure },
            ),
            select: fn(n) { Ok(n) },
            accept: fn(n, _) { Ok(definition.Finish(n, n)) },
            destinations: [],
          ),
        ],
        state: codec.int(),
        answer: codec.int(),
      ))
    graph.new(graph, support.store(), context: fn(_) { Nil }, policy: allow)
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
    |> should.be_ok
  }
  let assert Ok(declined) =
    graph.start(
      failing(tool.Explain("card declined")),
      id: support.id("vocabulary-declined"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(done) = graph.await(declined, within: duration.seconds(5))
  done
  |> should.equal(graph.Failed(graph.OperationFailed("card declined")))
  let assert Ok(unknown) =
    graph.start(
      failing(tool.Uncertain("gateway timed out")),
      id: support.id("vocabulary-unknown"),
      initial: 1,
      correlation: None,
    )
  let assert Ok(done) = graph.await(unknown, within: duration.seconds(5))
  let assert graph.Blocked(_, graph.EffectUncertain("gateway timed out")) = done
}

// --- status kinds --------------------------------------------------------------

/// Callers branch on the stable kind of a growing `graph.Status`.
pub fn a_status_has_a_stable_kind_test() {
  let id = support.id("kinds")
  let approval = graph.ApprovalRef(id, 1, 1, 1, run.Requirement("publish", 1))
  let reconciliation = graph.Reconciliation(id, 1, 1)
  [
    #(graph.Working, graph.Active),
    #(graph.Unattended, graph.NeedsRecovery),
    #(graph.AwaitingApproval(approval), graph.NeedsInput),
    #(
      graph.Blocked(reconciliation, graph.EffectUncertain("sent")),
      graph.NeedsInput,
    ),
    #(graph.Completed(1), graph.Ended),
    #(graph.Exhausted, graph.Ended),
    #(graph.Cancelled(graph.BeforeStart), graph.Ended),
    #(graph.Failed(graph.Denied("no")), graph.Ended),
  ]
  |> list.each(fn(case_) {
    graph.status_kind(case_.0) |> should.equal(case_.1)
    { graph.describe_status(case_.0) != "" } |> should.be_true
  })
  graph.describe_status(graph.AwaitingApproval(approval))
  |> should.equal("awaiting approval of activation 1 (publish)")
}
