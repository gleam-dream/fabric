//// Values that capture llm_wire settings never print the provider key: a
//// model from `fabric/llm` and an operation from `fabric/graph/llm` hold
//// the settings inside closures, so `string.inspect` shows a function
//// reference instead.

import fabric/graph/llm as graph_llm
import fabric/llm
import fabric/run
import fabric/support/codecs
import fabric/support/fake_provider
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire

const secret = "fabric-inspect-secret-key-3b8d"

fn hidden(value: a) -> Nil {
  string.contains(string.inspect(value), secret) |> should.be_false
}

pub fn inspecting_an_llm_model_or_operation_never_prints_the_key_test() {
  let fake = fake_provider.start([])
  let settings = fake_provider.google(fake, secret)
  hidden(llm.model(fake.client, settings, "inspect-model"))
  hidden(
    graph_llm.new(
      run.Identity("inspect-decision", 1),
      codec.string(),
      codecs.one_field("approve", codec.bool()),
      "decision",
      fn(_: Nil, text) {
        #(
          fake.client,
          settings,
          llm_wire.request("inspect-model", [llm_wire.user(text)]),
        )
      },
    ),
  )
  fake_provider.stop(fake)
}
