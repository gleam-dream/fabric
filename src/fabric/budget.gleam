//// A family budget: one bound shared by a root run and every run it
//// delegates to, below each run's own turn, token and sub-agent limits.
//// Admission counts are conservative: a saved grant is never refunded
//// implicitly, even when its work fails or is lost.
////
//// ```gleam
//// agent.new("desk", model, tools, policy)
//// |> agent.with_family_budget(
////   budget.limits(work: 200) |> budget.with_children(10) |> budget.with_depth(2),
//// )
//// ```

import fabric/internal/budget/limits as family

/// The bounds of one family. Build them with `limits`.
pub type Limits =
  family.Limits

/// At most `work` units of work in the whole family: each model attempt,
/// tool action and graph attempt counts one. As many sub-agent runs as
/// units of work, nested at most 16 levels below the root.
pub fn limits(work work: Int) -> Limits {
  family.Limits(work:, children: work, depth: 16)
}

/// At most `children` sub-agent and child runs in the whole family.
pub fn with_children(limits: Limits, children: Int) -> Limits {
  family.Limits(..limits, children:)
}

/// Child runs nest at most `depth` levels below the root (at most 63).
pub fn with_depth(limits: Limits, depth: Int) -> Limits {
  family.Limits(..limits, depth:)
}

/// Why the family budget refused work.
pub type Denial {
  WorkLimit(limit: Int)
  ChildLimit(limit: Int)
  DepthLimit(maximum: Int, requested: Int)
}

pub type Usage {
  Usage(work: Int, children: Int)
}
