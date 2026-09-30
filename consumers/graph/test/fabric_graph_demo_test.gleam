import fabric/graph
import fabric_graph_demo
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn a_native_boolean_result_finishes_the_bounded_review_loop_test() {
  let done = fabric_graph_demo.execute(6)
  done.value |> should.equal(3)
  done.status |> should.equal(graph.Completed(3))
  list.map(done.receipts, fn(receipt) { receipt.activation })
  |> should.equal([1, 2, 3, 4, 5, 6])
  list.map(done.receipts, fn(receipt) { receipt.output_json })
  |> should.equal(["1", "false", "2", "false", "3", "true"])
}

pub fn mapped_review_loops_keep_native_state_private_and_answers_ordered_test() {
  let done = fabric_graph_demo.execute_batch([0, 2, 3])
  done.status |> should.equal(graph.Completed([3, 3, 4]))
  done.value |> should.equal([0, 2, 3])
  list.length(done.receipts) |> should.equal(1)
  list.length(done.forks) |> should.equal(1)
}

pub fn five_activations_stop_before_the_last_review_test() {
  let done = fabric_graph_demo.execute(5)
  done.status |> should.equal(graph.Exhausted)
  done.value |> should.equal(3)
  list.length(done.receipts) |> should.equal(5)
}

pub fn a_managed_agent_supplies_the_same_native_boolean_decision_test() {
  let done = fabric_graph_demo.execute_agent(6)
  done.status |> should.equal(graph.Completed(3))
  list.map(done.receipts, fn(receipt) { receipt.output_json })
  |> should.equal(["1", "false", "2", "false", "3", "true"])
}

pub fn a_human_signal_can_supply_the_same_native_decision_contract_test() {
  let #(handle, decision) = fabric_graph_demo.start_manual(6)
  let assert Ok(first) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = first.status
  first.value |> should.equal(1)
  let assert Ok(_) = graph.deliver(handle, reference, decision, False)
  let assert Ok(second) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = second.status
  second.value |> should.equal(2)
  let assert Ok(done) = graph.deliver(handle, reference, decision, True)
  done.status |> should.equal(graph.Completed(2))
  list.map(done.receipts, fn(receipt) { receipt.activation })
  |> should.equal([1, 2, 3, 4])
}
