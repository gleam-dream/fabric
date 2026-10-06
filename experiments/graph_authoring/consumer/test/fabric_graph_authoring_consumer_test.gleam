import fabric_graph_authoring as graph
import fabric_graph_authoring_consumer as example
import gleam/list
import gleeunit
import gleeunit/should
import json/blueprint/codec

pub fn main() -> Nil {
  gleeunit.main()
}

// A separately authored graph retains native heterogeneous operation
// types and reaches a typed result through repeated visits to the same nodes.
pub fn bounded_generation_and_review_test() {
  let assert Ok(report) = example.run(6)
  report.outcome |> should.equal(Ok(example.Draft(3, "draft 3")))
  report.trace
  |> list.map(fn(step) { step.activation.ordinal })
  |> should.equal([1, 2, 3, 4, 5, 6])
}

pub fn exact_limit_stops_before_next_review_test() {
  let assert Ok(report) = example.run(5)
  report.outcome |> should.equal(Error(graph.ActivationLimitReached(5)))
  report.state
  |> should.equal(example.Reviewing(example.Draft(3, "draft 3")))
  report.trace |> list.length |> should.equal(5)
}

pub fn boolean_score_and_enum_use_the_same_control_contract_test() {
  let score_codec = codec.integer_between(0, 4)
  let enum_codec =
    codec.string_enum([
      #("accept", example.Accept),
      #("revise", example.Revise),
    ])
  let assert Ok(boolean) =
    example.decision_graph(codec.bool(), fn(_, _) { Ok(True) }, fn(value) {
      case value {
        True -> example.Accept
        False -> example.Revise
      }
    })
  let assert Ok(score) =
    example.decision_graph(score_codec, fn(_, _) { Ok(4) }, fn(value) {
      case value >= 3 {
        True -> example.Accept
        False -> example.Revise
      }
    })
  let assert Ok(choice) =
    example.decision_graph(
      enum_codec,
      fn(_, _) { Ok(example.Accept) },
      fn(value) { value },
    )
  list.each([boolean, score, choice], fn(definition) {
    let report = graph.run(definition, Nil, 0)
    report.outcome |> should.equal(Ok("accepted"))
    report.trace
    |> list.map(fn(receipt) { graph.node_name(receipt.activation.node) })
    |> should.equal(["decide", "accept"])
  })
}

pub fn negative_decision_selects_revision_test() {
  let assert Ok(definition) =
    example.decision_graph(codec.bool(), fn(_, _) { Ok(False) }, fn(value) {
      case value {
        True -> example.Accept
        False -> example.Revise
      }
    })
  let report = graph.run(definition, Nil, 0)
  report.outcome |> should.equal(Ok("needs revision"))
  report.trace
  |> list.map(fn(receipt) { graph.node_name(receipt.activation.node) })
  |> should.equal(["decide", "revise"])
}

pub fn score_outside_the_rubric_never_reaches_a_route_test() {
  let score_codec = codec.integer_between(0, 4)
  let assert Ok(definition) =
    example.decision_graph(score_codec, fn(_, _) { Ok(5) }, fn(_) {
      example.Accept
    })
  let report = graph.run(definition, Nil, 0)
  let assert Error(graph.NodeFailed(_, graph.OutputEncodingFailed(_))) =
    report.outcome
  report.trace |> should.equal([])
}

pub fn recorded_decisions_and_phase_state_roundtrip_test() {
  let assert Ok(report) = example.run(6)
  report.trace
  |> list.map(fn(receipt) {
    codec.decode_json(example.state_codec(), receipt.state_json)
  })
  |> should.equal([
    Ok(example.Reviewing(example.Draft(1, "draft 1"))),
    Ok(example.Drafting(2)),
    Ok(example.Reviewing(example.Draft(2, "draft 2"))),
    Ok(example.Drafting(3)),
    Ok(example.Reviewing(example.Draft(3, "draft 3"))),
    Ok(example.Reviewing(example.Draft(3, "draft 3"))),
  ])
}
