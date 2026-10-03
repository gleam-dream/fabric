//// Typed graph authoring. Binding a native operation to a node retains its
//// input and output codecs inside the node, so different node types compose
//// without a universal application value or provider-shaped chat messages.
////
//// Definitions contain deployed code; execution records contain data. Bump
//// the graph or operation version when changing its meaning or codecs. The
//// structural manifest detects topology and declared contract changes, not
//// arbitrary changes to callback implementations.

import fabric/graph/fork
import fabric/graph/job
import fabric/graph/operation.{type Invocation, type Operation}
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as control
import fabric/internal/graph/fork_driver
import fabric/internal/graph/record
import fabric/run
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}

pub opaque type NodeId {
  NodeId(String)
}

pub type Command(state, answer) {
  Continue(state, NodeId)
  Finish(state, answer)
}

pub opaque type Node(context, state, answer) {
  Node(
    id: NodeId,
    operation: run.DefinitionId,
    kind: operation.Kind,
    recovery: operation.Recovery,
    deadline: Option(Int),
    destinations: List(NodeId),
    prepare: fn(state) -> Result(String, Error),
    invoke: fn(context, Invocation, String) -> Result(String, Error),
    accept: fn(state, String) -> Result(Command(state, answer), Error),
    check_input: fn(String) -> Result(Nil, Error),
    check_output: fn(String) -> Result(Nil, Error),
    child: Result(child_driver.Driver, Error),
    fork: Result(fork_driver.Driver, Error),
    check_member: fn(Int, fork.Request) -> Result(Nil, String),
    prepare_members: fn(String) -> Result(List(fork.Request), String),
    join_output: fn(fork.Snapshot) -> Result(String, String),
    job: fn(context, String) -> Result(job.Progress(String), String),
    stop_job: fn(context, Invocation, String) -> Result(Nil, operation.Error),
  )
}

pub type Spec(context, state, answer) {
  Spec(
    identity: run.DefinitionId,
    entry: NodeId,
    nodes: List(Node(context, state, answer)),
    state: Codec(state),
    answer: Codec(answer),
    max_activations: Int,
  )
}

pub opaque type Definition(context, state, answer) {
  Definition(
    entry: NodeId,
    state: Codec(state),
    answer: Codec(answer),
    nodes: Dict(NodeId, Node(context, state, answer)),
    identity: control.Definition,
  )
}

pub type BuildError {
  InvalidNodeId
  InvalidIdentity(run.DefinitionId)
  InvalidActivationLimit(Int)
  DuplicateNode(NodeId)
  MissingEntry(NodeId)
  UnknownDestination(source: NodeId, destination: NodeId)
}

pub type Error {
  InputSelectionFailed(String)
  OperationRejected(operation.Error)
  TransitionFailed(String)
  DestinationNotAllowed(NodeId)
  StateEncodingFailed(codec.EncodeError)
  StateDecodingFailed(String)
  AnswerEncodingFailed(codec.EncodeError)
  AnswerDecodingFailed(String)
  NodeMissing(NodeId)
  DefinitionChanged
  OperationChanged(NodeId)
  EntryChanged
  InvalidRecord(String)
}

pub fn node_id(name: String) -> Result(NodeId, BuildError) {
  case string.trim(name) {
    "" -> Error(InvalidNodeId)
    _ -> Ok(NodeId(name))
  }
}

pub fn node_name(id: NodeId) -> String {
  let NodeId(name) = id
  name
}

/// Selection and acceptance are pure callbacks. External effects belong to
/// the operation body, where the runner applies policy and the start fence.
pub fn node(
  id: NodeId,
  op: Operation(context, input, output),
  select select: fn(state) -> Result(input, String),
  accept accept: fn(state, output) -> Result(Command(state, answer), String),
  destinations destinations: List(NodeId),
) -> Node(context, state, answer) {
  let input = operation.input_codec(op)
  let output = operation.output_codec(op)
  let invoke = operation.invoker(op)
  let fork_driver = operation.fork_driver(op)
  let check_member = case fork_driver {
    Ok(driver) -> driver.check
    Error(_) -> fn(_, _) { Error("operation has no fork members") }
  }
  let #(prepare_members, join_output) = case fork_driver {
    Ok(driver) -> {
      let encode = driver.output
      #(driver.prepare, fn(saved) { fork_driver.encode_join(saved, encode) })
    }
    Error(_) -> #(fn(_) { Error("operation has no fork members") }, fn(_) {
      Error("operation has no fork result")
    })
  }
  let decode_input = fn(text) {
    codec.decode_json(input, text)
    |> result.map_error(fn(error) {
      OperationRejected(
        operation.InputDecodingFailed(codec.describe_decode_error(error)),
      )
    })
  }
  let decode_output = fn(text) {
    codec.decode_json(output, text)
    |> result.map_error(fn(error) {
      OperationRejected(
        operation.OutputDecodingFailed(codec.describe_decode_error(error)),
      )
    })
  }
  Node(
    id:,
    operation: operation.identity(op),
    kind: operation.kind(op),
    recovery: operation.recovery(op),
    deadline: operation.deadline(op),
    destinations:,
    prepare: fn(state) {
      use value <- result.try(
        select(state) |> result.map_error(InputSelectionFailed),
      )
      codec.encode_json(input, value)
      |> result.map_error(fn(error) {
        OperationRejected(operation.InputEncodingFailed(error))
      })
    },
    invoke: fn(context, invocation, text) {
      invoke(context, invocation, text)
      |> result.map_error(OperationRejected)
    },
    accept: fn(state, text) {
      use output <- result.try(decode_output(text))
      accept(state, output) |> result.map_error(TransitionFailed)
    },
    check_input: fn(text) { decode_input(text) |> result.replace(Nil) },
    check_output: fn(text) { decode_output(text) |> result.replace(Nil) },
    child: operation.child_driver(op) |> result.map_error(OperationRejected),
    fork: fork_driver |> result.map_error(OperationRejected),
    check_member:,
    prepare_members:,
    join_output:,
    job: operation.job_reader(op),
    stop_job: operation.job_canceller(op),
  )
}

pub fn build(
  spec: Spec(context, state, answer),
) -> Result(Definition(context, state, answer), BuildError) {
  use _ <- result.try(check_identity(spec.identity))
  use _ <- result.try(case spec.max_activations >= 1 {
    True -> Ok(Nil)
    False -> Error(InvalidActivationLimit(spec.max_activations))
  })
  use nodes <- result.try(index_nodes(spec.nodes, dict.new()))
  use _ <- result.try(case dict.has_key(nodes, spec.entry) {
    True -> Ok(Nil)
    False -> Error(MissingEntry(spec.entry))
  })
  use _ <- result.try(
    list.try_each(spec.nodes, fn(node) {
      list.try_each(node.destinations, fn(destination) {
        case dict.has_key(nodes, destination) {
          True -> Ok(Nil)
          False -> Error(UnknownDestination(node.id, destination))
        }
      })
    }),
  )
  Ok(Definition(
    spec.entry,
    spec.state,
    spec.answer,
    nodes,
    control.Definition(spec.identity, manifest(spec), spec.max_activations),
  ))
}

fn check_identity(identity: run.DefinitionId) -> Result(Nil, BuildError) {
  case string.trim(identity.name) != "" && identity.version >= 1 {
    True -> Ok(Nil)
    False -> Error(InvalidIdentity(identity))
  }
}

fn index_nodes(
  nodes: List(Node(context, state, answer)),
  index: Dict(NodeId, Node(context, state, answer)),
) -> Result(Dict(NodeId, Node(context, state, answer)), BuildError) {
  case nodes {
    [] -> Ok(index)
    [node, ..rest] -> {
      use _ <- result.try(check_identity(node.operation))
      case dict.has_key(index, node.id) {
        True -> Error(DuplicateNode(node.id))
        False -> index_nodes(rest, dict.insert(index, node.id, node))
      }
    }
  }
}

fn manifest(spec: Spec(context, state, answer)) -> String {
  let nodes =
    list.sort(spec.nodes, fn(a, b) {
      string.compare(node_name(a.id), node_name(b.id))
    })
  json.object([
    #("entry", json.string(node_name(spec.entry))),
    #(
      "nodes",
      json.array(nodes, fn(node) {
        let destinations =
          node.destinations
          |> list.map(node_name)
          |> list.unique
          |> list.sort(string.compare)
        let schedule = case node.kind {
          operation.Job(job.Every(ms)) | operation.OwnedJob(job.Every(ms)) -> [
            #("poll_every", json.int(ms)),
          ]
          _ -> []
        }
        let schedule =
          list.append(schedule, case node.deadline {
            None -> []
            Some(ms) -> [#("deadline_after", json.int(ms))]
          })
        json.object(list.append(
          [
            #("node", json.string(node_name(node.id))),
            #("operation", json.string(node.operation.name)),
            #("version", json.int(node.operation.version)),
            #(
              "kind",
              json.string(case node.kind {
                operation.Activity -> "activity"
                operation.Signal -> "signal"
                operation.Job(_) -> "job"
                operation.OwnedJob(_) -> "owned_job"
                operation.Subgraph -> "subgraph"
                operation.Agent -> "agent"
                operation.Fork(maximum, concurrency, signature) ->
                  json.array(
                    [
                      json.string("fork"),
                      json.int(maximum),
                      json.int(concurrency),
                      json.string(signature),
                    ],
                    fn(value) { value },
                  )
                  |> json.to_string
              }),
            ),
            #("recovery", case node.recovery {
              operation.RequireReconciliation ->
                json.object([#("tag", json.string("reconcile"))])
              operation.ReplayInterrupted(max) ->
                json.object([
                  #("tag", json.string("replay")),
                  #("max_attempts", json.int(max)),
                ])
            }),
            #("destinations", json.array(destinations, json.string)),
          ],
          schedule,
        ))
      }),
    ),
  ])
  |> json.to_string
}

@internal
pub fn identity(
  definition: Definition(context, state, answer),
) -> control.Definition {
  definition.identity
}

fn lookup(
  definition: Definition(context, state, answer),
  id: NodeId,
) -> Result(Node(context, state, answer), Error) {
  dict.get(definition.nodes, id) |> result.replace_error(NodeMissing(id))
}

fn prepare_node(
  definition: Definition(context, state, answer),
  id: NodeId,
  state: state,
) -> Result(control.Prepared, Error) {
  use node <- result.try(lookup(definition, id))
  use input <- result.try(node.prepare(state))
  use _ <- result.try(node.check_input(input))
  Ok(control.Prepared(
    node_name(id),
    node.operation,
    input,
    node.recovery,
    node.kind,
    node.deadline,
  ))
}

fn encode_state(
  definition: Definition(context, state, answer),
  state: state,
) -> Result(String, Error) {
  use encoded <- result.try(
    codec.encode_json(definition.state, state)
    |> result.map_error(StateEncodingFailed),
  )
  use _ <- result.try(decode_state(definition, encoded))
  Ok(encoded)
}

@internal
pub fn decode_state(
  definition: Definition(context, state, answer),
  text: String,
) -> Result(state, Error) {
  codec.decode_json(definition.state, text)
  |> result.map_error(fn(error) {
    StateDecodingFailed(codec.describe_decode_error(error))
  })
}

@internal
pub fn decode_answer(
  definition: Definition(context, state, answer),
  text: String,
) -> Result(answer, Error) {
  codec.decode_json(definition.answer, text)
  |> result.map_error(fn(error) {
    AnswerDecodingFailed(codec.describe_decode_error(error))
  })
}

@internal
pub fn prepare(
  definition: Definition(context, state, answer),
  initial: state,
) -> Result(#(String, control.Prepared), Error) {
  use encoded <- result.try(encode_state(definition, initial))
  use prepared <- result.try(prepare_node(definition, definition.entry, initial))
  Ok(#(encoded, prepared))
}

fn check_prepared(
  definition: Definition(context, state, answer),
  prepared: control.Prepared,
) -> Result(Node(context, state, answer), Error) {
  let id = NodeId(prepared.node)
  use node <- result.try(lookup(definition, id))
  use _ <- result.try(
    case
      prepared.operation == node.operation
      && prepared.recovery == node.recovery
      && prepared.kind == node.kind
      && prepared.deadline == node.deadline
    {
      True -> Ok(Nil)
      False -> Error(OperationChanged(id))
    },
  )
  use _ <- result.try(node.check_input(prepared.input))
  Ok(node)
}

/// Only the fenced runner calls this, after persisting the admitted start.
@internal
pub fn invoke(
  definition: Definition(context, state, answer),
  context: context,
  invocation: Invocation,
  prepared: control.Prepared,
) -> Result(String, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.invoke(context, invocation, prepared.input)
}

@internal
pub fn observe_job(
  definition: Definition(context, state, answer),
  context: context,
  prepared: control.Prepared,
) -> Result(job.Progress(String), Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.job(context, prepared.input)
  |> result.map_error(fn(reason) {
    OperationRejected(operation.ObservationFailed(reason))
  })
}

@internal
pub fn cancel_job(
  definition: Definition(context, state, answer),
  context: context,
  invocation: Invocation,
  prepared: control.Prepared,
) -> Result(Nil, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.stop_job(context, invocation, prepared.input)
  |> result.map_error(OperationRejected)
}

@internal
pub fn accept(
  definition: Definition(context, state, answer),
  state: String,
  prepared: control.Prepared,
  output: String,
) -> Result(control.Decision, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  use state <- result.try(decode_state(definition, state))
  use command <- result.try(node.accept(state, output))
  case command {
    Continue(state, destination) -> {
      use _ <- result.try(allowed(node, destination))
      use encoded <- result.try(encode_state(definition, state))
      use next <- result.try(prepare_node(definition, destination, state))
      Ok(control.Continue(encoded, next))
    }
    Finish(state, answer) -> {
      use encoded <- result.try(encode_state(definition, state))
      use answer <- result.try(
        codec.encode_json(definition.answer, answer)
        |> result.map_error(AnswerEncodingFailed),
      )
      use _ <- result.try(decode_answer(definition, answer))
      Ok(control.Complete(encoded, answer))
    }
  }
}

fn allowed(
  node: Node(context, state, answer),
  destination: NodeId,
) -> Result(Nil, Error) {
  case list.contains(node.destinations, destination) {
    True -> Ok(Nil)
    False -> Error(DestinationNotAllowed(destination))
  }
}

/// Read-only compatibility check. Never reruns selection, body or acceptance
/// callbacks to reconstruct results or decisions already saved in a record.
@internal
pub fn validate(
  definition: Definition(context, state, answer),
  saved: control.State,
) -> Result(Nil, Error) {
  use _ <- result.try(case saved.definition == definition.identity {
    True -> Ok(Nil)
    False -> Error(DefinitionChanged)
  })
  use _ <- result.try(record.validate(saved) |> result.map_error(InvalidRecord))
  use _ <- result.try(decode_state(definition, saved.value))
  use _ <- result.try(decode_state(definition, saved.initial))
  use _ <- result.try(
    list.try_each(saved.forks, fn(scope) {
      use activation <- result.try(
        control.activation(saved, scope.occurrence.activation)
        |> result.replace_error(InvalidRecord("fork activation missing")),
      )
      use node <- result.try(check_prepared(definition, activation.prepared))
      use expected <- result.try(
        node.prepare_members(activation.prepared.input)
        |> result.map_error(InvalidRecord),
      )
      use _ <- result.try(
        case
          expected == list.map(scope.members, fn(member) { member.request })
        {
          True -> Ok(Nil)
          False ->
            Error(InvalidRecord("fork membership differs from its saved input"))
        },
      )
      scope.members
      |> list.index_map(fn(member, index) { #(member, index + 1) })
      |> list.try_each(fn(item) {
        node.check_member(item.1, item.0.request)
        |> result.map_error(InvalidRecord)
      })
    }),
  )
  use _ <- result.try(
    list.try_each(saved.receipts, fn(receipt) {
      use node <- result.try(check_prepared(
        definition,
        receipt.activation.prepared,
      ))
      use _ <- result.try(node.check_output(receipt.output))
      use _ <- result.try(check_join(
        definition,
        saved,
        receipt.activation,
        receipt.output,
      ))
      use _ <- result.try(decode_state(definition, receipt.state))
      case receipt.route {
        control.Next(destination) -> allowed(node, NodeId(destination))
        control.Finished | control.StoppedRoute -> Ok(Nil)
      }
    }),
  )
  let pending = case saved.phase {
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
    | control.Ended(control.Cancelled(a, _)) -> [a.prepared]
    control.Ended(control.Exhausted(next)) -> [next]
    control.Ended(control.Completed(_)) -> []
  }
  use _ <- result.try(
    list.try_each(pending, fn(prepared) {
      check_prepared(definition, prepared) |> result.replace(Nil)
    }),
  )
  let first = case saved.receipts {
    [receipt, ..] -> [receipt.activation.prepared]
    [] -> pending
  }
  let entry = node_name(definition.entry)
  use _ <- result.try(case first {
    [prepared, ..] if prepared.node == entry -> Ok(Nil)
    _ -> Error(EntryChanged)
  })
  case saved.phase {
    control.Blocked(a, control.InvalidResult(output, _)) if output != "" ->
      check_join(definition, saved, a, output)
    control.Ended(control.Completed(answer)) ->
      decode_answer(definition, answer) |> result.replace(Nil)
    _ -> Ok(Nil)
  }
}

/// Fork results are derived from retained member evidence. Reconciliation may
/// retry acceptance but cannot replace those results or turn failure into success.
@internal
pub fn check_join(
  definition: Definition(context, state, answer),
  state: control.State,
  activation: control.Activation,
  output: String,
) -> Result(Nil, Error) {
  case activation.prepared.kind {
    operation.Fork(..) -> {
      use node <- result.try(check_prepared(definition, activation.prepared))
      use saved <- result.try(
        list.find(state.forks, fn(saved) {
          saved.occurrence.activation == activation.id
        })
        |> result.replace_error(InvalidRecord("fork membership missing")),
      )
      use expected <- result.try(
        node.join_output(saved) |> result.map_error(InvalidRecord),
      )
      case
        json.parse(expected, decode.dynamic),
        json.parse(output, decode.dynamic)
      {
        Ok(expected), Ok(actual) if expected == actual -> Ok(Nil)
        _, _ ->
          Error(InvalidRecord("join result differs from retained members"))
      }
    }
    _ -> Ok(Nil)
  }
}

/// Validate a reconciliation or cancelled result without running its route.
@internal
pub fn check_output(
  definition: Definition(context, state, answer),
  prepared: control.Prepared,
  output: String,
) -> Result(Nil, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.check_output(output)
}

@internal
pub fn state_codec(
  definition: Definition(context, state, answer),
) -> Codec(state) {
  definition.state
}

@internal
pub fn answer_codec(
  definition: Definition(context, state, answer),
) -> Codec(answer) {
  definition.answer
}

@internal
pub fn detach_children(
  definition: Definition(context, state, answer),
) -> #(
  Definition(context, state, answer),
  fn(control.Prepared) -> Result(child_driver.Driver, Error),
  fn(control.Prepared) -> Result(fork_driver.Driver, Error),
) {
  let children = dict.map_values(definition.nodes, fn(_, node) { node.child })
  let forks = dict.map_values(definition.nodes, fn(_, node) { node.fork })
  let definition =
    Definition(
      ..definition,
      nodes: dict.map_values(definition.nodes, fn(_, node) {
        Node(
          ..node,
          child: Error(OperationRejected(operation.NotExecutable)),
          fork: Error(OperationRejected(operation.NotExecutable)),
        )
      }),
    )
  #(
    definition,
    fn(prepared) {
      use node <- result.try(check_prepared(definition, prepared))
      dict.get(children, node.id)
      |> result.unwrap(Error(NodeMissing(node.id)))
    },
    fn(prepared) {
      use node <- result.try(check_prepared(definition, prepared))
      dict.get(forks, node.id) |> result.unwrap(Error(NodeMissing(node.id)))
    },
  )
}
