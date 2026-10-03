//// The representation behind `fabric/graph/signal.Signal`.

import fabric/run
import json/blueprint/codec.{type Codec}

pub opaque type Signal(value) {
  Signal(identity: run.DefinitionId, codec: Codec(value))
}

pub fn new(identity: run.DefinitionId, codec: Codec(value)) -> Signal(value) {
  Signal(identity, codec)
}

pub fn identity(signal: Signal(value)) -> run.DefinitionId {
  signal.identity
}

pub fn codec(signal: Signal(value)) -> Codec(value) {
  signal.codec
}

pub fn encode(
  signal: Signal(value),
  value: value,
) -> Result(String, codec.EncodeError) {
  codec.encode_json(signal.codec, value)
}
