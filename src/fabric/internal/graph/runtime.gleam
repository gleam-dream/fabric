//// The representation behind `fabric/graph.Runtime`: a built definition
//// bound to its store, the runner's work and its bounds.

import fabric/graph/definition.{type Definition}
import fabric/internal/graph/live
import fabric/internal/graph/runner
import fabric/internal/store.{type Store}

pub opaque type Runtime(context, state, answer) {
  Runtime(
    definition: Definition(context, state, answer),
    store: Store,
    work: live.Work,
    options: runner.Options,
  )
}

pub fn new(
  definition: Definition(context, state, answer),
  store: Store,
  work: live.Work,
  options: runner.Options,
) -> Runtime(context, state, answer) {
  Runtime(definition:, store:, work:, options:)
}

pub fn with_options(
  runtime: Runtime(context, state, answer),
  options: runner.Options,
) -> Runtime(context, state, answer) {
  Runtime(..runtime, options:)
}

pub fn definition(
  runtime: Runtime(context, state, answer),
) -> Definition(context, state, answer) {
  runtime.definition
}

pub fn store(runtime: Runtime(context, state, answer)) -> Store {
  runtime.store
}

pub fn work(runtime: Runtime(context, state, answer)) -> live.Work {
  runtime.work
}

pub fn options(runtime: Runtime(context, state, answer)) -> runner.Options {
  runtime.options
}
