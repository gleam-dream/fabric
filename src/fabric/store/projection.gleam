//// Every storage projection of one record, from one decode.
////
//// A database backend keeps, next to each record, columns that its queries
//// read: the phase, the retention links (`fabric/store/retention`), the
//// discovery wait (`fabric/store/discovery`) and the diagnostic statistics
//// (`fabric/store/statistics`). Each of those modules' `encode` decodes the
//// record text again. A backend that writes all of them on every insert and
//// compare-and-set calls `project` instead: it decodes the record once and
//// returns the same values those functions return.

import fabric/internal/stored_record
import fabric/store/discovery
import fabric/store/retention
import fabric/store/statistics
import gleam/option.{type Option}

pub type Projection {
  Projection(
    /// The record's `phase.tag` (for example `"ended"`), or `None` for a
    /// record without one, such as a family budget. For text that is not a
    /// supported record, the tag is read from the text when it has one.
    phase: Option(String),
    /// `retention.encode(run, record)`.
    retention: String,
    /// `discovery.encode(run, record)`.
    discovery: String,
    /// `statistics.encode(run, record)`.
    statistics: String,
  )
}

/// The projections of `record`, stored under the run id `run`, from one
/// decode of `record`.
pub fn project(run: String, record: String) -> Projection {
  let stored = stored_record.decode(record)
  Projection(
    phase: option.from_result(stored_record.phase_tag(stored, record)),
    retention: retention.encode_stored(run, stored),
    discovery: discovery.encode_stored(run, stored),
    statistics: statistics.encode_stored(run, stored),
  )
}
