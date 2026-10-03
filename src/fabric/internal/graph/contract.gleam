//// The representation behind `fabric/graph/operation.Operation`: its
//// identity, codecs and recovery contract, plus what the runtime runs.
////
//// It is generic over the kind, recovery, invocation and error types so
//// that `fabric/graph/operation` can define them and still alias this
//// type. The constructors in `fabric/graph/operation` and
//// `fabric/internal/graph/managed` build every function below.

import fabric/graph/job
import fabric/internal/graph/child_driver
import fabric/internal/graph/fork_driver
import fabric/run
import json/blueprint/codec.{type Codec}

/// The deadline a wait asks for: the runtime's default (7 days), or a
/// `run.Timeout` set with `operation.with_deadline`. `definition.build`
/// checks it.
pub type Deadline {
  DefaultDeadline
  SetDeadline(run.Timeout)
}

pub opaque type Operation(
  context,
  input,
  output,
  kind,
  recovery,
  invocation,
  error,
) {
  Operation(
    identity: run.DefinitionId,
    input: Codec(input),
    output: Codec(output),
    kind: kind,
    recovery: recovery,
    deadline: Deadline,
    parts: Parts(context, invocation, error),
  )
}

/// What the runtime runs for an operation of each kind; each part that does
/// not apply to the kind refuses.
pub type Parts(context, invocation, error) {
  Parts(
    /// An activity's body over encoded input, returning encoded output.
    invoke: fn(context, invocation, String) -> Result(String, error),
    /// A job observer's read of an encoded receipt.
    read_job: fn(context, String) -> Result(job.Progress(String), String),
    /// An owned job's stop request for an encoded receipt.
    cancel_job: fn(context, invocation, String) -> Result(Nil, error),
    child: Result(child_driver.Driver, error),
    fork: Result(fork_driver.Driver, error),
  )
}

pub fn new(
  identity: run.DefinitionId,
  input: Codec(input),
  output: Codec(output),
  kind: kind,
  recovery: recovery,
  parts: Parts(context, invocation, error),
) -> Operation(context, input, output, kind, recovery, invocation, error) {
  Operation(
    identity:,
    input:,
    output:,
    kind:,
    recovery:,
    deadline: DefaultDeadline,
    parts:,
  )
}

pub fn with_recovery(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
  recovery: recovery,
) -> Operation(context, input, output, kind, recovery, invocation, error) {
  Operation(..operation, recovery:)
}

pub fn with_deadline(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
  deadline: Deadline,
) -> Operation(context, input, output, kind, recovery, invocation, error) {
  Operation(..operation, deadline:)
}

pub fn identity(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> run.DefinitionId {
  operation.identity
}

pub fn input(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> Codec(input) {
  operation.input
}

pub fn output(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> Codec(output) {
  operation.output
}

pub fn kind(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> kind {
  operation.kind
}

pub fn recovery(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> recovery {
  operation.recovery
}

/// The deadline an admitted wait asked for.
pub fn deadline(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> Deadline {
  operation.deadline
}

/// The owning runner must have committed admission and the start fence.
/// A non-activity callback must not capture its managed child runtime: BEAM
/// copies closure environments when handing work to another process.
pub fn invoker(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> fn(context, invocation, String) -> Result(String, error) {
  operation.parts.invoke
}

pub fn job_reader(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> fn(context, String) -> Result(job.Progress(String), String) {
  operation.parts.read_job
}

pub fn job_canceller(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> fn(context, invocation, String) -> Result(Nil, error) {
  operation.parts.cancel_job
}

pub fn child_driver(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> Result(child_driver.Driver, error) {
  operation.parts.child
}

pub fn fork_driver(
  operation: Operation(
    context,
    input,
    output,
    kind,
    recovery,
    invocation,
    error,
  ),
) -> Result(fork_driver.Driver, error) {
  operation.parts.fork
}
