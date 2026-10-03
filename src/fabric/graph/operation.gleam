//// A graph operation has native input and output types and an explicit
//// interrupted-effect contract. Adapters for tools, models and classifiers
//// implement this same boundary; it has no workflow-runtime dependency.
////
//// A body's typed errors are classified with the agent's `tool.Failure`:
//// `tool.Explain` is a definite failure (the run fails with
//// `graph.OperationFailed`), `tool.Uncertain` an effect that may have
//// happened (the run is `graph.Blocked` until it is reconciled).
////
//// Every wait (a signal, a job, a managed child or a fork) is bounded: 7
//// days after policy admission by default, `with_deadline` to change it,
//// `run.Infinity` to wait without one. `definition.build` checks every
//// setting of an operation and reports every problem at once.

import fabric/graph/job
import fabric/graph/signal
import fabric/internal/graph/contract
import fabric/internal/graph/observer
import fabric/internal/graph/signal as signal_contract
import fabric/run
import fabric/tool
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}
import sinal/correlation.{type Correlation}

pub type Recovery {
  /// A started body without a saved result requires reconciliation.
  RequireReconciliation
  /// The application guarantees that repeating the body is safe, for example
  /// by using the stable run and activation as an external idempotency key.
  /// The bound includes the initial attempt. It is not a timeout classifier.
  ReplayInterrupted(max_attempts: Int)
}

/// The call an operation body answers. Read it by label: Fabric may add
/// fields.
///
/// `run` and `activation` identify one logical operation across attempts;
/// a new visit to the same node always has a different activation.
/// `correlation` is the run's (see `graph.start`): pass it to the packages
/// the body calls (`http_gun.with_correlation`, say), so that their events
/// join the run's.
pub type Invocation {
  Invocation(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    correlation: Correlation,
  )
}

/// Why an admitted operation's lifetime is being stopped. This does not imply
/// that a remote effect stopped or that its cancellation was acknowledged.
pub type StopReason {
  CancellationRequested
  DeadlineReached(due: Int)
}

pub type Kind {
  Activity
  Signal
  Job(polling: job.Polling)
  OwnedJob(polling: job.Polling)
  Subgraph
  Agent
  Fork(max_members: Int, concurrency: Int, signature: String)
}

/// A typed operation bound to its body or wait. Build one with `new`,
/// `await_signal`, `await_job` or `own_job`.
pub type Operation(context, input, output) =
  contract.Operation(context, input, output, Kind, Recovery, Invocation, Error)

/// A setting of an operation that `definition.build` refuses.
pub type ConfigurationError {
  /// `with_replay` with fewer than one attempt.
  InvalidAttemptBound(Int)
  /// `with_replay` on an operation that is not an activity.
  ReplayRequiresActivity
  /// A `with_deadline` duration under 1 ms or over 2^32 - 1 ms.
  InvalidDeadline(Duration)
  /// `with_deadline` on an activity: its body is bounded by the runtime's
  /// operation timeout instead (`graph.with_operation_timeout`).
  DeadlineRequiresWait
  /// A `job.with_poll_interval` under 1 ms or over 2^32 - 1 ms.
  InvalidPollInterval(Duration)
}

pub type Error {
  NotExecutable
  ObservationFailed(String)
  InputEncodingFailed(codec.EncodeError)
  InputDecodingFailed(String)
  BodyFailed(tool.Failure)
  /// A native value could not be encoded; its printed representation is
  /// diagnostic evidence only, never a result eligible for routing.
  OutputEncodingFailed(evidence: String, error: codec.EncodeError)
  OutputDecodingFailed(String)
}

/// An activity: `perform` runs once policy admits it, in its own task,
/// bounded by the runtime's operation timeout. `classify` says what each
/// typed error means (`tool.Explain` or `tool.Uncertain`). A body crash, a
/// timeout or a lost task is an uncertain effect, never a definite
/// failure; a runner lost while the body ran replays it when the operation
/// allows (`with_replay`).
pub fn new(
  identity: run.DefinitionId,
  input: Codec(input),
  output: Codec(output),
  perform: fn(context, Invocation, input) -> Result(output, error),
  classify: fn(error) -> tool.Failure,
) -> Operation(context, input, output) {
  let invoke = fn(context, invocation, text) {
    use value <- result.try(
      codec.decode_json(input, text)
      |> result.map_error(fn(error) {
        InputDecodingFailed(codec.describe_decode_error(error))
      }),
    )
    use result <- result.try(
      perform(context, invocation, value)
      |> result.map_error(fn(error) { BodyFailed(classify(error)) }),
    )
    codec.encode_json(output, result)
    |> result.map_error(fn(error) {
      OutputEncodingFailed(string.inspect(result), error)
    })
  }
  contract.new(
    identity,
    input,
    output,
    Activity,
    RequireReconciliation,
    contract.Parts(..refusing(), invoke:),
  )
}

/// A wait retains its typed request as input, then accepts a value with the
/// signal's output contract. Policy gates publishing the wait. No task body
/// is started, and the waiting run holds no runner process.
pub fn await_signal(
  input: Codec(input),
  signal: signal.Signal(output),
) -> Operation(context, input, output) {
  contract.new(
    signal.identity(signal),
    input,
    signal_contract.codec(signal),
    Signal,
    RequireReconciliation,
    refusing(),
  )
}

/// Retain a typed external receipt and wait for a checked business outcome.
/// Observation is read-only; cancellation detaches without canceling remote work.
pub fn await_job(
  job_observer: job.Observer(context, receipt, output),
) -> Operation(context, receipt, output) {
  contract.new(
    observer.identity(job_observer),
    observer.receipt(job_observer),
    observer.output(job_observer),
    Job(observer.polling(job_observer)),
    RequireReconciliation,
    contract.Parts(..refusing(), read_job: observer.reader(job_observer)),
  )
}

/// Admit ownership of an existing job, including cancellation authority.
/// `request` acknowledges a stop request; the observer must confirm a terminal
/// outcome separately. Interrupted requests are never automatically
/// repeated. `classify` is as for `new`: `tool.Explain` refuses the stop,
/// `tool.Uncertain` leaves it uncertain.
pub fn own_job(
  job_observer: job.Observer(context, receipt, output),
  request: fn(context, Invocation, receipt) -> Result(Nil, error),
  classify: fn(error) -> tool.Failure,
) -> Operation(context, receipt, output) {
  let receipt = observer.receipt(job_observer)
  contract.new(
    observer.identity(job_observer),
    receipt,
    observer.output(job_observer),
    OwnedJob(observer.polling(job_observer)),
    RequireReconciliation,
    contract.Parts(
      ..refusing(),
      read_job: observer.reader(job_observer),
      cancel_job: fn(context, invocation, encoded) {
        use value <- result.try(
          codec.decode_json(receipt, encoded)
          |> result.map_error(fn(error) {
            InputDecodingFailed(codec.describe_decode_error(error))
          }),
        )
        request(context, invocation, value)
        |> result.map_error(fn(error) { BodyFailed(classify(error)) })
      },
    ),
  )
}

/// Parts that refuse everything: an operation fills in those of its kind.
fn refusing() -> contract.Parts(context, Invocation, Error) {
  contract.Parts(
    invoke: fn(_, _, _) { Error(NotExecutable) },
    read_job: fn(_, _) { Error("operation is not a job observer") },
    cancel_job: fn(_, _, _) { Error(NotExecutable) },
    child: Error(NotExecutable),
    fork: Error(NotExecutable),
  )
}

pub fn kind(operation: Operation(context, input, output)) -> Kind {
  contract.kind(operation)
}

/// Lets the runtime start an activity's body again, up to `max_attempts`
/// starts in all, when its runner was lost while it ran (a restart, a lost
/// node). Use it only for a body whose effect is safe to repeat (keyed by
/// `Invocation.run` and `activation`). `definition.build` refuses it on any
/// other kind of operation (`ReplayRequiresActivity`) and with fewer than
/// one attempt (`InvalidAttemptBound`).
pub fn with_replay(
  operation: Operation(context, input, output),
  max_attempts: Int,
) -> Operation(context, input, output) {
  contract.with_recovery(operation, ReplayInterrupted(max_attempts))
}

pub fn identity(
  operation: Operation(context, input, output),
) -> run.DefinitionId {
  contract.identity(operation)
}

/// Bounds an admitted wait (a signal, a job, a managed child or a fork):
/// `run.After(duration)`, from 1 ms to 2^32 - 1 ms, or `run.Infinity` to
/// wait without a deadline. The default is 7 days. The store's clock starts
/// the duration once policy (and any approval) admits the wait; the due
/// time is stored, so it survives restarts. A wait past its deadline fails
/// (`graph.DeadlineExpired`); owned jobs, children and forks are stopped
/// first, and their cleanup progress is kept.
///
/// The deadline is part of the operation's stored contract: a stored run
/// continues only under the deadline it was admitted with. A run stored
/// without one (before waits had a default, or under `run.Infinity`) keeps
/// none. Seven days set explicitly is the default. `definition.build`
/// refuses a deadline on an activity (`DeadlineRequiresWait`) or out of
/// range (`InvalidDeadline`).
pub fn with_deadline(
  operation: Operation(context, input, output),
  within: run.Timeout,
) -> Operation(context, input, output) {
  contract.with_deadline(operation, contract.SetDeadline(within))
}

pub fn recovery(operation: Operation(context, input, output)) -> Recovery {
  contract.recovery(operation)
}

/// The codec of the operation's input, for reading `graph.Receipt.input_json`.
pub fn input_codec(
  operation: Operation(context, input, output),
) -> Codec(input) {
  contract.input(operation)
}

/// The codec of the operation's output, for reading
/// `graph.Receipt.output_json`.
pub fn output_codec(
  operation: Operation(context, input, output),
) -> Codec(output) {
  contract.output(operation)
}
