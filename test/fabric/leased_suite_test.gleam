//// A representative part of the durable, approval, cancellation and
//// delegation tests, run again on a leased store (`support.leased`): a
//// single node that holds its runs' leases behaves as an unleased store.

import fabric/approval_test
import fabric/cancellation_test
import fabric/delegation_test
import fabric/drain_test
import fabric/durable_test
import fabric/store
import fabric/support
import gleam/option.{None, Some}
import gleeunit/should

/// Within `support.leased`, `support.store` makes leased stores, and only
/// there.
pub fn the_suite_runs_on_leased_stores_test() {
  support.leased(fn() {
    store.poll_interval(support.store()) |> should.equal(Some(500))
    store.poll_interval(support.restartable_store("unused"))
    |> should.equal(Some(500))
  })
  store.poll_interval(support.store()) |> should.equal(None)
  store.poll_interval(support.restartable_store("unused"))
  |> should.equal(None)
}

pub fn leased_killed_runner_is_recovered_test() {
  support.leased(
    durable_test.a_killed_runner_is_reported_and_its_run_recovered_test,
  )
}

pub fn leased_killed_runner_run_is_cancelled_test() {
  support.leased(
    durable_test.a_run_whose_runner_was_killed_can_be_cancelled_without_recovery_test,
  )
}

pub fn leased_approval_through_an_opened_handle_test() {
  support.leased(
    durable_test.an_approval_through_an_opened_handle_runs_the_action_test,
  )
}

pub fn leased_cancel_stored_of_a_live_run_test() {
  support.leased(
    durable_test.cancel_stored_stops_a_live_run_through_its_runner_test,
  )
}

pub fn leased_lost_runner_left_stopping_test() {
  support.leased(
    durable_test.cancelling_a_record_a_lost_runner_left_stopping_ends_it_test,
  )
}

pub fn leased_rejected_tool_test() {
  support.leased(
    approval_test.a_rejected_tool_never_runs_and_the_model_sees_the_reason_test,
  )
}

pub fn leased_concurrent_answers_test() {
  support.leased(
    approval_test.concurrent_answers_have_one_winner_and_the_tool_runs_once_test,
  )
}

pub fn leased_policy_at_answer_time_test() {
  support.leased(
    approval_test.the_policy_at_answer_time_wins_over_an_approval_test,
  )
}

pub fn leased_answer_racing_a_cancel_test() {
  support.leased(
    approval_test.an_answer_racing_a_cancel_has_a_defined_outcome_test,
  )
}

pub fn leased_cancelling_a_paused_run_test() {
  support.leased(approval_test.cancelling_a_paused_run_voids_its_approvals_test)
}

pub fn leased_held_run_is_cancelled_test() {
  support.leased(
    cancellation_test.a_held_run_is_cancelled_through_its_record_test,
  )
}

pub fn leased_held_runners_body_dies_test() {
  support.leased(
    cancellation_test.a_held_runners_running_body_dies_with_it_test,
  )
}

pub fn leased_held_child_is_cancelled_test() {
  support.leased(
    cancellation_test.a_held_child_is_cancelled_through_its_record_test,
  )
}

pub fn leased_tool_under_a_stopping_ancestor_test() {
  support.leased(
    cancellation_test.a_tool_under_a_stopping_ancestor_never_starts_test,
  )
}

pub fn leased_cancel_stored_of_a_settling_child_test() {
  support.leased(
    cancellation_test.cancel_stored_of_a_parent_with_a_settling_child_test,
  )
}

pub fn leased_child_pause_surfaces_test() {
  support.leased(
    delegation_test.a_child_pause_surfaces_to_the_parent_and_is_answered_through_it_test,
  )
}

pub fn leased_cancelling_a_parent_cancels_a_paused_child_test() {
  support.leased(
    delegation_test.cancelling_the_parent_cancels_a_paused_child_test,
  )
}

pub fn leased_cancelling_a_parent_stops_an_active_child_test() {
  support.leased(
    delegation_test.cancelling_the_parent_stops_an_active_child_test,
  )
}

pub fn leased_cancel_stored_cancels_the_children_first_test() {
  support.leased(delegation_test.cancel_stored_cancels_the_children_first_test)
}

pub fn leased_nested_delegation_depth_test() {
  support.leased(
    delegation_test.nested_delegation_is_bounded_by_the_root_depth_test,
  )
}

pub fn leased_drain_finishes_running_work_test() {
  support.leased(
    drain_test.a_stop_lets_a_running_tool_finish_and_hands_the_run_off_test,
  )
}

pub fn leased_drain_window_exhaustion_test() {
  support.leased(
    drain_test.a_tool_past_the_drain_window_is_uncertain_and_never_rerun_test,
  )
}

pub fn leased_drain_asks_for_queued_approval_again_test() {
  support.leased(
    drain_test.an_approved_queued_tool_is_asked_for_again_after_the_handoff_test,
  )
}

pub fn leased_drain_waits_for_model_reply_test() {
  support.leased(drain_test.a_stop_waits_for_the_model_reply_in_flight_test)
}

pub fn leased_drain_preserves_suspended_run_test() {
  support.leased(drain_test.a_suspended_run_is_untouched_by_a_stop_test)
}

pub fn leased_store_outlives_draining_runners_test() {
  support.leased(drain_test.a_store_stops_after_its_draining_runners_test)
}

pub fn leased_drain_hands_off_children_test() {
  support.leased(
    drain_test.a_child_run_drains_on_its_own_and_is_recovered_with_its_parent_test,
  )
}

pub fn leased_approval_ahead_of_shutdown_test() {
  support.leased(
    drain_test.a_delegation_approved_ahead_of_the_stop_does_not_hold_up_the_drain_test,
  )
}

pub fn leased_delegation_decided_during_shutdown_test() {
  support.leased(
    drain_test.a_delegation_decided_during_the_stop_does_not_hold_up_the_drain_test,
  )
}

pub fn leased_drain_refunds_retry_turn_test() {
  support.leased(
    drain_test.a_retry_backoff_is_not_waited_for_and_its_turn_is_given_back_test,
  )
}

pub fn leased_shutdown_precedes_queued_report_test() {
  support.leased(
    drain_test.a_shutdown_queued_behind_a_report_is_taken_first_test,
  )
}

pub fn leased_start_during_shutdown_test() {
  support.leased(
    drain_test.a_tool_body_starting_a_run_during_the_stop_does_not_hold_up_the_drain_test,
  )
}
