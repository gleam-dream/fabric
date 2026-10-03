//// The representation behind `fabric/budget.Limits`. Callers build one with
//// `budget.limits` and its setters; only Fabric constructs the record.

pub type Limits {
  Limits(work: Int, children: Int, depth: Int)
}
