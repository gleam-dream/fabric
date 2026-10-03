import fabric/graph/definition as graph
import fabric/graph/operation
import fabric/internal/graph/compiled
import fabric/internal/graph/controller
import fabric/internal/graph/record
import fabric/policy
import fabric/run
import fabric/tool
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal/correlation

fn id(name: String) -> graph.NodeId {
  let id = graph.node_id(name)
  id
}

fn no_error(_error: Nil) -> tool.Failure {
  tool.Explain("cannot fail")
}

fn increment() -> operation.Operation(Nil, Int, Int) {
  operation.new(
    run.DefinitionId("increment", 1),
    codec.int(),
    codec.int(),
    fn(_, _, input) { Ok(input + 1) },
    no_error,
  )
}

fn counter(
  accept: fn(Int, Int) -> Result(graph.Command(Int, Int), String),
  destinations: List(graph.NodeId),
) -> graph.Node(Nil, Int, Int) {
  graph.node(
    id("counter"),
    increment(),
    fn(state) { Ok(state) },
    accept,
    destinations,
  )
}

fn spec(nodes: List(graph.Node(Nil, Int, Int))) -> graph.Spec(Nil, Int, Int) {
  spec_of(run.DefinitionId("counter-loop", 1), id("counter"), nodes)
}

fn spec_of(
  identity: run.DefinitionId,
  entry: graph.NodeId,
  nodes: List(graph.Node(Nil, Int, Int)),
) -> graph.Spec(Nil, Int, Int) {
  graph.new(identity, entry:, nodes:, state: codec.int(), answer: codec.int())
  |> graph.with_max_activations(3)
}

fn loop() -> graph.Definition(Nil, Int, Int) {
  let assert Ok(definition) =
    graph.build(
      spec([
        counter(fn(_, value) { Ok(graph.Continue(value, id("counter"))) }, [
          id("counter"),
        ]),
      ]),
    )
  definition
}

fn started(definition: graph.Definition(Nil, Int, Int)) -> controller.State {
  let assert Ok(#(value, prepared)) = compiled.prepare(definition, 0)
  let assert Ok(#(state, _)) =
    controller.start(
      "native-graph",
      compiled.identity(definition),
      value,
      prepared,
    )
  state
}

fn completed_visit(
  definition: graph.Definition(Nil, Int, Int),
  state: controller.State,
) -> controller.State {
  let assert controller.Ready(a) = state.phase
  let ref = controller.reference(state, a)
  let assert Ok(#(state, _)) =
    controller.step(state, controller.Inspected(ref, Ok(policy.Allow), None))
  let assert Ok(#(state, _)) =
    controller.step(state, controller.BodyStarted(ref))
  let assert Ok(run) = run.parse_id(state.run)
  let assert Ok(output) =
    compiled.invoke(
      definition,
      Nil,
      operation.Invocation(
        run,
        a.id,
        a.attempt,
        correlation.from_key(state.run),
      ),
      a.prepared,
    )
  let assert Ok(decision) =
    compiled.accept(definition, state.value, a.prepared, output)
  let assert Ok(#(state, _)) =
    controller.step(state, controller.Returned(ref, output, decision))
  state
}

pub fn native_boolean_decision_routes_alongside_integer_generation_test() {
  let generate =
    counter(fn(_, draft) { Ok(graph.Continue(draft, id("review"))) }, [
      id("review"),
    ])
  let review =
    graph.node(
      id("review"),
      operation.new(
        run.DefinitionId("review", 1),
        codec.int(),
        codec.bool(),
        fn(_, _, draft) { Ok(draft >= 1) },
        no_error,
      ),
      fn(draft) { Ok(draft) },
      fn(draft, accepted) {
        case accepted {
          True -> Ok(graph.Finish(draft, draft))
          False -> Ok(graph.Continue(draft, id("counter")))
        }
      },
      [id("counter")],
    )
  let assert Ok(definition) = graph.build(spec([generate, review]))
  let done =
    started(definition)
    |> completed_visit(definition, _)
    |> completed_visit(definition, _)
  done.phase |> should.equal(controller.Ended(controller.Completed("1")))
  compiled.validate(definition, done) |> should.equal(Ok(Nil))
  let assert Ok(json) = record.encode(done)
  let assert Ok(restored) = record.decode(json)
  compiled.validate(definition, restored) |> should.equal(Ok(Nil))
  compiled.decode_answer(definition, "1") |> should.equal(Ok(1))
  list.map(restored.receipts, fn(receipt) { receipt.output })
  |> should.equal(["1", "true"])
}

pub fn validation_never_repeats_selection_operations_or_routing_test() {
  let state = completed_visit(loop(), started(loop()))
  let forbidden =
    operation.new(
      run.DefinitionId("increment", 1),
      codec.int(),
      codec.int(),
      fn(_, _, _) { panic as "body ran during validation" },
      no_error,
    )
  let node =
    graph.node(
      id("counter"),
      forbidden,
      fn(_) { panic as "selection ran during validation" },
      fn(_, _) { panic as "routing ran during validation" },
      [id("counter")],
    )
  let assert Ok(definition) = graph.build(spec([node]))
  compiled.validate(definition, state) |> should.equal(Ok(Nil))
}

pub fn construction_rejects_invalid_bounds_identity_and_destinations_test() {
  let node = counter(fn(state, value) { Ok(graph.Finish(state, value)) }, [])
  let identity = run.DefinitionId("counter-loop", 1)
  graph.build(spec([node, node]))
  |> should.equal(Error([graph.DuplicateNode(id("counter"))]))
  graph.build(spec([node]) |> graph.with_max_activations(0))
  |> should.equal(Error([graph.InvalidActivationLimit(0)]))
  graph.build(spec_of(run.DefinitionId("", 1), id("counter"), [node]))
  |> should.equal(Error([graph.InvalidIdentity(run.DefinitionId("", 1))]))
  graph.build(spec_of(identity, id("missing"), [node]))
  |> should.equal(Error([graph.MissingEntry(id("missing"))]))
  graph.build(
    spec([
      counter(fn(state, _) { Ok(graph.Continue(state, id("missing"))) }, [
        id("missing"),
      ]),
    ]),
  )
  |> should.equal(
    Error([graph.UnknownDestination(id("counter"), id("missing"))]),
  )
  // Every problem at once, an operation's settings included.
  let wait =
    graph.node(
      id(" "),
      operation.new(
        run.DefinitionId("increment", 1),
        codec.int(),
        codec.int(),
        fn(_, _, input) { Ok(input + 1) },
        no_error,
      )
        |> operation.with_replay(0)
        |> operation.with_deadline(run.After(duration.seconds(1))),
      fn(state) { Ok(state) },
      fn(state, value) { Ok(graph.Finish(state, value)) },
      [],
    )
  let assert Error(problems) =
    graph.build(
      spec_of(run.DefinitionId("", 0), id("counter"), [wait])
      |> graph.with_max_activations(0),
    )
  problems
  |> should.equal([
    graph.InvalidIdentity(run.DefinitionId("", 0)),
    graph.InvalidActivationLimit(0),
    graph.MissingEntry(id("counter")),
    graph.InvalidNodeId(" "),
    graph.InvalidOperation(id(" "), operation.InvalidAttemptBound(0)),
    graph.InvalidOperation(id(" "), operation.DeadlineRequiresWait),
  ])
  list.map(problems, graph.describe_build_error)
  |> list.all(fn(line) { line != "" })
  |> should.be_true
}

pub fn manifest_is_order_independent_and_detects_declared_contract_changes_test() {
  let a =
    counter(fn(_, n) { Ok(graph.Continue(n, id("b"))) }, [
      id("b"),
      id("counter"),
    ])
  let b =
    graph.node(
      id("b"),
      increment(),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(graph.Finish(n, n)) },
      [],
    )
  let assert Ok(first) = graph.build(spec([a, b]))
  let assert Ok(reordered) = graph.build(spec([b, a]))
  compiled.identity(first) |> should.equal(compiled.identity(reordered))
  let replay = operation.with_replay(increment(), 2)
  let changed =
    graph.node(
      id("counter"),
      replay,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(graph.Continue(n, id("b"))) },
      [id("b"), id("counter")],
    )
  let assert Ok(changed) = graph.build(spec([changed, b]))
  compiled.validate(changed, started(first))
  |> should.equal(Error(graph.DefinitionChanged))
}

pub fn saved_payloads_must_decode_under_the_current_native_contract_test() {
  let definition = loop()
  let state = completed_visit(definition, started(definition))
  let assert [receipt] = state.receipts
  let malformed =
    controller.State(..state, receipts: [
      controller.Receipt(..receipt, output: "true"),
    ])
  let assert Error(graph.OperationRejected(operation.OutputDecodingFailed(_))) =
    compiled.validate(definition, malformed)
  let assert controller.Ready(a) = state.phase
  let wrong_input = controller.Prepared(..a.prepared, input: "true")
  let malformed =
    controller.State(
      ..state,
      phase: controller.Ready(controller.Activation(..a, prepared: wrong_input)),
    )
  let assert Error(graph.OperationRejected(operation.InputDecodingFailed(_))) =
    compiled.validate(definition, malformed)
  let wrong_version =
    controller.Prepared(
      ..a.prepared,
      operation: run.DefinitionId("increment", 99),
    )
  compiled.validate(
    definition,
    controller.State(
      ..state,
      phase: controller.Ready(
        controller.Activation(..a, prepared: wrong_version),
      ),
    ),
  )
  |> should.equal(Error(graph.OperationChanged(id("counter"))))
}

pub fn runtime_routes_must_be_declared_even_if_the_destination_exists_test() {
  let node =
    counter(fn(_, value) { Ok(graph.Continue(value, id("counter"))) }, [])
  let assert Ok(definition) = graph.build(spec([node]))
  let assert Ok(#(state, prepared)) = compiled.prepare(definition, 0)
  compiled.accept(definition, state, prepared, "1")
  |> should.equal(Error(graph.DestinationNotAllowed(id("counter"))))
}

pub fn codecs_without_provider_schema_are_sufficient_for_durable_values_test() {
  let native =
    codec.custom(
      encode: codec.encode(codec.int(), _),
      decode: codec.decode(codec.int(), _),
      schema: None,
      placeholder: 0,
    )
  codec.schema(native) |> result.is_error |> should.be_true
  let op =
    operation.new(
      run.DefinitionId("increment", 1),
      native,
      native,
      fn(_, _, n) { Ok(n + 1) },
      no_error,
    )
  let node =
    graph.node(
      id("counter"),
      op,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(graph.Finish(n, n)) },
      [],
    )
  let assert Ok(definition) =
    graph.build(graph.new(
      run.DefinitionId("counter-loop", 1),
      entry: id("counter"),
      nodes: [node],
      state: native,
      answer: native,
    ))
  compiled.validate(
    definition,
    completed_visit(definition, started(definition)),
  )
  |> should.equal(Ok(Nil))
}

pub fn selection_transition_and_codec_failures_remain_distinct_test() {
  let selecting =
    graph.node(
      id("counter"),
      increment(),
      fn(_) { Error("wrong phase") },
      fn(_, n) { Ok(graph.Finish(n, n)) },
      [],
    )
  let assert Ok(definition) = graph.build(spec([selecting]))
  compiled.prepare(definition, 0)
  |> should.equal(Error(graph.InputSelectionFailed("wrong phase")))
  let accepting = counter(fn(_, _) { Error("decision rejected") }, [])
  let assert Ok(definition) = graph.build(spec([accepting]))
  let assert Ok(#(state, prepared)) = compiled.prepare(definition, 0)
  compiled.accept(definition, state, prepared, "1")
  |> should.equal(Error(graph.TransitionFailed("decision rejected")))
  let assert Error(graph.OperationRejected(operation.OutputDecodingFailed(_))) =
    compiled.accept(definition, state, prepared, "true")
  let assert Error(graph.StateDecodingFailed(_)) =
    compiled.accept(definition, "true", prepared, "1")
}

pub fn a_successor_whose_input_cannot_be_selected_releases_no_decision_test() {
  let first =
    counter(fn(_, n) { Ok(graph.Continue(n, id("other"))) }, [id("other")])
  let other =
    graph.node(
      id("other"),
      increment(),
      fn(_) { Error("cannot select successor") },
      fn(_, n) { Ok(graph.Finish(n, n)) },
      [],
    )
  let assert Ok(definition) = graph.build(spec([first, other]))
  let assert Ok(#(state, prepared)) = compiled.prepare(definition, 0)
  compiled.accept(definition, state, prepared, "1")
  |> should.equal(Error(graph.InputSelectionFailed("cannot select successor")))
}
