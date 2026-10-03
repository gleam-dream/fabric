//// The UTC clock that approval deadlines are judged by, in Unix
//// milliseconds, and its conversion to `gleam/time` timestamps.

import gleam/time/timestamp.{type Timestamp}

@external(erlang, "fabric_ffi", "system_time_ms")
pub fn now() -> Int

pub fn to_timestamp(milliseconds: Int) -> Timestamp {
  timestamp.from_unix_seconds_and_nanoseconds(
    milliseconds / 1000,
    { milliseconds % 1000 } * 1_000_000,
  )
}

pub fn to_milliseconds(at: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1000 + nanoseconds / 1_000_000
}
