//// Read-only observation of an independently owned external job. A receipt
//// comes from an earlier submission; this binding never submits or cancels it.

import fabric/run
import gleam/result
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
  InvalidPollInterval(Int)
}

pub type Reference {
  Reference(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    operation: run.Identity,
  )
}

pub opaque type Observer(context, receipt, output) {
  Observer(
    identity: run.Identity,
    receipt: Codec(receipt),
    output: Codec(output),
    read: fn(context, receipt) -> Result(Progress(output), String),
    polling: Polling,
  )
}

/// The callback must be a repeatable read. An error means no authoritative
/// observation; `Failed` means the remote job has a definite failure outcome.
/// Canceling this observation leaves the remote job independently owned.
pub fn observe(
  identity: run.Identity,
  receipt: Codec(receipt),
  output: Codec(output),
  read: fn(context, receipt) -> Result(Progress(output), String),
) -> Observer(context, receipt, output) {
  Observer(identity, receipt, output, read, Manual)
}

/// Opt into automatic observation by a registered sweeper on a leased store.
/// The first observation is immediately eligible; later ready claims wait at
/// least this interval according to the backend's clock. Manual polling remains
/// available. Changing this interval changes the persisted operation contract.
pub fn with_poll_interval(
  observer: Observer(context, receipt, output),
  milliseconds: Int,
) -> Result(Observer(context, receipt, output), ConfigurationError) {
  case valid_polling(Every(milliseconds)) {
    True -> Ok(Observer(..observer, polling: Every(milliseconds)))
    False -> Error(InvalidPollInterval(milliseconds))
  }
}

@internal
pub fn valid_polling(polling: Polling) -> Bool {
  case polling {
    Manual -> True
    Every(ms) -> ms > 0 && ms <= 4_294_967_295
  }
}

@internal
pub fn polling(observer: Observer(context, receipt, output)) -> Polling {
  observer.polling
}

@internal
pub fn identity(observer: Observer(context, receipt, output)) -> run.Identity {
  observer.identity
}

@internal
pub fn receipt_codec(
  observer: Observer(context, receipt, output),
) -> Codec(receipt) {
  observer.receipt
}

@internal
pub fn output_codec(
  observer: Observer(context, receipt, output),
) -> Codec(output) {
  observer.output
}

@internal
pub fn reader(
  observer: Observer(context, receipt, output),
) -> fn(context, String) -> Result(Progress(String), String) {
  fn(context, encoded) {
    use receipt <- result.try(
      codec.decode_json(observer.receipt, encoded)
      |> result.map_error(codec.describe_decode_error),
    )
    use progress <- result.try(observer.read(context, receipt))
    case progress {
      Pending -> Ok(Pending)
      Cancelled -> Ok(Cancelled)
      Failed(reason) -> Ok(Failed(reason))
      Completed(output) ->
        codec.encode_json(observer.output, output)
        |> result.map(Completed)
        |> result.map_error(fn(_) {
          "job result cannot be encoded by its output codec"
        })
    }
  }
}
