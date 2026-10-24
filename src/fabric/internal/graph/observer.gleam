//// The representation behind `fabric/graph/job.Observer`. It is generic
//// over the polling and progress types so that `fabric/graph/job` can
//// define them and still alias this type.

import fabric/run
import json/blueprint/codec.{type Codec}

pub opaque type Observer(context, receipt, output, polling, progress) {
  Observer(
    identity: run.DefinitionId,
    receipt: Codec(receipt),
    output: Codec(output),
    polling: polling,
    /// Reads the job of an encoded receipt; a completed output is encoded.
    reader: fn(context, String) -> Result(progress, String),
  )
}

pub fn new(
  identity: run.DefinitionId,
  receipt: Codec(receipt),
  output: Codec(output),
  polling: polling,
  reader: fn(context, String) -> Result(progress, String),
) -> Observer(context, receipt, output, polling, progress) {
  Observer(identity:, receipt:, output:, polling:, reader:)
}

pub fn with_polling(
  observer: Observer(context, receipt, output, polling, progress),
  polling: polling,
) -> Observer(context, receipt, output, polling, progress) {
  Observer(..observer, polling:)
}

pub fn identity(
  observer: Observer(context, receipt, output, polling, progress),
) -> run.DefinitionId {
  observer.identity
}

pub fn receipt(
  observer: Observer(context, receipt, output, polling, progress),
) -> Codec(receipt) {
  observer.receipt
}

pub fn output(
  observer: Observer(context, receipt, output, polling, progress),
) -> Codec(output) {
  observer.output
}

pub fn polling(
  observer: Observer(context, receipt, output, polling, progress),
) -> polling {
  observer.polling
}

pub fn reader(
  observer: Observer(context, receipt, output, polling, progress),
) -> fn(context, String) -> Result(progress, String) {
  observer.reader
}
