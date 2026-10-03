//// Operations whose body is a managed child: a subgraph, an agent run or a
//// fork of children. `fabric/graph` and `fabric/graph/agent` build them.

import fabric/graph/operation.{
  type Operation, Agent, Fork, NotExecutable, RequireReconciliation, Subgraph,
}
import fabric/internal/graph/child_driver
import fabric/internal/graph/contract
import fabric/internal/graph/fork_driver
import fabric/run
import json/blueprint/codec.{type Codec}

pub fn subgraph(
  identity: run.DefinitionId,
  input: Codec(input),
  output: Codec(output),
  driver: child_driver.Driver,
) -> Operation(context, input, output) {
  contract.new(
    identity,
    input,
    output,
    Subgraph,
    RequireReconciliation,
    parts(Ok(driver), Error(NotExecutable)),
  )
}

pub fn agent(
  identity: run.DefinitionId,
  input: Codec(input),
  output: Codec(output),
  driver: child_driver.Driver,
) -> Operation(context, input, output) {
  contract.new(
    identity,
    input,
    output,
    Agent,
    RequireReconciliation,
    parts(Ok(driver), Error(NotExecutable)),
  )
}

pub fn parallel(
  identity: run.DefinitionId,
  input: Codec(input),
  output: Codec(output),
  max_members: Int,
  concurrency: Int,
  signature: String,
  driver: fork_driver.Driver,
) -> Operation(context, input, output) {
  contract.new(
    identity,
    input,
    output,
    Fork(max_members, concurrency, signature),
    RequireReconciliation,
    parts(Error(NotExecutable), Ok(driver)),
  )
}

fn parts(
  child: Result(child_driver.Driver, operation.Error),
  fork: Result(fork_driver.Driver, operation.Error),
) -> contract.Parts(context, operation.Invocation, operation.Error) {
  contract.Parts(
    invoke: fn(_, _, _) { Error(NotExecutable) },
    read_job: fn(_, _) { Error("operation is not a job observer") },
    cancel_job: fn(_, _, _) { Error(NotExecutable) },
    child:,
    fork:,
  )
}
