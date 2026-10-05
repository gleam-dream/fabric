//// Typed graph authoring. Binding a native operation to a node retains its
//// input and output codecs inside the node, so different node types compose
//// without a universal application value or provider-shaped chat messages.
////
//// Definitions contain deployed code; execution records contain data. Bump
//// the graph or operation version when changing its meaning or codecs. The
//// structural manifest detects topology and declared contract changes, not
//// arbitrary changes to callback implementations.
////
//// ```gleam
//// let review = definition.node_id("review")
//// let assert Ok(graph) =
////   definition.new(
////     run.DefinitionId("publishing", 1),
////     entry: review,
////     nodes: [definition.node(review, check, select:, accept:, destinations: [])],
////     state: draft_codec,
////     answer: codec.string(),
////   )
////   |> definition.with_max_activations(20)
////   |> definition.build
//// ```
////
//// `build` checks the graph and the settings of every operation, and
//// reports every problem at once. A graph runs at most 100 activations by
//// default.

import fabric/graph/fork
import fabric/graph/job
import fabric/graph/operation.{type Invocation, type Operation}
import fabric/internal/graph/child_driver
import fabric/internal/graph/compiled
import fabric/internal/graph/contract
import fabric/internal/graph/controller as control
import fabric/internal/graph/fork_driver
import fabric/internal/graph/record
import fabric/internal/limit as bounds
import fabric/run
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import json/blueprint/codec.{type Codec}

/// How long a wait waits by default: 7 days, in milliseconds.
const default_wait = 604_800_000

const longest_timer = bounds.longest_timer

/// The most attempts `operation.with_replay` allows, as `tool.with_replay`.
const max_replay_attempts = 100

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
    /// The deadline in milliseconds an admitted wait gets: the default, the
    /// one set, or `None` for an activity or an unbounded wait.
    deadline: Option(Int),
    /// The operation's settings that `build` refuses.
    problems: List(operation.ConfigurationError),
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

/// A graph's description, checked by `build`. Build one with `new`.
pub opaque type Spec(context, state, answer) {
  Spec(
    identity: run.DefinitionId,
    entry: NodeId,
    nodes: List(Node(context, state, answer)),
    state: Codec(state),
    answer: Codec(answer),
    max_activations: Int,
  )
}

/// A built graph. Build one with `build`.
pub type Definition(context, state, answer) =
  compiled.Definition(context, state, answer, Error)

/// The built graph that `compile` turns into a `Definition`.
type Graph(context, state, answer) {
  Graph(
    entry: NodeId,
    state: Codec(state),
    answer: Codec(answer),
    nodes: Dict(NodeId, Node(context, state, answer)),
    identity: control.Definition,
  )
}

/// Why `build` refused a graph. This union may grow: match the variants you
/// handle and keep a catch-all, or use `describe_build_error`.
pub type BuildError {
  /// A node id is empty or only whitespace.
  InvalidNodeId(name: String)
  /// The graph's or an operation's name is empty or its version is not
  /// positive.
  InvalidIdentity(run.DefinitionId)
  /// A bound is outside `minimum..maximum` (both included), as for
  /// `agent.InvalidLimit`.
  InvalidLimit(limit: Limit, value: Int, minimum: Int, maximum: Int)
  DuplicateNode(NodeId)
  MissingEntry(NodeId)
  UnknownDestination(source: NodeId, destination: NodeId)
  /// A setting of the operation of the node `node`.
  InvalidOperation(node: NodeId, problem: operation.ConfigurationError)
}

/// A bound of a graph that `build` checks, named after its setter. This
/// union may grow.
pub type Limit {
  /// `with_max_activations`, at least 1.
  MaxActivations
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

/// The node named `name`. `build` refuses an empty or blank one
/// (`InvalidNodeId`); an acceptance callback that routes to a name no node
/// has is refused (`DestinationNotAllowed`).
pub fn node_id(name: String) -> NodeId {
  NodeId(name)
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
  let input = contract.input(op)
  let output = contract.output(op)
  let invoke = contract.invoker(op)
  let fork_driver = contract.fork_driver(op)
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
  let kind = operation.kind(op)
  let recovery = operation.recovery(op)
  let #(deadline, deadline_problems) = deadline_of(kind, contract.deadline(op))
  Node(
    id:,
    operation: operation.identity(op),
    kind:,
    recovery:,
    deadline:,
    problems: list.flatten([
      recovery_problems(kind, recovery),
      deadline_problems,
      kind_problems(kind),
    ]),
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
    child: contract.child_driver(op) |> result.map_error(OperationRejected),
    fork: fork_driver |> result.map_error(OperationRejected),
    check_member:,
    prepare_members:,
    join_output:,
    job: contract.job_reader(op),
    stop_job: contract.job_canceller(op),
  )
}

/// The deadline an admitted wait of `kind` gets, and the problems of what
/// was asked: 7 days by default, none for an activity.
fn deadline_of(
  kind: operation.Kind,
  asked: contract.Deadline,
) -> #(Option(Int), List(operation.ConfigurationError)) {
  case kind, asked {
    operation.Activity, contract.DefaultDeadline -> #(None, [])
    operation.Activity, contract.SetDeadline(_) -> #(None, [
      operation.DeadlineRequiresWait,
    ])
    _, contract.DefaultDeadline -> #(Some(default_wait), [])
    _, contract.SetDeadline(run.Infinity) -> #(None, [])
    _, contract.SetDeadline(run.After(within)) -> {
      let ms = duration.to_milliseconds(within)
      case ms > 0 && ms <= longest_timer {
        True -> #(Some(ms), [])
        False -> #(None, [
          operation.InvalidLimit(operation.Deadline, ms, 1, longest_timer),
        ])
      }
    }
  }
}

fn recovery_problems(
  kind: operation.Kind,
  recovery: operation.Recovery,
) -> List(operation.ConfigurationError) {
  case kind, recovery {
    _, operation.RequireReconciliation -> []
    operation.Activity, operation.ReplayInterrupted(max) ->
      bounds.check(
        [
          bounds.Bound(
            operation.ReplayAttempts,
            Some(max),
            1,
            max_replay_attempts,
          ),
        ],
        operation.InvalidLimit,
      )
    _, operation.ReplayInterrupted(_) -> [operation.ReplayRequiresActivity]
  }
}

/// The bounds of a job's polling and of a fork's members.
fn kind_problems(kind: operation.Kind) -> List(operation.ConfigurationError) {
  let checked = case kind {
    operation.Job(job.Every(ms)) | operation.OwnedJob(job.Every(ms)) -> [
      bounds.Bound(operation.PollInterval, Some(ms), 1, longest_timer),
    ]
    operation.Fork(max_members:, concurrency:, ..) -> [
      bounds.Bound(operation.MaxMembers, Some(max_members), 1, bounds.largest),
      bounds.Bound(operation.Concurrency, Some(concurrency), 1, bounds.largest),
    ]
    _ -> []
  }
  bounds.check(checked, operation.InvalidLimit)
}

/// A graph named by `identity`, starting at `entry`, over `nodes`, whose
/// state and answer `state` and `answer` encode, with at most 100
/// activations per run. A stored run records the identity and continues
/// only under the same name, version and structure.
pub fn new(
  identity: run.DefinitionId,
  entry entry: NodeId,
  nodes nodes: List(Node(context, state, answer)),
  state state: Codec(state),
  answer answer: Codec(answer),
) -> Spec(context, state, answer) {
  Spec(identity:, entry:, nodes:, state:, answer:, max_activations: 100)
}

/// At most `limit` activations per run, retries and node revisits included
/// (at least 1; `build` reports another value as
/// `InvalidLimit(MaxActivations, ..)`). A run that would start one more
/// ends `graph.Exhausted`. The limit is part of the graph's stored
/// structure.
pub fn with_max_activations(
  spec: Spec(context, state, answer),
  limit: Int,
) -> Spec(context, state, answer) {
  Spec(..spec, max_activations: limit)
}

/// Checks `spec`, and the settings of every node's operation, and reports
/// every problem at once.
pub fn build(
  spec: Spec(context, state, answer),
) -> Result(Definition(context, state, answer), List(BuildError)) {
  let nodes =
    list.fold(spec.nodes, dict.new(), fn(index, node) {
      case dict.has_key(index, node.id) {
        True -> index
        False -> dict.insert(index, node.id, node)
      }
    })
  let problems =
    list.flatten([
      check_identity(spec.identity),
      bounds.check(
        [
          bounds.Bound(
            MaxActivations,
            Some(spec.max_activations),
            1,
            bounds.largest,
          ),
        ],
        InvalidLimit,
      ),
      check_node_id(spec.entry),
      case dict.has_key(nodes, spec.entry) {
        True -> []
        False -> [MissingEntry(spec.entry)]
      },
      duplicates(spec.nodes, []),
      list.flat_map(spec.nodes, fn(node) {
        list.flatten([
          check_node_id(node.id),
          check_identity(node.operation),
          list.map(node.problems, InvalidOperation(node.id, _)),
          list.filter_map(node.destinations, fn(destination) {
            case dict.has_key(nodes, destination) {
              True -> Error(Nil)
              False -> Ok(UnknownDestination(node.id, destination))
            }
          }),
        ])
      }),
    ])
    |> list.unique
  case problems {
    [_, ..] -> Error(problems)
    [] ->
      Ok(
        compile(Graph(
          spec.entry,
          spec.state,
          spec.answer,
          nodes,
          control.Definition(
            spec.identity,
            manifest(spec),
            spec.max_activations,
          ),
        )),
      )
  }
}

/// One line naming the problem.
pub fn describe_build_error(error: BuildError) -> String {
  case error {
    InvalidNodeId(name) -> "the node id " <> string.inspect(name) <> " is blank"
    InvalidIdentity(identity) ->
      "the identity "
      <> identity.name
      <> " version "
      <> int.to_string(identity.version)
      <> " needs a name and a positive version"
    InvalidLimit(limit, value, minimum, maximum) ->
      bounds.describe(setter(limit), value, minimum, maximum)
    DuplicateNode(id) -> "two nodes are named " <> node_name(id)
    MissingEntry(id) -> "the entry node " <> node_name(id) <> " does not exist"
    UnknownDestination(source, destination) ->
      "the node "
      <> node_name(source)
      <> " routes to "
      <> node_name(destination)
      <> ", which does not exist"
    InvalidOperation(id, problem) ->
      "the operation of the node "
      <> node_name(id)
      <> ": "
      <> describe_configuration_error(problem)
  }
}

/// One line for every problem `build` reported, in its order, joined with
/// `"; "`.
pub fn describe_build_errors(errors: List(BuildError)) -> String {
  errors
  |> list.map(describe_build_error)
  |> string.join("; ")
}

fn describe_configuration_error(
  problem: operation.ConfigurationError,
) -> String {
  case problem {
    operation.InvalidLimit(limit, value, minimum, maximum) ->
      bounds.describe(operation_setter(limit), value, minimum, maximum)
    operation.ReplayRequiresActivity ->
      "operation.with_replay applies to activities only"
    operation.DeadlineRequiresWait ->
      "operation.with_deadline applies to waits only; an activity is bounded by graph.with_operation_timeout"
  }
}

fn setter(limit: Limit) -> String {
  case limit {
    MaxActivations -> "definition.with_max_activations"
  }
}

fn operation_setter(limit: operation.Limit) -> String {
  case limit {
    operation.ReplayAttempts -> "operation.with_replay"
    operation.Deadline -> "operation.with_deadline (ms)"
    operation.PollInterval -> "job.with_poll_interval (ms)"
    operation.MaxMembers -> "graph.map's max_members"
    operation.Concurrency -> "graph.map's concurrency"
  }
}

fn check_identity(identity: run.DefinitionId) -> List(BuildError) {
  case string.trim(identity.name) != "" && identity.version >= 1 {
    True -> []
    False -> [InvalidIdentity(identity)]
  }
}

fn check_node_id(id: NodeId) -> List(BuildError) {
  case string.trim(node_name(id)) {
    "" -> [InvalidNodeId(node_name(id))]
    _ -> []
  }
}

fn duplicates(
  nodes: List(Node(context, state, answer)),
  seen: List(NodeId),
) -> List(BuildError) {
  case nodes {
    [] -> []
    [node, ..rest] ->
      case list.contains(seen, node.id) {
        True -> [DuplicateNode(node.id), ..duplicates(rest, seen)]
        False -> duplicates(rest, [node.id, ..seen])
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
        // The default deadline, like no deadline, writes nothing: a
        // definition from before waits had a default keeps its manifest.
        let schedule =
          list.append(schedule, case node.deadline {
            Some(ms) if ms != default_wait -> [#("deadline_after", json.int(ms))]
            _ -> []
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

fn lookup(
  definition: Graph(context, state, answer),
  id: NodeId,
) -> Result(Node(context, state, answer), Error) {
  dict.get(definition.nodes, id) |> result.replace_error(NodeMissing(id))
}

fn prepare_node(
  definition: Graph(context, state, answer),
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
  definition: Graph(context, state, answer),
  state: state,
) -> Result(String, Error) {
  use encoded <- result.try(
    codec.encode_json(definition.state, state)
    |> result.map_error(StateEncodingFailed),
  )
  use _ <- result.try(decode_state(definition, encoded))
  Ok(encoded)
}

fn decode_state(
  definition: Graph(context, state, answer),
  text: String,
) -> Result(state, Error) {
  codec.decode_json(definition.state, text)
  |> result.map_error(fn(error) {
    StateDecodingFailed(codec.describe_decode_error(error))
  })
}

fn decode_answer(
  definition: Graph(context, state, answer),
  text: String,
) -> Result(answer, Error) {
  codec.decode_json(definition.answer, text)
  |> result.map_error(fn(error) {
    AnswerDecodingFailed(codec.describe_decode_error(error))
  })
}

fn prepare(
  definition: Graph(context, state, answer),
  initial: state,
) -> Result(#(String, control.Prepared), Error) {
  use encoded <- result.try(encode_state(definition, initial))
  use prepared <- result.try(prepare_node(definition, definition.entry, initial))
  Ok(#(encoded, prepared))
}

fn check_prepared(
  definition: Graph(context, state, answer),
  prepared: control.Prepared,
) -> Result(Node(context, state, answer), Error) {
  let id = NodeId(prepared.node)
  use node <- result.try(lookup(definition, id))
  use _ <- result.map(prepared_check(node)(prepared))
  node
}

/// Retain only the input contract while binding managed children. Capturing
/// the whole node would copy output codecs and unrelated descendant drivers
/// into both the child and fork lookup closures.
fn prepared_check(node: Node(context, state, answer)) {
  let Node(id:, operation:, recovery:, kind:, deadline:, check_input:, ..) =
    node
  fn(prepared: control.Prepared) {
    use _ <- result.try(
      case
        prepared.operation == operation
        && prepared.recovery == recovery
        && prepared.kind == kind
        && same_deadline(prepared.deadline, deadline)
      {
        True -> Ok(Nil)
        False -> Error(OperationChanged(id))
      },
    )
    check_input(prepared.input)
  }
}

/// Whether a stored activation's deadline fits the node's. A wait stored
/// without one (written before waits had a default) still fits a node that
/// waits the default: it keeps no deadline.
fn same_deadline(stored: Option(Int), node: Option(Int)) -> Bool {
  stored == node || stored == None && node == Some(default_wait)
}

/// Only the fenced runner calls this, after persisting the admitted start.
fn invoke(
  definition: Graph(context, state, answer),
  context: context,
  invocation: Invocation,
  prepared: control.Prepared,
) -> Result(String, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.invoke(context, invocation, prepared.input)
}

fn observe_job(
  definition: Graph(context, state, answer),
  context: context,
  prepared: control.Prepared,
) -> Result(job.Progress(String), Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.job(context, prepared.input)
  |> result.map_error(fn(reason) {
    OperationRejected(operation.ObservationFailed(reason))
  })
}

fn cancel_job(
  definition: Graph(context, state, answer),
  context: context,
  invocation: Invocation,
  prepared: control.Prepared,
) -> Result(Nil, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.stop_job(context, invocation, prepared.input)
  |> result.map_error(OperationRejected)
}

fn accept(
  definition: Graph(context, state, answer),
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
fn validate(
  definition: Graph(context, state, answer),
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
fn check_join(
  definition: Graph(context, state, answer),
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
fn check_output(
  definition: Graph(context, state, answer),
  prepared: control.Prepared,
  output: String,
) -> Result(Nil, Error) {
  use node <- result.try(check_prepared(definition, prepared))
  node.check_output(output)
}

fn detach_children(
  definition: Graph(context, state, answer),
) -> #(
  Graph(context, state, answer),
  fn(control.Prepared) -> Result(child_driver.Driver, Error),
  fn(control.Prepared) -> Result(fork_driver.Driver, Error),
) {
  let children =
    dict.map_values(definition.nodes, fn(_, node) {
      #(prepared_check(node), node.child)
    })
  let forks =
    dict.map_values(definition.nodes, fn(_, node) {
      #(prepared_check(node), node.fork)
    })
  let definition =
    Graph(
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
    fn(prepared: control.Prepared) {
      let id = NodeId(prepared.node)
      use #(check, driver) <- result.try(
        dict.get(children, id) |> result.replace_error(NodeMissing(id)),
      )
      use _ <- result.try(check(prepared))
      driver
    },
    fn(prepared: control.Prepared) {
      let id = NodeId(prepared.node)
      use #(check, driver) <- result.try(
        dict.get(forks, id) |> result.replace_error(NodeMissing(id)),
      )
      use _ <- result.try(check(prepared))
      driver
    },
  )
}

/// The runtime's view of `graph`: every function it calls, built over it.
fn compile(
  graph: Graph(context, state, answer),
) -> Definition(context, state, answer) {
  compiled.new(graph.identity, graph.state, graph.answer, fn() { parts(graph) })
}

fn parts(
  graph: Graph(context, state, answer),
) -> compiled.Parts(context, state, answer, Error) {
  compiled.Parts(
    decode_state: decode_state(graph, _),
    decode_answer: decode_answer(graph, _),
    prepare: prepare(graph, _),
    invoke: fn(context, invocation, prepared) {
      invoke(graph, context, invocation, prepared)
    },
    observe_job: fn(context, prepared) { observe_job(graph, context, prepared) },
    cancel_job: fn(context, invocation, prepared) {
      cancel_job(graph, context, invocation, prepared)
    },
    accept: fn(state, prepared, output) {
      accept(graph, state, prepared, output)
    },
    validate: validate(graph, _),
    check_join: fn(state, activation, output) {
      check_join(graph, state, activation, output)
    },
    check_output: fn(prepared, output) { check_output(graph, prepared, output) },
    detach_children: fn() {
      let #(detached, child, fork) = detach_children(graph)
      compiled.Detached(compile(detached), child, fork)
    },
  )
}
