//// Codec shorthands for test tools.

import json/blueprint/codec.{type Codec}

/// An object with the one required property `name`, decoded as its value.
pub fn one_field(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, fn(value) { value })
  codec.success(value)
}
