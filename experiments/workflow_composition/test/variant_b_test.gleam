//// THROWAWAY (workflow composition experiment). Variant B: Fabric-owned
//// controller and runtime; each dispatched tool batch is a runtime-defined Saga run.

import scenarios
import support.{B}
import wc/agent.{ActionId}

pub fn b_row1_4_durable_pause_restart_resume_test() {
  scenarios.durable_pause_and_resume(B)
}

pub fn b_row3_concurrent_answers_single_winner_test() {
  scenarios.concurrent_answers(B)
}

pub fn b_row5_cancel_while_running_test() {
  scenarios.cancel_while_running(B)
}

pub fn b_row5_cancel_while_paused_test() {
  scenarios.cancel_while_paused(B)
}

pub fn b_row6_failure_and_uncertain_effect_test() {
  scenarios.failure_and_uncertain_effect(B)
}

pub fn b_row7_concurrency_budget_test() {
  scenarios.concurrency_budget(B)
}

pub fn b_row7_turn_budget_test() {
  scenarios.turn_budget(B)
}

/// Evidence of a break: Saga's `max_concurrency` bounds one run only, so an
/// approval that arrives mid-batch starts a second run and exceeds the budget.
pub fn b_row7_budget_not_shared_across_batches_test() {
  let assert 2 = scenarios.budget_across_batches(B)
}

/// Evidence of a cost: a Saga run reports outputs only at its end, so a
/// result finished before the restart was never committed and is uncertain.
pub fn b_restart_mid_batch_loses_completed_results_test() {
  let assert [ActionId(1, "c1"), ActionId(1, "c2")] =
    scenarios.restart_mid_batch(B)
}

pub fn b_row8_saga_workflow_as_tool_test() {
  scenarios.saga_workflow_as_tool(B)
}

pub fn b_row8_delegate_needs_durable_approval_test() {
  scenarios.delegate_needs_durable_approval(B)
}
