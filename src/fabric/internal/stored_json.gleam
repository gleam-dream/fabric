//// Decoding of JSON text that Fabric itself encoded from application values
//// and stored in a run's record: a graph's state and answer, an
//// activation's input, output and job receipt, a child's input and output.
////
//// json_blueprint's `codec.decode_json` applies `value.default_limits()`
//// (1 MiB, depth 128), which guard text from a model, a tool call or a
//// request. Fabric's own text is read from the record store, which Fabric
//// trusts like its database (ADR 20), and is bounded where it is made: no
//// limit applied when it was encoded may refuse it when it is read back,
//// or a run whose state grew would be stranded. Untrusted text keeps
//// `codec.decode_json`.

import json/blueprint/codec.{type Codec, type DecodeError}
import json/blueprint/value

pub fn decode(codec: Codec(a), text: String) -> Result(a, DecodeError) {
  codec.decode_json_with_limits(codec, text, value.unlimited())
}
