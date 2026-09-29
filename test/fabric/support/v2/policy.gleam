//// Frozen v2 types from Git 570502e928496b0203909f164a5e8fd021b8ddc8.
//// See README.md in this directory; do not adapt to current domain types.

pub type ActionId {
  ActionId(turn: Int, call_id: String)
}

pub type Requirement {
  Requirement(name: String, version: Int)
}
