//// A graph operation has native input and output types and an explicit
//// interrupted-effect contract. Adapters for tools, models and classifiers
//// implement this same boundary; it has no workflow-runtime dependency.

import fabric/graph/job
import fabric/graph/signal
import fabric/internal/graph/contract
import fabric/internal/graph/observer
import fabric/internal/graph/signal as signal_contract
import fabric/run
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}

pub type Recovery {
  /// A started body without a saved result requires reconciliation.
  RequireReconciliation
  /// The application guarantees that repeating the body is safe, for example
  /// by using the stable run and activation as an external idempotency key.
  /// The bound includes the initial attempt. It is not a timeout classifier.
  ReplayInterrupted(max_attempts: Int)
}

pub type Invocation {
  /// `run` and `activation` identify one logical operation across attempts.
  /// A new visit to the same node always has a different activation.
  Invocation(run: run.RunId, activation: Int, attempt: Int)
}

pub type Failure {
  DefiniteFailure(detail: String)
  UncertainEffect(evidence: String)
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

pub type ConfigurationError {
  InvalidAttemptBound(Int)
  ReplayRequiresActivity
  /// Under 1 ms or over 2^32 - 1 ms.
  InvalidDeadline(Duration)
  DeadlineRequiresWait
}

pub type Error {
  NotExecutable
  ObservationFailed(String)
  InputEncodingFailed(codec.EncodeError)
  InputDecodingFailed(String)
  BodyFailed(Failure)
  /// A native value could not be encoded; its printed representation is
  /// diagnostic evidence only, never a result eligible for routing.
  OutputEncodingFailed(evidence: String, error: codec.EncodeError)
  OutputDecodingFailed(String)
}

/// Error classification remains application-specific. A body crash or lost
/// task is handled by the runner as uncertainty, not a definite failure.
pub fn new(
  identity: run.DefinitionId,
  input: Codec(input),
  output: Codec(output),
  perform: fn(context, Invocation, input) -> Result(output, error),
  classify: fn(error) -> Failure,
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
/// outcome separately. Interrupted requests are never automatically repeated.
pub fn own_job(
  job_observer: job.Observer(context, receipt, output),
  request: fn(context, Invocation, receipt) -> Result(Nil, error),
  classify: fn(error) -> Failure,
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

pub fn with_replay(
  operation: Operation(context, input, output),
  max_attempts: Int,
) -> Result(Operation(context, input, output), ConfigurationError) {
  case kind(operation), max_attempts >= 1 {
    Signal, _
    | Job(_), _
    | OwnedJob(_), _
    | Subgraph, _
    | Agent, _
    | Fork(..), _
    -> Error(ReplayRequiresActivity)
    Activity, True ->
      Ok(contract.with_recovery(operation, ReplayInterrupted(max_attempts)))
    Activity, False -> Error(InvalidAttemptBound(max_attempts))
  }
}

pub fn identity(
  operation: Operation(context, input, output),
) -> run.DefinitionId {
  contract.identity(operation)
}

/// Bound an admitted signal, job, managed child or fork by `within`, from
/// 1 ms to 2^32 - 1 ms. The backend clock starts the duration after policy
/// approval; the due time survives restart. Owned jobs, children and forks
/// retain cleanup progress after expiration.
///
/// A wait without a deadline is unbounded. The deadline is part of the
/// operation's persisted contract, so a stored run continues only under the
/// deadline it was admitted with.
pub fn with_deadline(
  operation: Operation(context, input, output),
  within: Duration,
) -> Result(Operation(context, input, output), ConfigurationError) {
  let ms = duration.to_milliseconds(within)
  case kind(operation), ms > 0 && ms <= 4_294_967_295 {
    Signal, True
    | Job(_), True
    | OwnedJob(_), True
    | Subgraph, True
    | Agent, True
    | Fork(..), True
    -> Ok(contract.with_deadline(operation, Some(ms)))
    Signal, False
    | Job(_), False
    | OwnedJob(_), False
    | Subgraph, False
    | Agent, False
    | Fork(..), False
    -> Error(InvalidDeadline(within))
    _, _ -> Error(DeadlineRequiresWait)
  }
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
