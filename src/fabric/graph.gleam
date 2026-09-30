//// Durable agentic graphs. Author a definition with native codecs,
//// supply an explicit policy and current-context function, and start runs
//// in the same supervised store used by ordinary Fabric agents.
////
//// A run handle starts no process by itself. Waiting approvals, unresolved
//// effects and completed runs live as stored data. `recover` reconnects work
//// whose owner is gone; recorded routing decisions are never recomputed.

import fabric/budget
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/job
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/bounded
import fabric/internal/budget/model as reservations
import fabric/internal/graph/agent_child
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as control
import fabric/internal/graph/fork as scope
import fabric/internal/graph/fork_driver
import fabric/internal/graph/live
import fabric/internal/graph/record
import fabric/internal/graph/runner
import fabric/internal/sweeper
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/int
import gleam/json
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

/// Register a root graph for `fabric.sweeper`. The bounded factory rebuilds
/// its complete runtime and children against the supplied pinned store.
/// Registration discovers expired leases and changed idle dependencies,
/// including waits whose local wakeup was lost.
pub fn recovery(
  identity: run.Identity,
  build: fn(store.Store) -> Runtime(context, state, answer),
) -> sweeper.Recovery {
  sweeper.graph_recovery(identity, fn(runs, id) {
    use runtime <- result.try(
      bounded.call(5000, fn() { build(runs) }) |> result.replace_error(Nil),
    )
    use Nil <- result.try(
      case
        definition.identity(runtime.definition).identity == identity,
        store.pid(runtime.store),
        store.pid(runs)
      {
        True, Ok(actual), Ok(expected) if actual == expected -> Ok(Nil)
        _, _, _ -> Error(Nil)
      },
    )
    runner.discover(runs, runtime.work, runtime.options, id, 3)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  })
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
  DeadlineExpired(due: Int)
  Denied(String)
  PolicyFailed(String)
  OperationFailed(String)
  FamilyBudget(budget.Denial)
}

pub type Cancellation {
  BeforeStart
  JobDetached(job.Reference)
  JobStopped(job.Reference)
  AfterResult
  AfterFailure(Failure)
  ChildSettled(child.Reference)
  ForkSettled(activation: Int)
  /// Reconcile the child's operation, then recover its canceled or expired parent.
  ChildUnresolved(child.Reference, problem: Problem)
  Unresolved(reference: Reconciliation, problem: Problem)
}

pub type Status(answer) {
  Working
  /// Work exists but this store knows no owner and no live foreign lease.
  Unattended
  AwaitingApproval(Approval)
  AwaitingSignal(SignalReference)
  AwaitingJob(job.Reference)
  CancellingJob(job.Reference, job.CancellationProgress, operation.StopReason)
  Child(child.Reference, child.Progress)
  Fork(fork.Snapshot, stop: option.Option(operation.StopReason))
  /// The stop cause is committed; the owned child has not settled yet.
  CancellingChild(child.Reference, operation.StopReason)
  Blocked(Reconciliation, problem: Problem)
  Completed(answer)
  Failed(Failure)
  Exhausted
  Cancelled(Cancellation)
  Expired(due: Int, disposition: Cancellation)
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
    /// UTC Unix milliseconds for a current wait, job cleanup or expired outcome.
    deadline: option.Option(Int),
    forks: List(fork.Snapshot),
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
  let #(definition, child, fork) = definition.detach_children(definition)
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
        use _ <- result.try(definition.check_join(
          definition,
          state,
          activation,
          output,
        ))
        definition.accept(definition, state.value, activation.prepared, output)
      },
      check_output: fn(activation, output) {
        definition.check_output(definition, activation.prepared, output)
      },
      observe_job: fn(activation) {
        definition.observe_job(definition, context(), activation.prepared)
      },
      cancel_job: fn(id, activation) {
        let context = context()
        fn() {
          definition.cancel_job(
            definition,
            context,
            operation.Invocation(
              run.issued(id),
              activation.id,
              activation.attempt,
            ),
            activation.prepared,
          )
          |> result.replace("null")
        }
      },
      validate: fn(state) { definition.validate(definition, state) },
      child: fn(activation) { child(activation.prepared) },
      fork: fn(activation) { fork(activation.prepared) },
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

@internal
pub fn backing_store(handle: Handle(context, state, answer)) -> store.Store {
  handle.runtime.store
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
        reserved_child(runtime, parent, id, input, reservation, 3)
        |> result.map_error(string.inspect)
      },
      read: fn(parent, id, _) {
        child_progress(runs, parent, id, 64) |> result.map_error(string.inspect)
      },
    ),
  )
}

/// Compose two managed graphs with independent native inputs and answers.
/// A settled member failure is available to the parent as a typed alternative.
pub fn both(
  identity: run.Identity,
  left: Runtime(left_context, left_state, left_answer),
  right: Runtime(right_context, right_state, right_answer),
) -> Result(
  operation.Operation(
    parent_context,
    #(left_state, right_state),
    Result(#(left_answer, right_answer), fork.Failure),
  ),
  Error,
) {
  let left_input = definition.state_codec(left.definition)
  let right_input = definition.state_codec(right.definition)
  let input = codec.pair(left_input, right_input)
  let left_output = definition.answer_codec(left.definition)
  let right_output = definition.answer_codec(right.definition)
  use output <- result.try(
    fork.result_codec(codec.pair(left_output, right_output))
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  use left_driver <- result.try(
    operation.child_driver(as_subgraph(left))
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  use right_driver <- result.try(
    operation.child_driver(as_subgraph(right))
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  let left_definition = definition.identity(left.definition)
  let right_definition = definition.identity(right.definition)
  let left_store = left.store
  let right_store = right.store
  let driver =
    fork_driver.Driver(
      stores: fn() { [store.pid(left_store), store.pid(right_store)] },
      prepare: fn(encoded) {
        use values <- result.try(
          codec.decode_json(input, encoded) |> result.map_error(string.inspect),
        )
        use left <- result.try(
          codec.encode_json(left_input, values.0)
          |> result.map_error(string.inspect),
        )
        use right <- result.map(
          codec.encode_json(right_input, values.1)
          |> result.map_error(string.inspect),
        )
        [
          fork.Request(left_definition.identity, left),
          fork.Request(right_definition.identity, right),
        ]
      },
      member: fn(ordinal) {
        case ordinal {
          1 -> Ok(left_driver)
          2 -> Ok(right_driver)
          _ -> Error("unknown pair member")
        }
      },
      check: fn(ordinal, request) {
        case ordinal, request.definition {
          1, identity if identity == left_definition.identity ->
            codec.decode_json(left_input, request.input)
            |> result.replace(Nil)
            |> result.map_error(string.inspect)
          2, identity if identity == right_definition.identity ->
            codec.decode_json(right_input, request.input)
            |> result.replace(Nil)
            |> result.map_error(string.inspect)
          _, _ -> Error("fork member definition changed")
        }
      },
      output: fn(outcome) {
        use answer <- result.try(case outcome {
          Error(failure) -> Ok(Error(failure))
          Ok([left, right]) -> {
            use left <- result.try(
              codec.decode_json(left_output, left)
              |> result.map_error(string.inspect),
            )
            use right <- result.map(
              codec.decode_json(right_output, right)
              |> result.map_error(string.inspect),
            )
            Ok(#(left, right))
          }
          Ok(_) -> Error("pair result must contain exactly two members")
        })
        codec.encode_json(output, answer) |> result.map_error(string.inspect)
      },
    )
  let signature = fork_signature([left_definition, right_definition])
  Ok(operation.parallel(identity, input, output, 2, 2, signature, driver))
}

/// Run a bounded list of managed children and join native answers in input order.
/// Empty input succeeds; oversized input is refused before any child reservation.
/// Waiting and uncertain members keep their concurrency slots.
pub fn map(
  identity: run.Identity,
  child: Runtime(child_context, child_state, child_answer),
  max_members maximum: Int,
  concurrency concurrency: Int,
) -> Result(
  operation.Operation(
    parent_context,
    List(child_state),
    Result(List(child_answer), fork.Failure),
  ),
  Error,
) {
  use _ <- result.try(case maximum > 0 && concurrency > 0 {
    True -> Ok(Nil)
    False ->
      Error(CommandRefused(
        "map requires positive membership and concurrency bounds",
      ))
  })
  let child_input = definition.state_codec(child.definition)
  let child_output = definition.answer_codec(child.definition)
  let input = codec.list(child_input)
  use output <- result.try(
    fork.result_codec(codec.list(child_output))
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  use binding <- result.try(
    operation.child_driver(as_subgraph(child))
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  let child_definition = definition.identity(child.definition)
  let runs = child.store
  let driver =
    fork_driver.Driver(
      stores: fn() { [store.pid(runs)] },
      prepare: fn(encoded) {
        use values <- result.try(
          codec.decode_json(input, encoded) |> result.map_error(string.inspect),
        )
        list.try_map(values, fn(value) {
          use input <- result.map(
            codec.encode_json(child_input, value)
            |> result.map_error(string.inspect),
          )
          fork.Request(child_definition.identity, input)
        })
      },
      member: fn(ordinal) {
        case ordinal > 0 && ordinal <= maximum {
          True -> Ok(binding)
          False -> Error("unknown map member")
        }
      },
      check: fn(ordinal, request) {
        case
          ordinal > 0
          && ordinal <= maximum
          && request.definition == child_definition.identity
        {
          True ->
            codec.decode_json(child_input, request.input)
            |> result.replace(Nil)
            |> result.map_error(string.inspect)
          False -> Error("map member definition changed")
        }
      },
      output: fn(outcome) {
        use answer <- result.try(case outcome {
          Error(failure) -> Ok(Error(failure))
          Ok(outputs) ->
            list.try_map(outputs, fn(output) {
              codec.decode_json(child_output, output)
              |> result.map_error(string.inspect)
            })
            |> result.map(Ok)
        })
        codec.encode_json(output, answer) |> result.map_error(string.inspect)
      },
    )
  Ok(operation.parallel(
    identity,
    input,
    output,
    maximum,
    concurrency,
    fork_signature([child_definition]),
    driver,
  ))
}

fn fork_signature(definitions: List(control.Definition)) -> String {
  json.array(definitions, fn(definition) {
    json.array(
      [
        json.string(definition.identity.name),
        json.int(definition.identity.version),
        json.string(definition.signature),
        json.int(definition.max_activations),
      ],
      fn(value) { value },
    )
  })
  |> json.to_string
}

/// Open one admitted fork member with its native runtime. Ordinals start at one.
pub fn branch(
  parent: Handle(context, state, answer),
  activation: Int,
  member: Int,
  runtime: Runtime(child_context, child_state, child_answer),
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  let link = child.Branch(run.id_to_string(parent.id), activation, member)
  attached_child(
    parent,
    runtime,
    link,
    child.branch_id(link.run, activation, member),
  )
}

/// Open a specific child visit, including a completed one, with its native
/// runtime. The child's reciprocal attachment is checked before returning.
pub fn child(
  parent: Handle(context, state, answer),
  activation: Int,
  runtime: Runtime(child_context, child_state, child_answer),
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  let link = child.Parent(run.id_to_string(parent.id), activation)
  attached_child(parent, runtime, link, child.reserved_id(link.run, activation))
}

fn attached_child(
  parent: Handle(context, state, answer),
  runtime: Runtime(child_context, child_state, child_answer),
  link: child.Parent,
  id: String,
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  use _ <- result.try(
    case store.pid(parent.runtime.store), store.pid(runtime.store) {
      Ok(parent_store), Ok(child_store) if parent_store == child_store -> Ok(Nil)
      _, _ ->
        Error(CommandRefused("child runtime does not use the parent store"))
    },
  )
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
  case state.parent == Some(child.attachment(parent)) {
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
  reservation: child_driver.Reservation,
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
      case reservation, state.phase {
        child_driver.Cancel, control.Ended(_) -> Ok(Nil)
        child_driver.Cancel, control.Forking(_, control.ClosingFork(_))
        | child_driver.Cancel, control.WaitingFork(_, control.ClosingFork(_))
        ->
          // Intent already committed: follow cleanup without restarting waits.
          runner.discover(runtime.store, runtime.work, runtime.options, id, 3)
          |> result.replace(Nil)
          |> result.map_error(from_runner)
        child_driver.Cancel, _ ->
          runner.cancel(runtime.store, runtime.work, runtime.options, id, 3)
          |> result.replace(Nil)
          |> result.map_error(from_runner)
        child_driver.Discover, _ | child_driver.Start, _ ->
          // An acknowledged child may be idle inside a nested fork. Inspect
          // it without resetting unchanged waits on every parent observation.
          runner.discover(runtime.store, runtime.work, runtime.options, id, 3)
          |> result.replace(Nil)
          |> result.map_error(from_runner)
      }
    }
    Error(runner.StoreFailed(store.NotFound))
      if reservation == child_driver.Discover
    -> Error(from_runner(runner.StoreFailed(store.NotFound)))
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
      let state = control.State(..state, parent: Some(child.attachment(parent)))
      use #(state, effects) <- result.try(
        case reservation == child_driver.Cancel {
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
        },
      )
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
          reserved_child(runtime, parent, id, input, reservation, tries - 1)
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
        control.WaitingFork(a, _) -> nested_fork_progress(runs, state, a, left)
        control.Joining(a, child) | control.WaitingChild(a, child) ->
          case a.prepared.kind {
            operation.Agent ->
              agent_child.progress(runs, child.Parent(state.run, a.id), child)
              |> result.map_error(CallbackFailed)
            _ ->
              child_progress(
                runs,
                child.Parent(state.run, a.id),
                child,
                left - 1,
              )
          }
        _ -> Ok(child.Working)
      })
      Ok(case state.phase {
        control.AwaitingApproval(_, approval) ->
          child.Approval(approval.requirement)
        control.WaitingSignal(a) -> child.Signal(a.prepared.operation)
        control.WaitingJob(a) -> child.Job(a.prepared.operation)
        control.StoppingJob(_, job.RequestQueued, _)
        | control.StoppingJob(_, job.RequestStarted, _) -> child.Working
        control.StoppingJob(_, _, _) -> child.Cancelled(True)
        control.Blocked(_, problem) -> child.Uncertain(string.inspect(problem))
        control.ChildBlocked(_, _, reason) -> child.Uncertain(reason)
        control.Ended(control.Completed(output)) -> child.Succeeded(output)
        control.Ended(control.Failed(_, fault)) ->
          child.Failed(string.inspect(fault))
        control.Ended(control.Expired(_, control.UnresolvedCancellation(_))) ->
          child.Cancelled(True)
        control.Ended(control.Expired(_, _)) ->
          child.Failed("child deadline expired")
        control.Ended(control.Exhausted(_)) ->
          child.Failed("child activation limit reached")
        control.Ended(control.Cancelled(_, control.UnresolvedCancellation(_))) ->
          child.Cancelled(True)
        control.Ended(control.Cancelled(_, _)) -> child.Cancelled(False)
        _ ->
          case nested {
            child.Approval(_)
            | child.AgentInput(..)
            | child.Signal(_)
            | child.Job(_)
            | child.Fork(_)
            | child.Uncertain(_) -> nested
            child.FinishedUncertain(reason) -> child.Uncertain(reason)
            _ -> child.Working
          }
      })
    }
  }
}

fn nested_fork_progress(
  runs: store.Store,
  state: control.State,
  a: control.Activation,
  left: Int,
) -> Result(child.Progress, Error) {
  use members <- result.try(
    control.current_fork(state, a.id)
    |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
  )
  use active <- result.try(
    list.try_map(scope.unsettled(members), fn(ref) {
      use member <- result.try(
        scope.member(members, ref)
        |> result.map_error(fn(error) { CommandRefused(string.inspect(error)) }),
      )
      let id = child.branch_id(state.run, a.id, ref.member)
      // A parked scope has acknowledged children; absence is not fresh work.
      use _ <- result.try(store.get(runs, id) |> result.map_error(StoreFailed))
      use progress <- result.map(child_progress(
        runs,
        child.Branch(state.run, a.id, ref.member),
        id,
        left - 1,
      ))
      progress == child.Working
      || member.status != fork.Admitted(fork_driver.progress(progress))
    }),
  )
  case list.any(active, fn(value) { value }) {
    True -> Ok(child.Working)
    False -> Ok(child.Fork(scope.snapshot(members)))
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
  start_root(runtime, id, initial, None)
}

/// Starts a root with durable admission limits shared by graphs and agents
/// throughout its managed family. A new attempt spends new work capacity;
/// acknowledging an existing reservation never spends twice.
pub fn start_with_budget(
  runtime: Runtime(context, state, answer),
  id: run.RunId,
  initial: state,
  limits: budget.Limits,
) -> Result(Handle(context, state, answer), Error) {
  use _ <- result.try(
    reservations.new(limits)
    |> result.replace_error(CommandRefused("invalid family budget limits")),
  )
  use Nil <- result.try(case store.supports_family_budget(runtime.store) {
    True -> Ok(Nil)
    False ->
      Error(CommandRefused("family budgets require agent record writer 7"))
  })
  start_root(
    runtime,
    id,
    initial,
    Some(reservations.Declaration(limits, False)),
  )
}

fn start_root(
  runtime: Runtime(context, state, answer),
  id: run.RunId,
  initial: state,
  declaration: option.Option(reservations.Declaration),
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
  let state = control.State(..state, family_budget: declaration)
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
    | CancellingJob(_, job.RequestQueued, _), True
    | CancellingJob(_, job.RequestStarted, _), True
    | CancellingChild(_, _), True
    | Child(_, child.Working), True
    | Child(_, child.Succeeded(_)), True
    | Child(_, child.InvalidOutput(..)), True
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

/// Inspect an admitted job wait once. Pending progress leaves its record
/// unchanged; a checked outcome commits its route before successor work starts.
/// Repeating an accepted reference reuses the saved result without another read.
/// After owned cancellation, terminal evidence settles the canceled run without
/// invoking its route. An accepted, refused or uncertain stop may be observed.
pub fn poll_job(
  handle: Handle(context, state, answer),
  reference: job.Reference,
) -> Result(Snapshot(state, answer), Error) {
  use _ <- result.try(case reference.run == handle.id {
    True -> Ok(Nil)
    False -> Error(CommandRefused("job reference belongs to another run"))
  })
  let runtime = handle.runtime
  use _ <- result.try(
    runner.observe_job(
      runtime.store,
      runtime.work,
      runtime.options,
      reference,
      3,
    )
    |> result.map_error(from_runner),
  )
  read(handle)
}

/// Cancellation does not require the currently deployed definition to fit the
/// record. A lost or unresponsive owner is fenced by a committed cancellation;
/// effects whose results were not saved remain explicitly unresolved.
/// For an admitted owned job this records intent, not proof that remote work
/// stopped. Its request runs only with compatible code and a committed fence;
/// manual or scheduled observation must confirm the terminal outcome.
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
/// A due wait instead commits and returns `Failed(DeadlineExpired(due))`;
/// that snapshot acknowledges expiration, not acceptance of the supplied value.
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
      use due <- result.try(
        runner.wait_due(runtime.store, activation)
        |> result.map_error(from_runner),
      )
      use event <- result.try(case due {
        Some(now) ->
          Ok(control.ExpireWait(control.reference(state, activation), now))
        None -> signal_event(runtime, state, activation, output)
      })
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
          deliver_with(handle, reference, output, tries - 1)
        Error(error) -> Error(from_runner(error))
      }
    }
  }
}

fn signal_event(
  runtime: Runtime(context, state, answer),
  state: control.State,
  activation: control.Activation,
  output: String,
) -> Result(control.Event, Error) {
  use accepted <- result.try(
    bounded.call(runtime.options.callback_timeout, fn() {
      runtime.work.accept(state, activation, output)
    })
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  use decision <- result.try(accepted |> result.map_error(DefinitionRejected))
  use due <- result.map(
    runner.wait_due(runtime.store, activation)
    |> result.map_error(from_runner),
  )
  case due {
    Some(now) -> control.ExpireWait(control.reference(state, activation), now)
    None ->
      control.Signaled(activation.id, activation.attempt, output, decision)
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
  use #(event, body) <- result.try(case rejection {
    Some(reason) -> Ok(#(control.Rejected(reference, reason), None))
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
        Ok(live.Admission(decision, body)) ->
          Ok(#(control.Approved(reference, Ok(decision)), Some(body)))
        Error(runner.PolicyRejected(reason)) ->
          Ok(#(control.Approved(reference, Error(reason)), None))
        Error(runner.BudgetLimited(reason)) ->
          Ok(#(
            control.BudgetRefused(control.reference(state, activation), reason),
            None,
          ))
        Error(runner.BudgetUnavailable(reason)) ->
          Error(StoreFailed(store.Unavailable(reason)))
      }
  })
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
    control.Ended(control.Cancelled(a, control.UnresolvedCancellation(_)))
    | control.Ended(control.Expired(a, control.UnresolvedCancellation(_))) ->
      Ok(#(a, True))
    _ -> Error(CommandRefused("no unresolved result"))
  })
  use _ <- result.try(
    case
      cancelled
      && {
        activation.prepared.kind == operation.Subgraph
        || activation.prepared.kind == operation.Agent
      }
    {
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
  let due = fn() {
    case cancelled {
      True -> Ok(None)
      False ->
        runner.child_due(runtime.store, state)
        |> result.map(fn(due) { option.map(due, fn(entry) { entry.1 }) })
        |> result.map_error(from_runner)
    }
  }
  use before <- result.try(due())
  use event <- result.try(case before {
    Some(now) ->
      Ok(control.ExpireWait(control.reference(state, activation), now))
    None -> {
      let accepted =
        bounded.call(runtime.options.callback_timeout, fn() {
          case cancelled {
            True -> {
              use _ <- result.map(runtime.work.check_output(activation, output))
              control.CancelledResult(
                control.reference(state, activation),
                output,
              )
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
        |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) })
        |> result.try(fn(event) {
          event |> result.map_error(DefinitionRejected)
        })
      use after <- result.try(due())
      case after {
        Some(now) ->
          Ok(control.ExpireWait(control.reference(state, activation), now))
        None -> accepted
      }
    }
  })
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
    control.WaitingFork(a, mode) -> {
      use active <- result.try(
        runner.fork_has_activity(runtime.store, runtime.work, state, a)
        |> result.map_error(CallbackFailed),
      )
      use saved <- result.try(
        list.find(state.forks, fn(saved) { saved.occurrence.activation == a.id })
        |> result.replace_error(CorruptRecord("missing fork scope")),
      )
      Ok(case active {
        True -> Working
        False ->
          Fork(saved, case mode {
            control.JoiningFork -> None
            control.ClosingFork(cause) -> Some(cause)
          })
      })
    }
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
        driver.read(child.Parent(state.run, a.id), id, child_driver.Observe)
        |> result.map_error(CallbackFailed),
      )
      Ok(Child(
        child.Reference(run.issued(state.run), a.id, run.issued(id)),
        progress,
      ))
    }
    control.StoppingChild(a, id, cause) ->
      Ok(case runner.driven(entry, state) {
        False -> Unattended
        True ->
          CancellingChild(
            child.Reference(run.issued(state.run), a.id, run.issued(id)),
            cause,
          )
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
              case
                driver.read(
                  child.Parent(state.run, a.id),
                  id,
                  child_driver.Observe,
                )
              {
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
    control.PreparingFork(_)
    | control.Forking(..)
    | control.Ready(_)
    | control.ArmingWait(_)
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
    control.WaitingJob(a) ->
      Ok(
        AwaitingJob(job.Reference(
          run.issued(state.run),
          a.id,
          a.attempt,
          a.prepared.operation,
        )),
      )
    control.StoppingJob(a, progress, cause) ->
      Ok(case control.needs_runner(state) && !runner.driven(entry, state) {
        True -> Unattended
        False ->
          CancellingJob(
            job.Reference(
              run.issued(state.run),
              a.id,
              a.attempt,
              a.prepared.operation,
            ),
            progress,
            cause,
          )
      })
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
    control.Ended(control.Expired(a, disposition)) -> {
      let assert Some(due) = a.deadline
      Ok(Expired(due, public_cancellation(state, a, disposition)))
    }
    control.Ended(control.Cancelled(a, cancellation)) ->
      Ok(Cancelled(public_cancellation(state, a, cancellation)))
  })
  let current = current_action(state)
  Ok(Snapshot(
    entry.revision,
    value,
    status,
    current,
    public_receipts(state),
    case state.phase {
      control.WaitingSignal(a)
      | control.WaitingJob(a)
      | control.StoppingJob(a, _, _)
      | control.PreparingFork(a)
      | control.Forking(a, _)
      | control.WaitingFork(a, _)
      | control.Joining(a, _)
      | control.WaitingChild(a, _)
      | control.ChildBlocked(a, _, _)
      | control.StoppingChild(a, _, _)
      | control.Blocked(a, _)
      | control.Ended(control.Failed(a, control.DeadlineExpired(_)))
      | control.Ended(control.Expired(a, _)) -> a.deadline
      _ -> None
    },
    state.forks,
  ))
}

fn public_cancellation(
  state: control.State,
  a: control.Activation,
  cancellation: control.Cancellation,
) -> Cancellation {
  case cancellation {
    control.AfterFork -> ForkSettled(a.id)
    control.BeforeStart -> BeforeStart
    control.JobDetached ->
      JobDetached(job.Reference(
        run.issued(state.run),
        a.id,
        a.attempt,
        a.prepared.operation,
      ))
    control.JobStopped ->
      JobStopped(job.Reference(
        run.issued(state.run),
        a.id,
        a.attempt,
        a.prepared.operation,
      ))
    control.AfterResult -> AfterResult
    control.AfterFailure(fault) -> AfterFailure(failure(fault))
    control.AfterChild(id) ->
      ChildSettled(child.Reference(run.issued(state.run), a.id, run.issued(id)))
    control.UnresolvedCancellation(problem)
      if {
        a.prepared.kind == operation.Subgraph
        || a.prepared.kind == operation.Agent
      }
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
  }
}

fn current_action(state: control.State) -> option.Option(Action) {
  case state.phase {
    control.Ready(a)
    | control.Queued(a)
    | control.Running(a)
    | control.AwaitingApproval(a, _)
    | control.WaitingSignal(a)
    | control.ArmingWait(a)
    | control.WaitingJob(a)
    | control.StoppingJob(a, _, _)
    | control.PreparingFork(a)
    | control.Forking(a, _)
    | control.WaitingFork(a, _)
    | control.Joining(a, _)
    | control.WaitingChild(a, _)
    | control.ChildBlocked(a, _, _)
    | control.StoppingChild(a, _, _)
    | control.Blocked(a, _)
    | control.Stopping(a)
    | control.Ended(control.Failed(a, _))
    | control.Ended(control.Expired(a, _))
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
}

fn public_receipts(state: control.State) -> List(Receipt) {
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
  })
}

fn failure(fault: control.Fault) -> Failure {
  case fault {
    control.DeadlineExpired(due) -> DeadlineExpired(due)
    control.Denied(reason) -> Denied(reason)
    control.PolicyFailed(reason) -> PolicyFailed(reason)
    control.OperationFailed(reason) -> OperationFailed(reason)
    control.FamilyBudget(reason) -> FamilyBudget(reason)
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
