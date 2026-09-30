//// A graph operation has native input and output types and an explicit
//// interrupted-effect contract. Adapters for tools, models and classifiers
//// implement this same boundary; it has no workflow-runtime dependency.

import fabric/graph/signal
import fabric/internal/graph/child_driver
import fabric/run
import gleam/result
import gleam/string
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

pub type Kind {
  Activity
  Signal
  Subgraph
  Agent
}

type Implementation(context, input, output) {
  Perform(fn(context, Invocation, input) -> Result(output, Failure))
  WaitForSignal
  Managed(Kind, child_driver.Driver)
}

pub opaque type Operation(context, input, output) {
  Operation(
    identity: run.Identity,
    input: Codec(input),
    output: Codec(output),
    recovery: Recovery,
    implementation: Implementation(context, input, output),
  )
}

pub type ConfigurationError {
  InvalidAttemptBound(Int)
  ReplayRequiresActivity
}

pub type Error {
  NotExecutable
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
  identity: run.Identity,
  input: Codec(input),
  output: Codec(output),
  perform: fn(context, Invocation, input) -> Result(output, error),
  classify: fn(error) -> Failure,
) -> Operation(context, input, output) {
  Operation(
    identity,
    input,
    output,
    RequireReconciliation,
    Perform(fn(context, invocation, value) {
      perform(context, invocation, value) |> result.map_error(classify)
    }),
  )
}

/// A wait retains its typed request as input, then accepts a value with the
/// signal's output contract. Policy gates publishing the wait. No task body
/// is started, and the waiting run holds no runner process.
pub fn await_signal(
  input: Codec(input),
  signal: signal.Signal(output),
) -> Operation(context, input, output) {
  Operation(
    signal.identity(signal),
    input,
    signal.output(signal),
    RequireReconciliation,
    WaitForSignal,
  )
}

pub fn kind(operation: Operation(context, input, output)) -> Kind {
  case operation.implementation {
    Perform(_) -> Activity
    WaitForSignal -> Signal
    Managed(kind, _) -> kind
  }
}

pub fn with_replay(
  operation: Operation(context, input, output),
  max_attempts: Int,
) -> Result(Operation(context, input, output), ConfigurationError) {
  case kind(operation), max_attempts >= 1 {
    Signal, _ | Subgraph, _ | Agent, _ -> Error(ReplayRequiresActivity)
    Activity, True ->
      Ok(Operation(..operation, recovery: ReplayInterrupted(max_attempts)))
    Activity, False -> Error(InvalidAttemptBound(max_attempts))
  }
}

pub fn identity(operation: Operation(context, input, output)) -> run.Identity {
  operation.identity
}

@internal
pub fn subgraph(
  identity: run.Identity,
  input: Codec(input),
  output: Codec(output),
  driver: child_driver.Driver,
) -> Operation(context, input, output) {
  Operation(
    identity,
    input,
    output,
    RequireReconciliation,
    Managed(Subgraph, driver),
  )
}

@internal
pub fn agent(
  identity: run.Identity,
  input: Codec(input),
  output: Codec(output),
  driver: child_driver.Driver,
) -> Operation(context, input, output) {
  Operation(
    identity,
    input,
    output,
    RequireReconciliation,
    Managed(Agent, driver),
  )
}

@internal
pub fn child_driver(
  operation: Operation(context, input, output),
) -> Result(child_driver.Driver, Error) {
  case operation.implementation {
    Managed(_, driver) -> Ok(driver)
    _ -> Error(NotExecutable)
  }
}

pub fn recovery(operation: Operation(context, input, output)) -> Recovery {
  operation.recovery
}

@internal
pub fn input_codec(
  operation: Operation(context, input, output),
) -> Codec(input) {
  operation.input
}

@internal
pub fn output_codec(
  operation: Operation(context, input, output),
) -> Codec(output) {
  operation.output
}

/// A non-activity callback must not capture its managed child runtime. BEAM
/// copies closure environments when handing work to another process.
@internal
pub fn invoker(
  operation: Operation(context, input, output),
) -> fn(context, Invocation, String) -> Result(String, Error) {
  case operation.implementation {
    Perform(_) -> fn(context, invocation, text) {
      invoke(operation, context, invocation, text)
    }
    WaitForSignal | Managed(..) -> fn(_, _, _) { Error(NotExecutable) }
  }
}

@internal
pub fn encode_input(
  operation: Operation(context, input, output),
  input: input,
) -> Result(String, Error) {
  codec.encode_json(operation.input, input)
  |> result.map_error(InputEncodingFailed)
}

@internal
pub fn check_input(
  operation: Operation(context, input, output),
  text: String,
) -> Result(Nil, Error) {
  decode_input(operation, text) |> result.replace(Nil)
}

fn decode_input(
  operation: Operation(context, input, output),
  text: String,
) -> Result(input, Error) {
  codec.decode_json(operation.input, text)
  |> result.map_error(fn(error) {
    InputDecodingFailed(codec.render_json_decode_error(error))
  })
}

@internal
pub fn decode_output(
  operation: Operation(context, input, output),
  text: String,
) -> Result(output, Error) {
  codec.decode_json(operation.output, text)
  |> result.map_error(fn(error) {
    OutputDecodingFailed(codec.render_json_decode_error(error))
  })
}

/// The owning runner must have committed admission and the start fence.
@internal
pub fn invoke(
  operation: Operation(context, input, output),
  context: context,
  invocation: Invocation,
  text: String,
) -> Result(String, Error) {
  use perform <- result.try(case operation.implementation {
    Perform(perform) -> Ok(perform)
    WaitForSignal | Managed(..) -> Error(NotExecutable)
  })
  use input <- result.try(decode_input(operation, text))
  use output <- result.try(
    perform(context, invocation, input)
    |> result.map_error(BodyFailed),
  )
  codec.encode_json(operation.output, output)
  |> result.map_error(fn(error) {
    OutputEncodingFailed(string.inspect(output), error)
  })
}
