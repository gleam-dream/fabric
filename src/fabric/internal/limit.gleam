//// The range check behind every `InvalidLimit` a build step reports
//// (`agent.build`, `graph.build`, `definition.build`): a bound is stored by
//// its setter and checked once, with every problem reported at once.

import fabric/internal/budget/limits as family
import fabric/internal/budget/model as reservations
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}

/// The longest timer the runtime can set, in milliseconds: a longer wait
/// crashes the process that waits.
pub const longest_timer = 4_294_967_295

/// The largest count or duration a record keeps exactly (2^53 - 1, the
/// largest integer JSON readers agree on), the maximum of bounds that have
/// no other.
pub const largest = 9_007_199_254_740_991

/// A bound to check: its name, its value (`None` when unset or unbounded),
/// and its range, both ends included.
pub type Bound(limit) {
  Bound(limit: limit, value: Option(Int), minimum: Int, maximum: Int)
}

/// The bounds whose value is outside their range, in order, built with
/// `invalid` (an `InvalidLimit` constructor).
pub fn check(
  bounds: List(Bound(limit)),
  invalid: fn(limit, Int, Int, Int) -> error,
) -> List(error) {
  list.filter_map(bounds, fn(bound) {
    case bound {
      Bound(limit, Some(value), minimum, maximum)
        if value < minimum || value > maximum
      -> Ok(invalid(limit, value, minimum, maximum))
      _ -> Error(Nil)
    }
  })
}

/// The bounds of a family budget (`budget.limits`), when one is set:
/// work and children from 0, depth from 0 to 63.
pub fn family(
  budget: Option(family.Limits),
  work work: limit,
  children children: limit,
  depth depth: limit,
) -> List(Bound(limit)) {
  let read = fn(field: fn(family.Limits) -> Int) { option.map(budget, field) }
  [
    Bound(work, read(fn(limits) { limits.work }), 0, largest),
    Bound(children, read(fn(limits) { limits.children }), 0, largest),
    Bound(depth, read(fn(limits) { limits.depth }), 0, reservations.max_depth),
  ]
}

/// One line naming the setter, the value and its range.
pub fn describe(
  setter: String,
  value: Int,
  minimum: Int,
  maximum: Int,
) -> String {
  setter
  <> " is "
  <> int.to_string(value)
  <> ", outside "
  <> int.to_string(minimum)
  <> ".."
  <> int.to_string(maximum)
}
