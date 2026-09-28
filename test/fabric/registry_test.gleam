import fabric/internal/invocation
import fabric/internal/registry
import fabric/model
import fabric/support/apps
import fabric/tool
import gleam/option
import gleeunit/should
import json/blueprint/codec

pub fn registry_rejects_duplicate_names_test() {
  registry.new([apps.weather_tool(), apps.weather_tool()])
  |> should.equal(Error([registry.DuplicateName("lookup_weather")]))
}

pub fn registry_rejects_provider_incompatible_names_test() {
  let bad =
    tool.define("look up!", "", apps.city_codec(), apps.forecast_codec())
    |> tool.bind(apps.lookup_weather, fn(_) { tool.Explain("unknown city") })
  registry.new([bad])
  |> should.equal(Error([registry.InvalidName("look up!")]))
}

pub fn registry_rejects_codecs_without_schema_test() {
  let schemaless =
    codec.new(fn(_) { codec.encode_string_value("x") }, fn(_) { Ok(Nil) })
  let custom =
    tool.define("custom", "", schemaless, codec.string())
    |> tool.bind(fn(_, _) { Ok("ok") }, fn(_: Nil) { tool.Explain("failed") })
  registry.new([custom])
  |> should.equal(Error([registry.SchemaUnavailable("custom")]))
}

pub fn declarations_derive_from_the_input_codec_test() {
  let assert Ok(tools) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  let assert Ok(city_schema) = codec.schema(apps.city_codec())
  let assert Ok(transfer_schema) = codec.schema(apps.transfer_codec())
  registry.declarations(tools)
  |> should.equal([
    model.ToolSpec(
      "lookup_weather",
      "Look up the weather forecast for a city.",
      city_schema,
    ),
    model.ToolSpec(
      "transfer_funds",
      "Transfer an amount to a recipient.",
      transfer_schema,
    ),
  ])
}

pub fn admission_distinguishes_unknown_tools_and_malformed_arguments_test() {
  let assert Ok(tools) = registry.new([apps.weather_tool()])
  registry.admit(tools, "lookup_weather", "{\"city\":\"Paris\"}")
  |> should.equal(Ok(Nil))
  registry.admit(tools, "ghost", "{}")
  |> should.equal(Error(registry.NotRegistered))
  let assert Error(registry.MalformedArguments(_)) =
    registry.admit(tools, "lookup_weather", "{\"city\":")
  let assert Error(registry.MalformedArguments(detail)) =
    registry.admit(tools, "lookup_weather", "{\"town\":\"Paris\"}")
  detail |> should.not_equal("")
}

pub fn invocation_distinguishes_success_failure_and_uncertainty_test() {
  let assert Ok(tools) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  let invoke = fn(name, args) {
    registry.invoke(tools, Nil, name, args, unsettled)
  }
  invoke("lookup_weather", "{\"city\":\"Paris\"}")
  |> should.equal(invocation.Returned("{\"summary\":\"sunny\"}"))
  invoke("lookup_weather", "{\"city\":\"Oslo\"}")
  |> should.equal(invocation.FailedVisibly("{\"error\":\"unknown city: Oslo\"}"))
  invoke("transfer_funds", "{\"to\":\"bob\",\"amount\":5000}")
  |> should.equal(invocation.EffectUncertain("gateway timed out after sending"))
}

pub fn the_binding_classifies_every_typed_error_test() {
  let classified =
    apps.transfer_definition()
    |> tool.bind(apps.transfer, fn(error) {
      case error {
        apps.InsufficientFunds(_) -> tool.Explain("declined")
        apps.GatewayTimeout -> tool.Uncertain("timed out after sending")
      }
    })
  let assert Ok(tools) = registry.new([classified])
  let invoke = fn(amount) {
    registry.invoke(
      tools,
      Nil,
      "transfer_funds",
      "{\"to\":\"bob\",\"amount\":" <> amount <> "}",
      unsettled,
    )
  }
  invoke("500")
  |> should.equal(invocation.FailedVisibly("{\"error\":\"declined\"}"))
  invoke("5000")
  |> should.equal(invocation.EffectUncertain("timed out after sending"))
}

pub fn handler_receives_context_separately_from_input_test() {
  let echo_context =
    tool.define("whoami", "", apps.city_codec(), codec.string())
    |> tool.bind(
      fn(context: String, city: apps.City) { Ok(context <> "@" <> city.name) },
      fn(_: Nil) { tool.Explain("failed") },
    )
  let assert Ok(tools) = registry.new([echo_context])
  registry.invoke(tools, "alice", "whoami", "{\"city\":\"Rome\"}", unsettled)
  |> should.equal(invocation.Returned("\"alice@Rome\""))
}

pub fn unencodable_output_is_a_host_failure_test() {
  let refusing =
    codec.string()
    |> codec.try_imap(Ok, fn(_: String) {
      Error(codec.CannotEncode(codec.CustomEncodeReason("no")))
    })
  let broken =
    tool.define("broken", "", apps.city_codec(), refusing)
    |> tool.bind(fn(_, _) { Ok("anything") }, fn(_: Nil) {
      tool.Explain("failed")
    })
  let assert Ok(tools) = registry.new([broken])
  let assert invocation.OutputUnencodable(_) =
    registry.invoke(tools, Nil, "broken", "{\"city\":\"Rome\"}", unsettled)
}

/// A scripted model builds its calls from the same typed definitions the
/// tools are bound from, so their arguments always decode.
pub fn a_typed_call_encodes_its_input_with_the_definition_test() {
  tool.call(apps.transfer_definition(), "t", apps.Transfer("bob", 10))
  |> should.equal(
    Ok(model.ToolCall(
      "t",
      "transfer_funds",
      "{\"to\":\"bob\",\"amount\":10}",
      provider_id: option.None,
      provider_state: option.None,
    )),
  )
}

/// No late settlement is expected from these tools.
fn unsettled(_, _) -> Result(Nil, tool.SettleError) {
  Error(tool.NotAwaited)
}
