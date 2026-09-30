//// Shared family budget values. Admission counts are conservative: a saved
//// grant is never refunded implicitly, even when its work fails or is lost.

pub type Limits {
  Limits(work: Int, children: Int, depth: Int)
}

pub type Denial {
  WorkLimit(limit: Int)
  ChildLimit(limit: Int)
  DepthLimit(maximum: Int, requested: Int)
}

pub type Usage {
  Usage(work: Int, children: Int)
}
