//// A versioned native contract for a durable graph wait. It contains no
//// process handle or handler; a transport supplies a value when the wait
//// is ready. Identity and codec semantics must change versions together.

import fabric/internal/graph/signal as contract
import fabric/run
import json/blueprint/codec.{type Codec}

/// A signal contract: its identity and the codec of the value it delivers.
pub type Signal(value) =
  contract.Signal(value)

pub fn new(identity: run.DefinitionId, codec: Codec(value)) -> Signal(value) {
  contract.new(identity, codec)
}

pub fn identity(signal: Signal(value)) -> run.DefinitionId {
  contract.identity(signal)
}
