//// Executable authoring experiment, not a production Fabric runtime.
////
//// Native input/output types disappear only when an operation is bound into
//// a node. The resulting closures retain the codecs at the receipt boundary.
//// The local driver is synchronous: no persistence, policy, task isolation,
//// cancellation or replay safety is implied by a successful run.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}

pub type Identity {
  Identity(name: String, version: Int)
}

pub opaque type NodeId {
  NodeId(String)
}

pub type Failure {
  DefiniteFailure(detail: String)
  UncertainEffect(evidence: String)
}

pub opaque type Operation(context, input, output) {
  Operation(
    identity: Identity,
    input: Codec(input),
    output: Codec(output),
    perform: fn(context, input) -> Result(output, Failure),
  )
}

pub type Command(state, answer) {
  Continue(state, NodeId)
  Finish(state, answer)
}

pub opaque type Node(context, state, answer) {
  Node(
    id: NodeId,
    operation: Identity,
    destinations: List(NodeId),
    prepare: fn(state) -> Result(String, NodeError),
    invoke: fn(context, String) -> Result(String, NodeError),
    accept: fn(state, String) -> Result(Command(state, answer), NodeError),
  )
}

pub type Spec(context, state, answer) {
  Spec(
    identity: Identity,
    entry: NodeId,
    nodes: List(Node(context, state, answer)),
    state: Codec(state),
    answer: Codec(answer),
    max_activations: Int,
  )
}

pub opaque type Graph(context, state, answer) {
  Graph(
    spec: Spec(context, state, answer),
    nodes: Dict(NodeId, Node(context, state, answer)),
  )
}

pub type BuildError {
  InvalidNodeId
  InvalidIdentity(Identity)
  InvalidActivationLimit(Int)
  DuplicateNode(NodeId)
  MissingEntry(NodeId)
  UnknownDestination(source: NodeId, destination: NodeId)
}

pub type NodeError {
  InputSelectionFailed(String)
  InputEncodingFailed(codec.EncodeError)
  InputDecodingFailed(String)
  OperationFailed(Failure)
  OutputEncodingFailed(codec.EncodeError)
  OutputDecodingFailed(String)
  TransitionFailed(String)
  DestinationNotAllowed(NodeId)
  StateEncodingFailed(codec.EncodeError)
  AnswerEncodingFailed(codec.EncodeError)
}

/// Ordinals are local to one run. A production identity also needs its run.
pub type Activation {
  Activation(ordinal: Int, node: NodeId)
}

pub type Route {
  Next(NodeId)
  Completed(answer_json: String)
}

pub type Receipt {
  Receipt(
    activation: Activation,
    operation: Identity,
    input_json: String,
    output_json: String,
    state_json: String,
    route: Route,
  )
}

pub type Stop {
  InitialStateRejected(codec.EncodeError)
  ActivationLimitReached(completed: Int)
  NodeFailed(Activation, NodeError)
  NodeMissing(NodeId)
}

pub type Report(state, answer) {
  Report(state: state, outcome: Result(answer, Stop), trace: List(Receipt))
}

/// No provider-tool naming grammar applies to a graph position.
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

/// The application error remains native until its explicit classification.
pub fn operation(
  identity: Identity,
  input: Codec(input),
  output: Codec(output),
  perform: fn(context, input) -> Result(output, error),
  classify: fn(error) -> Failure,
) -> Operation(context, input, output) {
  Operation(identity, input, output, fn(context, value) {
    perform(context, value) |> result.map_error(classify)
  })
}

/// All node-specific values are typed inside these closures. Only the named
/// receipt boundary encodes them. No JSON Schema is requested here.
pub fn node(
  id: NodeId,
  operation: Operation(context, input, output),
  select select: fn(state) -> Result(input, String),
  accept accept: fn(state, output) -> Result(Command(state, answer), String),
  destinations destinations: List(NodeId),
) -> Node(context, state, answer) {
  Node(
    id:,
    operation: operation.identity,
    destinations:,
    prepare: fn(state) {
      use input <- result.try(
        select(state)
        |> result.map_error(InputSelectionFailed),
      )
      encode(operation.input, input, InputEncodingFailed)
    },
    invoke: fn(context, json) {
      use input <- result.try(decode(operation.input, json, InputDecodingFailed))
      use output <- result.try(
        operation.perform(context, input)
        |> result.map_error(OperationFailed),
      )
      encode(operation.output, output, OutputEncodingFailed)
    },
    accept: fn(state, json) {
      use output <- result.try(decode(
        operation.output,
        json,
        OutputDecodingFailed,
      ))
      accept(state, output) |> result.map_error(TransitionFailed)
    },
  )
}

pub fn build(
  spec: Spec(context, state, answer),
) -> Result(Graph(context, state, answer), BuildError) {
  use _ <- result.try(check_identity(spec.identity))
  use _ <- result.try(case spec.max_activations > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidActivationLimit(spec.max_activations))
  })
  use nodes <- result.try(index_nodes(spec.nodes, dict.new()))
  use _ <- result.try(case dict.has_key(nodes, spec.entry) {
    True -> Ok(Nil)
    False -> Error(MissingEntry(spec.entry))
  })
  use _ <- result.try(check_destinations(spec.nodes, nodes))
  Ok(Graph(spec, nodes))
}

fn check_identity(identity: Identity) -> Result(Nil, BuildError) {
  case string.trim(identity.name) == "" || identity.version < 1 {
    True -> Error(InvalidIdentity(identity))
    False -> Ok(Nil)
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

fn check_destinations(
  nodes: List(Node(context, state, answer)),
  index: Dict(NodeId, Node(context, state, answer)),
) -> Result(Nil, BuildError) {
  case nodes {
    [] -> Ok(Nil)
    [node, ..rest] -> {
      use _ <- result.try(
        list.try_each(node.destinations, fn(destination) {
          case dict.has_key(index, destination) {
            True -> Ok(Nil)
            False -> Error(UnknownDestination(node.id, destination))
          }
        }),
      )
      check_destinations(rest, index)
    }
  }
}

fn encode(
  contract: Codec(value),
  value: value,
  error: fn(codec.EncodeError) -> NodeError,
) -> Result(String, NodeError) {
  codec.encode_json(contract, value)
  |> result.map_error(error)
}

fn decode(
  contract: Codec(value),
  json: String,
  error: fn(String) -> NodeError,
) -> Result(value, NodeError) {
  codec.decode_json(contract, json)
  |> result.map_error(fn(reason) { error(codec.describe_decode_error(reason)) })
}

/// Wave 1 deliberately runs only synchronous scripted operations. Never use
/// this experimental driver for external effects: it has no admission fence.
pub fn run(
  graph: Graph(context, state, answer),
  context: context,
  initial: state,
) -> Report(state, answer) {
  case codec.encode_json(graph.spec.state, initial) {
    Error(error) -> Report(initial, Error(InitialStateRejected(error)), [])
    Ok(_) -> walk(graph, context, initial, graph.spec.entry, 1, [])
  }
}

type Accepted(state, answer) {
  Moved(state: state, state_json: String, destination: NodeId)
  Finished(
    state: state,
    state_json: String,
    answer: answer,
    answer_json: String,
  )
}

type Step(state, answer) {
  Step(
    input_json: String,
    output_json: String,
    accepted: Accepted(state, answer),
  )
}

fn walk(
  graph: Graph(context, state, answer),
  context: context,
  state: state,
  destination: NodeId,
  ordinal: Int,
  trace: List(Receipt),
) -> Report(state, answer) {
  case ordinal > graph.spec.max_activations {
    True ->
      Report(
        state,
        Error(ActivationLimitReached(ordinal - 1)),
        list.reverse(trace),
      )
    False ->
      case dict.get(graph.nodes, destination) {
        Error(Nil) ->
          Report(state, Error(NodeMissing(destination)), list.reverse(trace))
        Ok(node) -> {
          let activation = Activation(ordinal, destination)
          case step(graph, node, context, state) {
            Error(error) ->
              Report(
                state,
                Error(NodeFailed(activation, error)),
                list.reverse(trace),
              )
            Ok(Step(input, output, Moved(next_state, encoded, next))) ->
              walk(graph, context, next_state, next, ordinal + 1, [
                Receipt(
                  activation,
                  node.operation,
                  input,
                  output,
                  encoded,
                  Next(next),
                ),
                ..trace
              ])
            Ok(Step(input, output, Finished(next_state, encoded, answer, final))) ->
              Report(
                next_state,
                Ok(answer),
                list.reverse([
                  Receipt(
                    activation,
                    node.operation,
                    input,
                    output,
                    encoded,
                    Completed(final),
                  ),
                  ..trace
                ]),
              )
          }
        }
      }
  }
}

fn step(
  graph: Graph(context, state, answer),
  node: Node(context, state, answer),
  context: context,
  state: state,
) -> Result(Step(state, answer), NodeError) {
  use input <- result.try(node.prepare(state))
  use output <- result.try(node.invoke(context, input))
  use command <- result.try(node.accept(state, output))
  use accepted <- result.try(accept(graph.spec, node.destinations, command))
  Ok(Step(input, output, accepted))
}

fn accept(
  spec: Spec(context, state, answer),
  destinations: List(NodeId),
  command: Command(state, answer),
) -> Result(Accepted(state, answer), NodeError) {
  case command {
    Continue(state, destination) -> {
      use _ <- result.try(case list.contains(destinations, destination) {
        True -> Ok(Nil)
        False -> Error(DestinationNotAllowed(destination))
      })
      use encoded <- result.try(encode(spec.state, state, StateEncodingFailed))
      Ok(Moved(state, encoded, destination))
    }
    Finish(state, answer) -> {
      use encoded <- result.try(encode(spec.state, state, StateEncodingFailed))
      use final <- result.try(encode(spec.answer, answer, AnswerEncodingFailed))
      Ok(Finished(state, encoded, answer, final))
    }
  }
}
