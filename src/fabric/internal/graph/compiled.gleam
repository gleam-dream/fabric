//// The representation behind `fabric/graph/definition.Definition`: a built
//// graph, as the functions the runtime calls. `fabric/graph/definition`
//// builds every function over its own nodes. It is generic over the error
//// type so that `fabric/graph/definition` can define it and still alias
//// this type.

import fabric/graph/job
import fabric/graph/operation.{type Invocation}
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as control
import fabric/internal/graph/fork_driver
import json/blueprint/codec.{type Codec}

pub opaque type Definition(context, state, answer, error) {
  Definition(
    identity: control.Definition,
    state: Codec(state),
    answer: Codec(answer),
    /// One closure over the built graph, so that copying a definition to
    /// another process copies the graph once: the runtime copies closure
    /// environments without sharing, and a managed child's driver holds
    /// the child's definition.
    parts: fn() -> Parts(context, state, answer, error),
  )
}

pub type Parts(context, state, answer, error) {
  Parts(
    decode_state: fn(String) -> Result(state, error),
    decode_answer: fn(String) -> Result(answer, error),
    prepare: fn(state) -> Result(#(String, control.Prepared), error),
    /// Only the fenced runner calls this, after persisting the admitted start.
    invoke: fn(context, Invocation, control.Prepared) -> Result(String, error),
    observe_job: fn(context, control.Prepared) ->
      Result(job.Progress(String), error),
    cancel_job: fn(context, Invocation, control.Prepared) -> Result(Nil, error),
    accept: fn(String, control.Prepared, String) ->
      Result(control.Decision, error),
    /// Read-only compatibility check of a saved record.
    validate: fn(control.State) -> Result(Nil, error),
    check_join: fn(control.State, control.Activation, String) ->
      Result(Nil, error),
    check_output: fn(control.Prepared, String) -> Result(Nil, error),
    detach_children: fn() -> Detached(context, state, answer, error),
  )
}

/// A definition whose nodes no longer carry their managed child and fork
/// drivers, with those drivers looked up by prepared node instead.
pub type Detached(context, state, answer, error) {
  Detached(
    definition: Definition(context, state, answer, error),
    child: fn(control.Prepared) -> Result(child_driver.Driver, error),
    fork: fn(control.Prepared) -> Result(fork_driver.Driver, error),
  )
}

pub fn new(
  identity: control.Definition,
  state: Codec(state),
  answer: Codec(answer),
  parts: fn() -> Parts(context, state, answer, error),
) -> Definition(context, state, answer, error) {
  Definition(identity:, state:, answer:, parts:)
}

pub fn identity(
  definition: Definition(context, state, answer, error),
) -> control.Definition {
  definition.identity
}

pub fn state_codec(
  definition: Definition(context, state, answer, error),
) -> Codec(state) {
  definition.state
}

pub fn answer_codec(
  definition: Definition(context, state, answer, error),
) -> Codec(answer) {
  definition.answer
}

pub fn decode_state(
  definition: Definition(context, state, answer, error),
  text: String,
) -> Result(state, error) {
  definition.parts().decode_state(text)
}

pub fn decode_answer(
  definition: Definition(context, state, answer, error),
  text: String,
) -> Result(answer, error) {
  definition.parts().decode_answer(text)
}

pub fn prepare(
  definition: Definition(context, state, answer, error),
  initial: state,
) -> Result(#(String, control.Prepared), error) {
  definition.parts().prepare(initial)
}

pub fn invoke(
  definition: Definition(context, state, answer, error),
  context: context,
  invocation: Invocation,
  prepared: control.Prepared,
) -> Result(String, error) {
  definition.parts().invoke(context, invocation, prepared)
}

pub fn observe_job(
  definition: Definition(context, state, answer, error),
  context: context,
  prepared: control.Prepared,
) -> Result(job.Progress(String), error) {
  definition.parts().observe_job(context, prepared)
}

pub fn cancel_job(
  definition: Definition(context, state, answer, error),
  context: context,
  invocation: Invocation,
  prepared: control.Prepared,
) -> Result(Nil, error) {
  definition.parts().cancel_job(context, invocation, prepared)
}

pub fn accept(
  definition: Definition(context, state, answer, error),
  state: String,
  prepared: control.Prepared,
  output: String,
) -> Result(control.Decision, error) {
  definition.parts().accept(state, prepared, output)
}

pub fn validate(
  definition: Definition(context, state, answer, error),
  saved: control.State,
) -> Result(Nil, error) {
  definition.parts().validate(saved)
}

pub fn check_join(
  definition: Definition(context, state, answer, error),
  state: control.State,
  activation: control.Activation,
  output: String,
) -> Result(Nil, error) {
  definition.parts().check_join(state, activation, output)
}

pub fn check_output(
  definition: Definition(context, state, answer, error),
  prepared: control.Prepared,
  output: String,
) -> Result(Nil, error) {
  definition.parts().check_output(prepared, output)
}

pub fn detach_children(
  definition: Definition(context, state, answer, error),
) -> Detached(context, state, answer, error) {
  definition.parts().detach_children()
}
