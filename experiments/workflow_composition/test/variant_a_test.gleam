//// THROWAWAY (workflow composition experiment). Variant A: Fabric-owned
//// controller and runtime, plain tasks; Saga only inside the book_trip tool.

import scenarios
import support.{A}
import wc/agent.{ActionId}

pub fn a_row1_4_durable_pause_restart_resume_test() {
  scenarios.durable_pause_and_resume(A)
}

pub fn a_row3_concurrent_answers_single_winner_test() {
  scenarios.concurrent_answers(A)
}

pub fn a_row5_cancel_while_running_test() {
  scenarios.cancel_while_running(A)
}

pub fn a_row5_cancel_while_paused_test() {
  scenarios.cancel_while_paused(A)
}

pub fn a_row6_failure_and_uncertain_effect_test() {
  scenarios.failure_and_uncertain_effect(A)
}

pub fn a_row7_concurrency_budget_test() {
  scenarios.concurrency_budget(A)
}

pub fn a_row7_turn_budget_test() {
  scenarios.turn_budget(A)
}

pub fn a_row7_budget_shared_across_batches_test() {
  let assert 1 = scenarios.budget_across_batches(A)
}

pub fn a_restart_mid_batch_keeps_completed_results_test() {
  let assert [ActionId(1, "c2")] = scenarios.restart_mid_batch(A)
}

pub fn a_row8_saga_workflow_as_tool_test() {
  scenarios.saga_workflow_as_tool(A)
}

pub fn a_row8_delegate_needs_durable_approval_test() {
  scenarios.delegate_needs_durable_approval(A)
}
