import fabric_graph_authoring as graph
import gleam/list
import gleeunit/should
import json/blueprint/codec

fn id(name: String) -> graph.NodeId {
  let assert Ok(id) = graph.node_id(name)
  id
}

fn no_error(_error: Nil) -> graph.Failure {
  graph.DefiniteFailure("cannot fail")
}

fn spec(nodes: List(graph.Node(Nil, Int, Int))) -> graph.Spec(Nil, Int, Int) {
  graph.Spec(
    identity: graph.Identity("counter", 1),
    entry: id("counter"),
    nodes:,
    state: codec.int(),
    answer: codec.int(),
    max_activations: 4,
  )
}

fn counter(
  accept: fn(Int, Int) -> Result(graph.Command(Int, Int), String),
  destinations: List(graph.NodeId),
) -> graph.Node(Nil, Int, Int) {
  graph.node(
    id("counter"),
    graph.operation(
      graph.Identity("increment", 1),
      codec.int(),
      codec.int(),
      fn(_, input) { Ok(input + 1) },
      no_error,
    ),
    fn(state) { Ok(state) },
    accept,
    destinations,
  )
}

fn run_node(node: graph.Node(Nil, Int, Int)) -> graph.Report(Int, Int) {
  let assert Ok(definition) = graph.build(spec([node]))
  graph.run(definition, Nil, 0)
}

// G2: validating a graph is independent of running its operations.
pub fn invalid_graphs_are_rejected_test() {
  let node = counter(fn(state, value) { Ok(graph.Finish(state, value)) }, [])
  let base = spec([node])
  graph.build(graph.Spec(..base, nodes: [node, node]))
  |> should.equal(Error(graph.DuplicateNode(id("counter"))))
  graph.build(graph.Spec(..base, max_activations: 0))
  |> should.equal(Error(graph.InvalidActivationLimit(0)))
  graph.build(graph.Spec(..base, identity: graph.Identity("counter", 0)))
  |> should.equal(Error(graph.InvalidIdentity(graph.Identity("counter", 0))))
  graph.build(graph.Spec(..base, entry: id("missing")))
  |> should.equal(Error(graph.MissingEntry(id("missing"))))
  graph.node_id("  ") |> should.equal(Error(graph.InvalidNodeId))
}

pub fn unknown_destination_is_rejected_during_build_test() {
  let missing = id("missing")
  let node =
    counter(fn(state, _) { Ok(graph.Continue(state, missing)) }, [missing])
  graph.build(spec([node]))
  |> should.equal(Error(graph.UnknownDestination(id("counter"), missing)))
}

pub fn malformed_operation_identity_is_rejected_test() {
  let node =
    graph.node(
      id("counter"),
      graph.operation(
        graph.Identity("", 1),
        codec.int(),
        codec.int(),
        fn(_, input) { Ok(input) },
        no_error,
      ),
      fn(state) { Ok(state) },
      fn(state, value) { Ok(graph.Finish(state, value)) },
      [],
    )
  graph.build(spec([node]))
  |> should.equal(Error(graph.InvalidIdentity(graph.Identity("", 1))))
}

pub fn undeclared_route_does_not_apply_the_state_update_test() {
  let node =
    counter(fn(_, value) { Ok(graph.Continue(value, id("counter"))) }, [])
  let report = run_node(node)
  report.state |> should.equal(0)
  report.trace |> should.equal([])
  report.outcome
  |> should.equal(
    Error(graph.NodeFailed(
      graph.Activation(1, id("counter")),
      graph.DestinationNotAllowed(id("counter")),
    )),
  )
}

// G3: this cycle has no model turns. Its independent activation limit is real.
pub fn pure_cycle_is_bounded_and_preserves_distinct_visits_test() {
  let node =
    counter(fn(_, value) { Ok(graph.Continue(value, id("counter"))) }, [
      id("counter"),
    ])
  let report = run_node(node)
  report.state |> should.equal(4)
  report.outcome |> should.equal(Error(graph.ActivationLimitReached(4)))
  report.trace
  |> list.map(fn(receipt) { receipt.activation.ordinal })
  |> should.equal([1, 2, 3, 4])
  report.trace
  |> list.map(fn(receipt) { receipt.input_json })
  |> should.equal(["0", "1", "2", "3"])
}

// G1: an internal codec need not advertise provider JSON Schema.
pub fn schema_independent_codecs_and_receipts_test() {
  let internal = codec.new(codec.encode_int_value, codec.decode_int_value)
  let assert Error(_) = codec.schema(internal)
  let node =
    graph.node(
      id("counter"),
      graph.operation(
        graph.Identity("increment", 1),
        internal,
        internal,
        fn(_, input) { Ok(input + 1) },
        no_error,
      ),
      fn(state) { Ok(state) },
      fn(_, value) { Ok(graph.Finish(value, value)) },
      [],
    )
  let definition = spec([node])
  let assert Ok(definition) =
    graph.build(graph.Spec(..definition, state: internal, answer: internal))
  let report = graph.run(definition, Nil, 4)
  report.outcome |> should.equal(Ok(5))
  let assert [receipt] = report.trace
  codec.decode_json(internal, receipt.input_json) |> should.equal(Ok(4))
  codec.decode_json(internal, receipt.output_json) |> should.equal(Ok(5))
  codec.decode_json(internal, receipt.state_json) |> should.equal(Ok(5))
  receipt.route |> should.equal(graph.Completed("5"))
}

fn rejects_encode() -> codec.Codec(Int) {
  codec.new(
    fn(_) { Error(codec.CannotEncode(codec.CustomEncodeReason("rejected"))) },
    codec.decode_int_value,
  )
}

fn encoding_rejection() -> codec.EncodeError {
  codec.CannotEncode(codec.CustomEncodeReason("rejected"))
}

// G4: the failing stage is public evidence, not a generic failed operation.
pub fn selection_and_transition_failures_test() {
  let operation =
    graph.operation(
      graph.Identity("increment", 1),
      codec.int(),
      codec.int(),
      fn(_, input) { Ok(input + 1) },
      no_error,
    )
  let selecting =
    graph.node(
      id("counter"),
      operation,
      fn(_) { Error("wrong phase") },
      fn(state, value) { Ok(graph.Finish(state, value)) },
      [],
    )
  run_node(selecting).outcome
  |> should.equal(
    Error(graph.NodeFailed(
      graph.Activation(1, id("counter")),
      graph.InputSelectionFailed("wrong phase"),
    )),
  )
  let transitioning = counter(fn(_, _) { Error("invalid transition") }, [])
  run_node(transitioning).outcome
  |> should.equal(
    Error(graph.NodeFailed(
      graph.Activation(1, id("counter")),
      graph.TransitionFailed("invalid transition"),
    )),
  )
}

pub fn input_and_output_encoding_failures_test() {
  let input_fails =
    graph.operation(
      graph.Identity("increment", 1),
      rejects_encode(),
      codec.int(),
      fn(_, input) { Ok(input + 1) },
      no_error,
    )
  let output_fails =
    graph.operation(
      graph.Identity("increment", 1),
      codec.int(),
      rejects_encode(),
      fn(_, input) { Ok(input + 1) },
      no_error,
    )
  let node = fn(operation) {
    graph.node(
      id("counter"),
      operation,
      fn(state) { Ok(state) },
      fn(state, value) { Ok(graph.Finish(state, value)) },
      [],
    )
  }
  run_node(node(input_fails)).outcome
  |> should.equal(
    Error(graph.NodeFailed(
      graph.Activation(1, id("counter")),
      graph.InputEncodingFailed(encoding_rejection()),
    )),
  )
  run_node(node(output_fails)).outcome
  |> should.equal(
    Error(graph.NodeFailed(
      graph.Activation(1, id("counter")),
      graph.OutputEncodingFailed(encoding_rejection()),
    )),
  )
}

pub fn initial_state_and_final_answer_must_encode_test() {
  let node = counter(fn(state, value) { Ok(graph.Finish(state, value)) }, [])
  let base = spec([node])
  let assert Ok(bad_state) =
    graph.build(graph.Spec(..base, state: rejects_encode()))
  graph.run(bad_state, Nil, 0).outcome
  |> should.equal(Error(graph.InitialStateRejected(encoding_rejection())))
  let assert Ok(bad_answer) =
    graph.build(graph.Spec(..base, answer: rejects_encode()))
  graph.run(bad_answer, Nil, 0).outcome
  |> should.equal(
    Error(graph.NodeFailed(
      graph.Activation(1, id("counter")),
      graph.AnswerEncodingFailed(encoding_rejection()),
    )),
  )
}

pub fn state_encoding_failure_does_not_apply_update_test() {
  let assert Ok(only_initial) = codec.integer_between(0, 0)
  let node = counter(fn(_, value) { Ok(graph.Finish(value, value)) }, [])
  let base = spec([node])
  let assert Ok(definition) =
    graph.build(graph.Spec(..base, state: only_initial))
  let report = graph.run(definition, Nil, 0)
  report.state |> should.equal(0)
  report.trace |> should.equal([])
  let assert Error(graph.NodeFailed(_, graph.StateEncodingFailed(_))) =
    report.outcome
}

type BusinessError {
  Rejected
  TimedOutAfterSending
}

fn classify(error: BusinessError) -> graph.Failure {
  case error {
    Rejected -> graph.DefiniteFailure("rejected without effect")
    TimedOutAfterSending -> graph.UncertainEffect("request may have arrived")
  }
}

pub fn typed_handler_failures_preserve_uncertainty_test() {
  list.each([Rejected, TimedOutAfterSending], fn(failure) {
    let operation =
      graph.operation(
        graph.Identity("request", 1),
        codec.int(),
        codec.int(),
        fn(_, _) { Error(failure) },
        classify,
      )
    let node =
      graph.node(
        id("counter"),
        operation,
        fn(state) { Ok(state) },
        fn(state, value) { Ok(graph.Finish(state, value)) },
        [],
      )
    let report = run_node(node)
    report.outcome
    |> should.equal(
      Error(graph.NodeFailed(
        graph.Activation(1, id("counter")),
        graph.OperationFailed(classify(failure)),
      )),
    )
    report.trace |> should.equal([])
  })
}

fn rejecting_decoder() -> codec.Codec(Int) {
  codec.new(codec.encode_int_value, fn(_) {
    Error(codec.CannotDecode(codec.CustomDecodeReason("receipt is invalid")))
  })
}

pub fn receipt_decode_failures_are_distinct_test() {
  let input_fails =
    graph.operation(
      graph.Identity("echo", 1),
      rejecting_decoder(),
      codec.int(),
      fn(_, input) { Ok(input) },
      no_error,
    )
  let output_fails =
    graph.operation(
      graph.Identity("echo", 1),
      codec.int(),
      rejecting_decoder(),
      fn(_, input) { Ok(input) },
      no_error,
    )
  let node = fn(operation) {
    graph.node(
      id("counter"),
      operation,
      fn(state) { Ok(state) },
      fn(state, value) { Ok(graph.Finish(state, value)) },
      [],
    )
  }
  let assert Error(graph.NodeFailed(_, graph.InputDecodingFailed(_))) =
    run_node(node(input_fails)).outcome
  let assert Error(graph.NodeFailed(_, graph.OutputDecodingFailed(_))) =
    run_node(node(output_fails)).outcome
}
