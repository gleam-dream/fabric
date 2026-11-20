//// The deprecated `agent.build` keeps working until it is removed: its
//// agent is built once and copied whole into every process. Representative
//// tests run again with every test agent built that way (`built_once`):
//// typed tools, approval and cancellation, a sub-agent across a restart,
//// recovery of a parent with its child, restart of running tools, and a
//// late settlement.

import fabric/approval_test
import fabric/delegation_test
import fabric/durable_test
import fabric/runner_test
import fabric/settlement_test
import fabric/support

pub fn typed_tools_with_a_built_agent_test() {
  support.built_once(runner_test.run_completes_with_two_typed_tools_test)
}

pub fn an_approval_and_a_cancellation_with_a_built_agent_test() {
  support.built_once(fn() {
    runner_test.approval_suspends_the_run_as_data_test()
    approval_test.an_approved_tool_runs_once_after_a_restart_test()
    runner_test.cancel_kills_running_tools_and_records_them_uncertain_test()
  })
}

pub fn a_sub_agent_with_a_built_agent_test() {
  support.built_once(fn() {
    delegation_test.a_sub_agent_starts_only_after_approval_even_across_a_restart_test()
    delegation_test.recovering_the_parent_recovers_its_child_test()
    delegation_test.cancelling_the_parent_stops_an_active_child_test()
  })
}

pub fn recovery_with_a_built_agent_test() {
  support.built_once(
    durable_test.restart_keeps_results_and_takes_over_running_and_queued_tools_test,
  )
}

pub fn a_late_settlement_with_a_built_agent_test() {
  support.built_once(
    settlement_test.a_stopped_tool_is_settled_definitely_before_the_run_ends_test,
  )
}
