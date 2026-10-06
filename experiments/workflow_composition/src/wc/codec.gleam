//// JSON codec pair for the workflow composition experiment.
//// Typed tools and run records cross a JSON boundary; stored values
//// contain data, never closures.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/result

pub type Codec(a) {
  Codec(encode: fn(a) -> Json, decoder: Decoder(a))
}

pub fn to_string(codec: Codec(a), value: a) -> String {
  codec.encode(value) |> json.to_string
}

pub fn from_string(codec: Codec(a), text: String) -> Result(a, String) {
  json.parse(text, codec.decoder)
  |> result.map_error(fn(_) { "cannot decode: " <> text })
}

pub fn string() -> Codec(String) {
  Codec(json.string, decode.string)
}

pub fn int() -> Codec(Int) {
  Codec(json.int, decode.int)
}

/// A one-field object `{"<name>": value}`.
pub fn field(name: String, inner: Codec(a)) -> Codec(a) {
  Codec(fn(value) { json.object([#(name, inner.encode(value))]) }, {
    use value <- decode.field(name, inner.decoder)
    decode.success(value)
  })
}
