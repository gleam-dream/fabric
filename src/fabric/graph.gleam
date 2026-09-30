//// Durable serial agentic graphs. Author a definition with native codecs,
//// supply an explicit policy and current-context function, and start runs
//// in the same supervised store used by ordinary Fabric agents.
////
//// A run handle starts no process by itself. Waiting approvals, unresolved
//// effects and completed runs live as stored data. `recover` reconnects work
//// whose owner is gone; recorded routing decisions are never recomputed.

import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/bounded
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as control
import fabric/internal/graph/live
import fabric/internal/graph/record
import fabric/internal/graph/runner
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec

pub type Action {
  Action(
    invocation: operation.Invocation,
    node: String,
    operation: run.Identity,
    input_json: String,
    recovery: operation.Recovery,
    kind: operation.Kind,
  )
}

pub type Policy(context) =
  fn(context, Action) -> Result(policy.Decision, String)

pub opaque type Runtime(context, state, answer) {
  Runtime(
    definition: definition.Definition(context, state, answer),
    store: store.Store,
    work: live.Work,
    options: runner.Options,
  )
}

pub opaque type Handle(context, state, answer) {
  Handle(runtime: Runtime(context, state, answer), id: run.RunId)
}

pub type Approval {
  Approval(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    revision: Int,
    requirement: run.Requirement,
  )
}

pub type Reconciliation {
  Reconciliation(run: run.RunId, activation: Int, attempt: Int)
}

/// Durable correlation data, not an authorization token. Applications must
/// authorize callers before using the delivery APIs.
pub type SignalReference {
  SignalReference(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    contract: run.Identity,
  )
}

pub type Problem {
  EffectUncertain(evidence: String)
  InvalidResult(output: String, reason: String)
}

pub type Failure {
  Denied(String)
  PolicyFailed(String)
  OperationFailed(String)
}

pub type Cancellation {
  BeforeStart
  AfterResult
  AfterFailure(Failure)
  ChildSettled(child.Reference)
  /// Reconcile the child's operation, then recover this canceled parent.
  ChildUnresolved(child.Reference, problem: Problem)
  Unresolved(reference: Reconciliation, problem: Problem)
}

pub type Status(answer) {
  Working
  /// Work exists but this store knows no owner and no live foreign lease.
  Unattended
  AwaitingApproval(Approval)
  AwaitingSignal(SignalReference)
  Child(child.Reference, child.Progress)
  /// Cancellation is committed; the owned child has not settled yet.
  CancellingChild(child.Reference)
  Blocked(Reconciliation, problem: Problem)
  Completed(answer)
  Failed(Failure)
  Exhausted
  Cancelled(Cancellation)
}

pub type Route {
  Next(node: String)
  Finished
  Canceled
}

pub type Receipt {
  Receipt(
    activation: Int,
    attempt: Int,
    node: String,
    operation: run.Identity,
    input_json: String,
    output_json: String,
    state_json: String,
    route: Route,
  )
}

pub type Snapshot(state, answer) {
  Snapshot(
    revision: Int,
    value: state,
    status: Status(answer),
    current: option.Option(Action),
    receipts: List(Receipt),
  )
}

pub type Error {
  StoreFailed(store.StoreError)
  CorruptRecord(String)
  UnsupportedRecordVersion(Int)
  DefinitionRejected(definition.Error)
  CallbackFailed(String)
  SignalEncodingFailed(codec.EncodeError)
  CommandRefused(String)
  InvalidTimeout(Int)
  Busy
  Contended
  OwnerUnknown
}

/// `context` is called for each admission, including recovery and approval.
/// The admitted body receives that same context. Callbacks and operations are
/// bounded separately; pure selection/acceptance must contain no effects.
pub fn new(
  definition: definition.Definition(context, state, answer),
  store: store.Store,
  context: fn() -> context,
  policy: Policy(context),
) -> Runtime(context, state, answer) {
  // Keep child runtimes in one deployed callback. The ordinary callbacks
  // capture the parent's codecs and routes, without copying descendant trees.
  let #(definition, child) = definition.detach_children(definition)
  let work =
    live.Work(
      admit: fn(id, activation) {
        let invocation =
          operation.Invocation(
            run.issued(id),
            activation.id,
            activation.attempt,
          )
        let prepared = activation.prepared
        let context = context()
        use decision <- result.try(policy(
          context,
          Action(
            invocation,
            prepared.node,
            prepared.operation,
            prepared.input,
            prepared.recovery,
            prepared.kind,
          ),
        ))
        Ok(
          live.Admission(decision, fn() {
            definition.invoke(definition, context, invocation, prepared)
          }),
        )
      },
      accept: fn(state, activation, output) {
        definition.accept(definition, state.value, activation.prepared, output)
      },
      check_output: fn(activation, output) {
        definition.check_output(definition, activation.prepared, output)
      },
      validate: fn(state) { definition.validate(definition, state) },
      child: fn(activation) { child(activation.prepared) },
    )
  Runtime(definition, store, work, runner.Options(1000, 60_000, 1000))
}

pub fn with_timeouts(
  runtime: Runtime(context, state, answer),
  callbacks: Int,
  operation: Int,
  commands: Int,
) -> Result(Runtime(context, state, answer), Error) {
  use _ <- result.try(
    list.try_each([callbacks, operation, commands], fn(value) {
      case value > 0 && value <= 4_294_967_295 {
        True -> Ok(Nil)
        False -> Error(InvalidTimeout(value))
      }
    }),
  )
  Ok(
    Runtime(..runtime, options: runner.Options(callbacks, operation, commands)),
  )
}

pub fn attach(
  runtime: Runtime(context, state, answer),
  id: run.RunId,
) -> Handle(context, state, answer) {
  Handle(runtime, id)
}

pub fn id(handle: Handle(context, state, answer)) -> run.RunId {
  handle.id
}

/// Bind a graph's native initial state and answer as one managed operation.
/// Parent and child runtimes must use the same supervised store. The parent
/// owns cancellation; child policy still gates every child operation.
pub fn as_subgraph(
  runtime: Runtime(child_context, child_state, child_answer),
) -> operation.Operation(parent_context, child_state, child_answer) {
  let runs = runtime.store
  operation.subgraph(
    definition.identity(runtime.definition).identity,
    definition.state_codec(runtime.definition),
    definition.answer_codec(runtime.definition),
    child_driver.Driver(
      store: fn() { store.pid(runs) },
      reserve: fn(parent, id, input, reservation) {
        reserved_child(
          runtime,
          parent,
          id,
          input,
          reservation == child_driver.Cancel,
          3,
        )
        |> result.map_error(string.inspect)
      },
      read: fn(parent, id) {
        child_progress(runs, parent, id, 64) |> result.map_error(string.inspect)
      },
    ),
  )
}

/// Open a specific child visit, including a completed one, with its native
/// runtime. The child's reciprocal attachment is checked before returning.
pub fn child(
  parent: Handle(context, state, answer),
  activation: Int,
  runtime: Runtime(child_context, child_state, child_answer),
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  use _ <- result.try(
    case store.pid(parent.runtime.store), store.pid(runtime.store) {
      Ok(parent_store), Ok(child_store) if parent_store == child_store -> Ok(Nil)
      _, _ ->
        Error(CommandRefused("child runtime does not use the parent store"))
    },
  )
  let link = child.Parent(run.id_to_string(parent.id), activation)
  let id = child.reserved_id(link.run, activation)
  use #(_, state) <- result.try(
    runner.load(runtime.store, runtime.work, runtime.options, id)
    |> result.map_error(from_runner),
  )
  use _ <- result.try(check_attachment(state, link))
  Ok(attach(runtime, run.issued(id)))
}

fn check_attachment(
  state: control.State,
  parent: child.Parent,
) -> Result(Nil, Error) {
  case state.parent == Some(parent) {
    True -> Ok(Nil)
    False ->
      Error(CommandRefused("child belongs to a different parent activation"))
  }
}

fn reserved_child(
  runtime: Runtime(context, state, answer),
  parent: child.Parent,
  id: String,
  input: String,
  cancel: Bool,
  tries: Int,
) -> Result(Nil, Error) {
  case runner.load_raw(runtime.store, id) {
    Ok(#(_, state)) -> {
      use _ <- result.try(check_attachment(state, parent))
      use _ <- result.try(case state.initial == input {
        True -> Ok(Nil)
        False ->
          Error(CommandRefused("child input differs from its reservation"))
      })
      case cancel, state.phase {
        True, control.Ended(_) -> Ok(Nil)
        True, _ ->
          runner.cancel(runtime.store, runtime.work, runtime.options, id, 3)
          |> result.replace(Nil)
          |> result.map_error(from_runner)
        False, _ ->
          runner.recover(runtime.store, runtime.work, runtime.options, id, 3)
          |> result.replace(Nil)
          |> result.map_error(from_runner)
      }
    }
    Error(runner.StoreFailed(store.NotFound)) -> {
      use initial <- result.try(
        definition.decode_state(runtime.definition, input)
        |> result.map_error(DefinitionRejected),
      )
      use #(value, entry) <- result.try(
        definition.prepare(runtime.definition, initial)
        |> result.map_error(DefinitionRejected),
      )
      use #(state, effects) <- result.try(
        control.start(id, definition.identity(runtime.definition), value, entry)
        |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
      )
      let state = control.State(..state, parent: Some(parent))
      use #(state, effects) <- result.try(case cancel {
        True ->
          control.cancel_abandoned(state)
          |> result.map_error(fn(error) {
            CommandRefused(string.inspect(error))
          })
        False -> {
          use _ <- result.map(
            runner.check_ancestry(runtime.store, state)
            |> result.map_error(from_runner),
          )
          #(state, effects)
        }
      })
      case
        runner.launch(
          runtime.store,
          runtime.work,
          runtime.options,
          None,
          state,
          effects,
          None,
          False,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(runner.StoreFailed(store.AlreadyExists)) if tries > 1 ->
          reserved_child(runtime, parent, id, input, cancel, tries - 1)
        Error(error) -> Error(from_runner(error))
      }
    }
    Error(error) -> Error(from_runner(error))
  }
}

fn child_progress(
  runs: store.Store,
  parent: child.Parent,
  id: String,
  left: Int,
) -> Result(child.Progress, Error) {
  use _ <- result.try(case left > 0 {
    True -> Ok(Nil)
    False -> Error(CommandRefused("child nesting limit reached"))
  })
  case runner.load_raw(runs, id) {
    Error(runner.StoreFailed(store.NotFound)) -> Ok(child.Working)
    Error(error) -> Error(from_runner(error))
    Ok(#(_, state)) -> {
      use _ <- result.try(check_attachment(state, parent))
      use nested <- result.try(case state.phase {
        control.Joining(a, child) | control.WaitingChild(a, child) ->
          child_progress(runs, child.Parent(state.run, a.id), child, left - 1)
        _ -> Ok(child.Working)
      })
      Ok(case state.phase {
        control.AwaitingApproval(_, approval) ->
          child.Approval(approval.requirement)
        control.WaitingSignal(a) -> child.Signal(a.prepared.operation)
        control.Blocked(_, problem) -> child.Uncertain(string.inspect(problem))
        control.ChildBlocked(_, _, reason) -> child.Uncertain(reason)
        control.Ended(control.Completed(output)) -> child.Succeeded(output)
        control.Ended(control.Failed(_, fault)) ->
          child.Failed(string.inspect(fault))
        control.Ended(control.Exhausted(_)) ->
          child.Failed("child activation limit reached")
        control.Ended(control.Cancelled(_, control.UnresolvedCancellation(_))) ->
          child.Cancelled(True)
        control.Ended(control.Cancelled(_, _)) -> child.Cancelled(False)
        _ ->
          case nested {
            child.Approval(_) | child.Signal(_) | child.Uncertain(_) -> nested
            _ -> child.Working
          }
      })
    }
  }
}

pub fn approval_requirement(approval: Approval) -> run.Requirement {
  approval.requirement
}

/// A successful return means the initial record was confirmed. Execution
/// proceeds independently; a store draining during start retains unattended
/// work for recovery. Reusing an existing run id is refused.
pub fn start(
  runtime: Runtime(context, state, answer),
  id: run.RunId,
  initial: state,
) -> Result(Handle(context, state, answer), Error) {
  use prepared <- result.try(
    bounded.call(runtime.options.callback_timeout, fn() {
      definition.prepare(runtime.definition, initial)
    })
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  use #(value, prepared) <- result.try(
    prepared |> result.map_error(DefinitionRejected),
  )
  use #(state, effects) <- result.try(
    control.start(
      run.id_to_string(id),
      definition.identity(runtime.definition),
      value,
      prepared,
    )
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  use _ <- result.try(
    runner.launch(
      runtime.store,
      runtime.work,
      runtime.options,
      None,
      state,
      effects,
      None,
      False,
    )
    |> result.map_error(from_runner),
  )
  Ok(Handle(runtime, id))
}

pub fn read(
  handle: Handle(context, state, answer),
) -> Result(Snapshot(state, answer), Error) {
  let runtime = handle.runtime
  use #(entry, state) <- result.try(
    runner.load(
      runtime.store,
      runtime.work,
      runtime.options,
      run.id_to_string(handle.id),
    )
    |> result.map_error(from_runner),
  )
  use view <- result.try(
    bounded.call(runtime.options.callback_timeout, fn() {
      snapshot(runtime, entry, state)
    })
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  view
}

/// Waits for completion, approval, reconciliation or unattended work. At the
/// deadline a still-working snapshot is returned. It never recovers a run.
pub fn await(
  handle: Handle(context, state, answer),
  within: Int,
) -> Result(Snapshot(state, answer), Error) {
  use _ <- result.try(case within >= 0 && within <= 4_294_967_295 {
    True -> Ok(Nil)
    False -> Error(InvalidTimeout(within))
  })
  let watcher = process.new_subject()
  let id = run.id_to_string(handle.id)
  use _ <- result.try(
    store.watch(handle.runtime.store, id, watcher)
    |> result.map_error(StoreFailed),
  )
  let outcome = attend(handle, watcher, now() + within)
  store.unwatch(handle.runtime.store, id, watcher)
  outcome
}

fn attend(
  handle: Handle(context, state, answer),
  watcher: process.Subject(Nil),
  deadline: Int,
) -> Result(Snapshot(state, answer), Error) {
  use snapshot <- result.try(read(handle))
  let left = deadline - now()
  case snapshot.status, left > 0 {
    Working, True
    | CancellingChild(_), True
    | Child(_, child.Working), True
    | Child(_, child.Succeeded(_)), True
    | Child(_, child.Failed(_)), True
    | Child(_, child.Cancelled(_)), True
    -> {
      let _ = process.receive(watcher, int.min(left, 100))
      attend(handle, watcher, deadline)
    }
    _, _ -> Ok(snapshot)
  }
}

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

/// A leased store leaves a live foreign owner alone. On an unleased store,
/// callers must know the previous owner is gone before recovering through
/// another store process. Started effects obey their declared replay contract.
/// Idle child waits restore their local wakeup registration and reconnect the
/// child; a missed notification is repaired from its retained outcome.
/// For a canceled subgraph, recovery only records a now-settled child outcome;
/// it never restarts the child or resumes the parent's routes.
pub fn recover(
  handle: Handle(context, state, answer),
) -> Result(Snapshot(state, answer), Error) {
  let runtime = handle.runtime
  use _ <- result.try(
    runner.recover(
      runtime.store,
      runtime.work,
      runtime.options,
      run.id_to_string(handle.id),
      3,
    )
    |> result.map_error(from_runner),
  )
  read(handle)
}

/// Cancellation does not require the currently deployed definition to fit the
/// record. A lost or unresponsive owner is fenced by a committed cancellation;
/// effects whose results were not saved remain explicitly unresolved.
pub fn cancel(handle: Handle(context, state, answer)) -> Result(Nil, Error) {
  let runtime = handle.runtime
  runner.cancel(
    runtime.store,
    runtime.work,
    runtime.options,
    run.id_to_string(handle.id),
    3,
  )
  |> result.map_error(from_runner)
  |> result.replace(Nil)
}

pub fn approve(
  handle: Handle(context, state, answer),
  approval: Approval,
) -> Result(Snapshot(state, answer), Error) {
  answer_approval(handle, approval, None, 3)
}

pub fn reject(
  handle: Handle(context, state, answer),
  approval: Approval,
  reason: String,
) -> Result(Snapshot(state, answer), Error) {
  answer_approval(handle, approval, Some(reason), 3)
}

/// Supply a native value for the exact committed wait. An identical encoded
/// value for an already consumed reference is acknowledged without routing
/// again. A conflicting value or canceled/uncommitted wait is refused.
pub fn deliver(
  handle: Handle(context, state, answer),
  reference: SignalReference,
  contract: signal.Signal(value),
  value: value,
) -> Result(Snapshot(state, answer), Error) {
  use _ <- result.try(case signal.identity(contract) == reference.contract {
    True -> Ok(Nil)
    False ->
      Error(CommandRefused("signal contract does not match the reference"))
  })
  use encoded <- result.try(
    bounded.call(handle.runtime.options.callback_timeout, fn() {
      signal.encode(contract, value)
    })
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  use encoded <- result.try(encoded |> result.map_error(SignalEncodingFailed))
  deliver_json(handle, reference, encoded)
}

/// Transport boundary for callers that already hold encoded data. The saved
/// signal's deployed codec validates the value before it can be consumed.
/// Duplicate acknowledgement compares exact encoded bytes, including JSON
/// whitespace; transports should retain the original payload on retries.
pub fn deliver_json(
  handle: Handle(context, state, answer),
  reference: SignalReference,
  output_json: String,
) -> Result(Snapshot(state, answer), Error) {
  deliver_with(handle, reference, output_json, 3)
}

fn signal_matches(
  reference: SignalReference,
  activation: control.Activation,
) -> Bool {
  reference.activation == activation.id
  && reference.attempt == activation.attempt
  && reference.contract == activation.prepared.operation
  && activation.prepared.kind == operation.Signal
}

fn deliver_with(
  handle: Handle(context, state, answer),
  reference: SignalReference,
  output: String,
  tries: Int,
) -> Result(Snapshot(state, answer), Error) {
  use _ <- result.try(case reference.run == handle.id {
    True -> Ok(Nil)
    False -> Error(CommandRefused("signal belongs to another run"))
  })
  let runtime = handle.runtime
  use #(entry, state) <- result.try(
    runner.load(
      runtime.store,
      runtime.work,
      runtime.options,
      run.id_to_string(handle.id),
    )
    |> result.map_error(from_runner),
  )
  case
    list.find(state.receipts, fn(receipt) {
      receipt.activation.id == reference.activation
    })
  {
    Ok(receipt) ->
      case
        signal_matches(reference, receipt.activation)
        && receipt.output == output
        && receipt.route != control.Canceled
      {
        True -> read(handle)
        False ->
          Error(CommandRefused("signal conflicts with an accepted result"))
      }
    Error(Nil) -> {
      use _ <- result.try(
        runner.check_ancestry(runtime.store, state)
        |> result.map_error(from_runner),
      )
      use activation <- result.try(case state.phase {
        control.WaitingSignal(a) ->
          case signal_matches(reference, a) {
            True -> Ok(a)
            False -> Error(CommandRefused("signal is not for the current wait"))
          }
        _ -> Error(CommandRefused("no signal is awaited"))
      })
      use accepted <- result.try(
        bounded.call(runtime.options.callback_timeout, fn() {
          runtime.work.accept(state, activation, output)
        })
        |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
      )
      use decision <- result.try(
        accepted |> result.map_error(DefinitionRejected),
      )
      use #(next, effects) <- result.try(
        control.step(
          state,
          control.Signaled(activation.id, activation.attempt, output, decision),
        )
        |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
      )
      case
        runner.launch(
          runtime.store,
          runtime.work,
          runtime.options,
          Some(entry.revision),
          next,
          effects,
          None,
          False,
        )
      {
        Ok(_) -> read(handle)
        Error(runner.StoreFailed(store.Conflict(_))) if tries > 1 ->
          deliver_with(handle, reference, output, tries - 1)
        Error(error) -> Error(from_runner(error))
      }
    }
  }
}

fn answer_approval(
  handle: Handle(context, state, answer),
  approval: Approval,
  rejection: option.Option(String),
  tries: Int,
) -> Result(Snapshot(state, answer), Error) {
  let runtime = handle.runtime
  let id = run.id_to_string(handle.id)
  let reference =
    control.Approval(
      approval.activation,
      approval.attempt,
      approval.revision,
      approval.requirement,
    )
  use _ <- result.try(case approval.run == handle.id {
    True -> Ok(Nil)
    False -> Error(CommandRefused("approval belongs to another run"))
  })
  use #(entry, state) <- result.try(
    runner.load(runtime.store, runtime.work, runtime.options, id)
    |> result.map_error(from_runner),
  )
  use activation <- result.try(case state.phase {
    control.AwaitingApproval(activation, current) if current == reference ->
      Ok(activation)
    _ -> Error(CommandRefused("approval is not current"))
  })
  use _ <- result.try(
    runner.check_ancestry(runtime.store, state) |> result.map_error(from_runner),
  )
  let #(event, body) = case rejection {
    Some(reason) -> #(control.Rejected(reference, reason), None)
    None ->
      case
        runner.admit(
          runtime.store,
          runtime.work,
          runtime.options,
          state,
          activation,
        )
      {
        Ok(live.Admission(decision, body)) -> #(
          control.Approved(reference, Ok(decision)),
          Some(body),
        )
        Error(reason) -> #(control.Approved(reference, Error(reason)), None)
      }
  }
  use #(next, effects) <- result.try(
    control.step(state, event)
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  case
    runner.launch(
      runtime.store,
      runtime.work,
      runtime.options,
      Some(entry.revision),
      next,
      effects,
      body,
      False,
    )
  {
    Ok(_) -> read(handle)
    Error(runner.StoreFailed(store.Conflict(_))) if tries > 1 ->
      answer_approval(handle, approval, rejection, tries - 1)
    Error(error) -> Error(from_runner(error))
  }
}

/// Supply the actual result of the original operation, encoded with its output
/// codec. This is an explicit application reconciliation, not a repeated body.
/// After cancellation the result is retained without running a route callback.
pub fn reconcile(
  handle: Handle(context, state, answer),
  reference: Reconciliation,
  output_json: String,
) -> Result(Snapshot(state, answer), Error) {
  reconcile_with(handle, reference, output_json, 3)
}

fn reconcile_with(
  handle: Handle(context, state, answer),
  reference: Reconciliation,
  output: String,
  tries: Int,
) -> Result(Snapshot(state, answer), Error) {
  let runtime = handle.runtime
  let id = run.id_to_string(handle.id)
  use _ <- result.try(case reference.run == handle.id {
    True -> Ok(Nil)
    False -> Error(CommandRefused("reconciliation belongs to another run"))
  })
  use #(entry, state) <- result.try(
    runner.load(runtime.store, runtime.work, runtime.options, id)
    |> result.map_error(from_runner),
  )
  use #(activation, cancelled) <- result.try(case state.phase {
    control.Blocked(a, _) -> Ok(#(a, False))
    control.Ended(control.Cancelled(a, control.UnresolvedCancellation(_))) ->
      Ok(#(a, True))
    _ -> Error(CommandRefused("no unresolved result"))
  })
  use _ <- result.try(
    case cancelled && activation.prepared.kind == operation.Subgraph {
      True ->
        Error(CommandRefused(
          "reconcile the child, then recover its canceled parent",
        ))
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(case cancelled {
    True -> Ok(Nil)
    False ->
      runner.check_ancestry(runtime.store, state)
      |> result.map_error(from_runner)
  })
  use _ <- result.try(
    case
      reference.activation == activation.id
      && reference.attempt == activation.attempt
    {
      True -> Ok(Nil)
      False -> Error(CommandRefused("reconciliation is not current"))
    },
  )
  use event <- result.try(
    bounded.call(runtime.options.callback_timeout, fn() {
      case cancelled {
        True -> {
          use _ <- result.map(runtime.work.check_output(activation, output))
          control.CancelledResult(control.reference(state, activation), output)
        }
        False -> {
          use decision <- result.map(runtime.work.accept(
            state,
            activation,
            output,
          ))
          control.Reconciled(
            activation.id,
            activation.attempt,
            output,
            decision,
          )
        }
      }
    })
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  use event <- result.try(event |> result.map_error(DefinitionRejected))
  use #(next, effects) <- result.try(
    control.step(state, event)
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  case
    runner.launch(
      runtime.store,
      runtime.work,
      runtime.options,
      Some(entry.revision),
      next,
      effects,
      None,
      False,
    )
  {
    Ok(_) -> read(handle)
    Error(runner.StoreFailed(store.Conflict(_))) if tries > 1 ->
      reconcile_with(handle, reference, output, tries - 1)
    Error(error) -> Error(from_runner(error))
  }
}

fn snapshot(
  runtime: Runtime(context, state, answer),
  entry: store.Entry,
  state: control.State,
) -> Result(Snapshot(state, answer), Error) {
  let definition = runtime.definition
  use value <- result.try(
    definition.decode_state(definition, state.value)
    |> result.map_error(DefinitionRejected),
  )
  use status <- result.try(case state.phase {
    control.ChildBlocked(a, id, reason) ->
      Ok(Child(
        child.Reference(run.issued(state.run), a.id, run.issued(id)),
        child.Uncertain(reason),
      ))
    control.WaitingChild(a, id) -> {
      use driver <- result.try(
        runner.checked_child(runtime.store, runtime.work, a)
        |> result.map_error(CallbackFailed),
      )
      use progress <- result.try(
        driver.read(child.Parent(state.run, a.id), id)
        |> result.map_error(CallbackFailed),
      )
      Ok(Child(
        child.Reference(run.issued(state.run), a.id, run.issued(id)),
        progress,
      ))
    }
    control.StoppingChild(a, id) ->
      Ok(case runner.driven(entry, state) {
        False -> Unattended
        True ->
          CancellingChild(child.Reference(
            run.issued(state.run),
            a.id,
            run.issued(id),
          ))
      })
    control.Joining(a, id) ->
      Ok(case runner.driven(entry, state) {
        False -> Unattended
        True -> {
          let progress = case
            runner.checked_child(runtime.store, runtime.work, a)
          {
            Error(error) -> child.Uncertain(error)
            Ok(driver) ->
              case driver.read(child.Parent(state.run, a.id), id) {
                Ok(progress) -> progress
                Error(reason) -> child.Uncertain(reason)
              }
          }
          Child(
            child.Reference(run.issued(state.run), a.id, run.issued(id)),
            progress,
          )
        }
      })
    control.Ready(_)
    | control.Queued(_)
    | control.Running(_)
    | control.Stopping(_) ->
      Ok(case runner.driven(entry, state) {
        True -> Working
        False -> Unattended
      })
    control.AwaitingApproval(_, reference) ->
      Ok(
        AwaitingApproval(Approval(
          run.issued(state.run),
          reference.activation,
          reference.attempt,
          reference.revision,
          reference.requirement,
        )),
      )
    control.WaitingSignal(a) ->
      Ok(
        AwaitingSignal(SignalReference(
          run.issued(state.run),
          a.id,
          a.attempt,
          a.prepared.operation,
        )),
      )
    control.Blocked(a, problem) ->
      Ok(Blocked(
        Reconciliation(run.issued(state.run), a.id, a.attempt),
        public_problem(problem),
      ))
    control.Ended(control.Completed(answer)) ->
      definition.decode_answer(definition, answer)
      |> result.map(Completed)
      |> result.map_error(DefinitionRejected)
    control.Ended(control.Exhausted(_)) -> Ok(Exhausted)
    control.Ended(control.Failed(_, fault)) -> Ok(Failed(failure(fault)))
    control.Ended(control.Cancelled(a, cancellation)) ->
      Ok(
        Cancelled(case cancellation {
          control.BeforeStart -> BeforeStart
          control.AfterResult -> AfterResult
          control.AfterFailure(fault) -> AfterFailure(failure(fault))
          control.AfterChild(id) ->
            ChildSettled(child.Reference(
              run.issued(state.run),
              a.id,
              run.issued(id),
            ))
          control.UnresolvedCancellation(problem)
            if a.prepared.kind == operation.Subgraph
          ->
            ChildUnresolved(
              child.Reference(
                run.issued(state.run),
                a.id,
                run.issued(child.reserved_id(state.run, a.id)),
              ),
              public_problem(problem),
            )
          control.UnresolvedCancellation(problem) ->
            Unresolved(
              Reconciliation(run.issued(state.run), a.id, a.attempt),
              public_problem(problem),
            )
        }),
      )
  })
  let current = case state.phase {
    control.Ready(a)
    | control.Queued(a)
    | control.Running(a)
    | control.AwaitingApproval(a, _)
    | control.WaitingSignal(a)
    | control.Joining(a, _)
    | control.WaitingChild(a, _)
    | control.ChildBlocked(a, _, _)
    | control.StoppingChild(a, _)
    | control.Blocked(a, _)
    | control.Stopping(a)
    | control.Ended(control.Failed(a, _))
    | control.Ended(control.Cancelled(a, _)) ->
      Some(Action(
        operation.Invocation(run.issued(state.run), a.id, a.attempt),
        a.prepared.node,
        a.prepared.operation,
        a.prepared.input,
        a.prepared.recovery,
        a.prepared.kind,
      ))
    control.Ended(control.Completed(_)) | control.Ended(control.Exhausted(_)) ->
      None
  }
  Ok(Snapshot(
    entry.revision,
    value,
    status,
    current,
    list.map(state.receipts, fn(receipt) {
      let a = receipt.activation
      Receipt(
        a.id,
        a.attempt,
        a.prepared.node,
        a.prepared.operation,
        a.prepared.input,
        receipt.output,
        receipt.state,
        case receipt.route {
          control.Next(node) -> Next(node)
          control.Finished -> Finished
          control.Canceled -> Canceled
        },
      )
    }),
  ))
}

fn failure(fault: control.Fault) -> Failure {
  case fault {
    control.Denied(reason) -> Denied(reason)
    control.PolicyFailed(reason) -> PolicyFailed(reason)
    control.OperationFailed(reason) -> OperationFailed(reason)
  }
}

fn public_problem(problem: control.Problem) -> Problem {
  case problem {
    control.Uncertain(evidence) -> EffectUncertain(evidence)
    control.InvalidResult(output, reason) -> InvalidResult(output, reason)
  }
}

fn from_runner(error: runner.Error) -> Error {
  case error {
    runner.StoreFailed(error) -> StoreFailed(error)
    runner.Unreadable(record.Corrupt(reason)) -> CorruptRecord(reason)
    runner.Unreadable(record.UnsupportedVersion(version)) ->
      UnsupportedRecordVersion(version)
    runner.Incompatible(error) -> DefinitionRejected(error)
    runner.CallbackFailed(reason) -> CallbackFailed(reason)
    runner.Refused(reason) -> CommandRefused(string.inspect(reason))
    runner.Busy -> Busy
    runner.Contended -> Contended
    runner.OwnerUnknown -> OwnerUnknown
  }
}
