//// Read-only observation of an independently owned external job. A receipt
//// comes from an earlier submission; this binding never submits or cancels it.

import fabric/internal/graph/observer
import fabric/run
import gleam/result
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}

pub type Progress(output) {
  Pending
  Completed(output)
  Failed(reason: String)
  /// The service confirms that cancellation has settled.
  Cancelled
}

/// A stop request's progress is independent of the remote job's outcome.
pub type CancellationProgress {
  RequestQueued
  RequestStarted
  RequestAccepted
  RequestRefused(reason: String)
  RequestUncertain(evidence: String)
}

pub type Polling {
  Manual
  Every(milliseconds: Int)
}

pub type ConfigurationError {
  /// Under 1 ms or over 2^32 - 1 ms.
  InvalidPollInterval(Duration)
}

pub type Reference {
  Reference(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    operation: run.DefinitionId,
  )
}

/// A read-only binding to an external job: its identity, its receipt and
/// output codecs, how it is polled, and the read callback.
pub type Observer(context, receipt, output) =
  observer.Observer(context, receipt, output, Polling, Progress(String))

/// The callback must be a repeatable read. An error means no authoritative
/// observation; `Failed` means the remote job has a definite failure outcome.
/// Canceling this observation leaves the remote job independently owned.
pub fn observe(
  identity: run.DefinitionId,
  receipt: Codec(receipt),
  output: Codec(output),
  read: fn(context, receipt) -> Result(Progress(output), String),
) -> Observer(context, receipt, output) {
  observer.new(identity, receipt, output, Manual, reader(receipt, output, read))
}

/// Opt into automatic observation by a registered sweeper on a leased store.
/// The first observation is immediately eligible; later ready claims wait at
/// least this interval according to the backend's clock. Manual polling remains
/// available. Changing this interval changes the persisted operation contract,
/// which keeps it in whole milliseconds (`Every`).
pub fn with_poll_interval(
  observer: Observer(context, receipt, output),
  every: Duration,
) -> Result(Observer(context, receipt, output), ConfigurationError) {
  let polling = Every(duration.to_milliseconds(every))
  case valid_polling(polling) {
    True -> Ok(observer.with_polling(observer, polling))
    False -> Error(InvalidPollInterval(every))
  }
}

fn valid_polling(polling: Polling) -> Bool {
  case polling {
    Manual -> True
    Every(ms) -> ms > 0 && ms <= 4_294_967_295
  }
}

/// Reads the job of an encoded receipt, encoding a completed output.
fn reader(
  receipt_codec: Codec(receipt),
  output_codec: Codec(output),
  read: fn(context, receipt) -> Result(Progress(output), String),
) -> fn(context, String) -> Result(Progress(String), String) {
  fn(context, encoded) {
    use receipt <- result.try(
      codec.decode_json(receipt_codec, encoded)
      |> result.map_error(codec.describe_decode_error),
    )
    use progress <- result.try(read(context, receipt))
    case progress {
      Pending -> Ok(Pending)
      Cancelled -> Ok(Cancelled)
      Failed(reason) -> Ok(Failed(reason))
      Completed(output) ->
        codec.encode_json(output_codec, output)
        |> result.map(Completed)
        |> result.map_error(fn(_) {
          "job result cannot be encoded by its output codec"
        })
    }
  }
}
