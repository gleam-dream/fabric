//// The representation behind `fabric/graph.Runtime`: a built definition
//// bound to its store, the runner's work and its bounds.

import fabric/budget
import fabric/graph/definition.{type Definition}
import fabric/internal/answerer.{type Answerer}
import fabric/internal/graph/live
import fabric/internal/graph/runner
import fabric/internal/store.{type Store}
import gleam/option.{type Option}

pub opaque type Runtime(context, state, answer) {
  Runtime(
    definition: Definition(context, state, answer),
    store: Store,
    work: live.Work,
    /// The work with one caller's context instead of the runtime's: an
    /// approval's recheck, and the body it admits, run with it.
    with_context: fn(context) -> live.Work,
    options: runner.Options,
    family_budget: Option(budget.Limits),
    /// Who may answer the runtime's approval requests.
    approvers: Option(Answerer),
  )
}

pub fn new(
  definition: Definition(context, state, answer),
  store: Store,
  work: live.Work,
  with_context: fn(context) -> live.Work,
  options: runner.Options,
) -> Runtime(context, state, answer) {
  Runtime(
    definition:,
    store:,
    work:,
    with_context:,
    options:,
    family_budget: option.None,
    approvers: option.None,
  )
}

pub fn with_options(
  runtime: Runtime(context, state, answer),
  options: runner.Options,
) -> Runtime(context, state, answer) {
  Runtime(..runtime, options:)
}

pub fn with_family_budget(
  runtime: Runtime(context, state, answer),
  limits: budget.Limits,
) -> Runtime(context, state, answer) {
  Runtime(..runtime, family_budget: option.Some(limits))
}

pub fn with_approvers(
  runtime: Runtime(context, state, answer),
  approvers: Answerer,
) -> Runtime(context, state, answer) {
  Runtime(..runtime, approvers: option.Some(approvers))
}

pub fn approvers(runtime: Runtime(context, state, answer)) -> Option(Answerer) {
  runtime.approvers
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

pub fn work_with(
  runtime: Runtime(context, state, answer),
  context: context,
) -> live.Work {
  runtime.with_context(context)
}

pub fn options(runtime: Runtime(context, state, answer)) -> runner.Options {
  runtime.options
}

pub fn family_budget(
  runtime: Runtime(context, state, answer),
) -> Option(budget.Limits) {
  runtime.family_budget
}
