//// Runs every usage example once and prints what it shows:
//// `gleam run` from this directory. The tests assert the same results.

import gleam/io
import gleam/option.{None}
import gleam/string
import sinal/correlation
import usage/correlation as usage_correlation
import usage/failures
import usage/family_budget
import usage/limits
import usage/reconcile
import usage/recovery
import usage/waiting

pub fn main() -> Nil {
  let assert Ok(_) = limits.tuned()
  io.println(
    "limits: tuned bounds build; out of range -> " <> limits.rejected(),
  )
  io.println(
    "failures: missing run -> "
    <> string.inspect(failures.missing_run())
    <> "; retried start -> "
    <> string.inspect(failures.retried_start()),
  )
  let seen = usage_correlation.seen_by_the_run(None)
  io.println(
    "correlation: derived "
    <> correlation.to_string(seen.in_request)
    <> " reached the tool call as "
    <> correlation.to_string(seen.in_tool_call),
  )
  io.println(
    "waiting: caller gave up -> "
    <> string.inspect(waiting.the_caller_gives_up())
    <> "; owner exited -> "
    <> string.inspect(waiting.the_owner_exits()),
  )
  io.println("family budget: " <> string.inspect(family_budget.spent()))
  io.println(
    "reconcile: actions needing it (waiting, cancelled, settled) -> "
    <> string.inspect(reconcile.counts()),
  )
  io.println("recovery: " <> string.inspect(recovery.supervised_sweeper()))
}
