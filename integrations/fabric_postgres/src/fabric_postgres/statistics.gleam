//// Database-wide diagnostic snapshots. Run ages measure time since the latest
//// durable record write, not time in a phase. Intervention groups can overlap.
//// Read one with `fabric_postgres.statistics`.

import gleam/option.{type Option}

pub type Group {
  Group(count: Int, oldest_record_age_ms: Option(Int))
}

pub type NodeLeases {
  NodeLeases(node: String, count: Int)
}

pub type ExpiredLeases {
  ExpiredLeases(count: Int, oldest_overdue_ms: Option(Int))
}

pub type Snapshot {
  Snapshot(
    sampled_at_ms: Int,
    working: Group,
    unattended: Group,
    waiting: Group,
    finished: Group,
    approval: Group,
    reconciliation: Group,
    unknown: Group,
    budget_records: Int,
    leases_per_node: List(NodeLeases),
    expired_leases: ExpiredLeases,
  )
}
