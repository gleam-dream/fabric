//// A versioned native contract for a durable graph wait. It contains no
//// process handle or handler; a transport supplies a value when the wait
//// is ready. Identity and codec semantics must change versions together.

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

@internal
pub fn output(signal: Signal(value)) -> Codec(value) {
  signal.codec
}

@internal
pub fn encode(
  signal: Signal(value),
  value: value,
) -> Result(String, codec.EncodeError) {
  codec.encode_json(signal.codec, value)
}
