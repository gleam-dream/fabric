import fabric
import fabric/budget
import fabric/run
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sinal/correlation
import usage/correlation as usage_correlation
import usage/failures
import usage/family_budget
import usage/limits
import usage/reconcile
import usage/recovery
import usage/summarize
import usage/support
import usage/waiting

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn tuned_bounds_build_test() {
  let assert Ok(_) = limits.tuned()
}

pub fn every_bound_out_of_range_is_reported_at_once_test() {
  let line = limits.rejected()
  let assert True = string.contains(line, "agent.with_max_turns")
  let assert True = string.contains(line, "agent.with_max_concurrency")
}

pub fn a_missing_run_is_not_found_test() {
  failures.missing_run() |> should.equal(fabric.NotFound)
}

pub fn a_retried_start_is_refused_and_says_whether_it_is_the_same_start_test() {
  failures.retried_start() |> should.equal(#(fabric.Refused, True))
}

pub fn a_model_failure_says_whether_to_retry_test() {
  let #(retryable, text) = failures.model_failure()
  let assert True = retryable
  let assert True = string.contains(text, "overloaded")
}

pub fn the_chosen_correlation_reaches_the_request_and_the_tool_call_test() {
  let chosen = correlation.from_key("request-7")
  usage_correlation.seen_by_the_run(Some(chosen))
  |> should.equal(usage_correlation.Seen(chosen, chosen))
}

pub fn a_derived_correlation_is_shared_by_the_run_and_differs_between_runs_test() {
  let first = usage_correlation.seen_by_the_run(None)
  let second = usage_correlation.seen_by_the_run(None)
  first.in_request |> should.equal(first.in_tool_call)
  let assert True = first.in_request != second.in_request
}

pub fn a_caller_that_gives_up_cancels_the_run_test() {
  waiting.the_caller_gives_up() |> should.equal(run.Finished(run.Cancelled))
}

pub fn a_run_is_cancelled_when_its_owner_exits_test() {
  waiting.the_owner_exits() |> should.equal(run.Finished(run.Cancelled))
}

pub fn a_spent_family_budget_ends_the_run_test() {
  family_budget.spent()
  |> should.equal(
    run.Finished(run.BudgetExhausted(run.FamilyLimit(budget.WorkLimit(2)))),
  )
}

pub fn stored_evidence_settles_an_uncertain_effect_after_cancellation_test() {
  reconcile.counts() |> should.equal(#(1, 1, 0))
}

pub fn a_sweeper_runs_under_a_leased_store_test() {
  recovery.supervised_sweeper()
  |> should.equal(run.Finished(run.Completed("done")))
}

pub fn a_sweeper_needs_a_leased_store_test() {
  let assert True = string.contains(recovery.needs_a_leased_store(), "lease")
}

pub fn the_summarizer_returns_the_models_answer_test() {
  summarize.summarize(support.answering("A short summary."), "A long text.")
  |> should.equal(Ok(run.Finished(run.Completed("A short summary."))))
}
