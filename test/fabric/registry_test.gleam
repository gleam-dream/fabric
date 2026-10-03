import fabric
import fabric/agent
import fabric/internal/invocation
import fabric/internal/registry
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/apps
import fabric/support/codecs
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import sinal/correlation

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
    codec.custom(
      encode: fn(_) { Ok(value.String("x")) },
      decode: fn(_) { Ok(Nil) },
      schema: None,
      placeholder: Nil,
    )
  let custom =
    tool.define("custom", "", schemaless, codec.string())
    |> tool.bind(fn(_, _call, _) { Ok("ok") }, fn(_: Nil) {
      tool.Explain("failed")
    })
  registry.new([custom])
  |> should.equal(Error([registry.SchemaUnavailable("custom")]))
}

pub fn declarations_derive_from_the_input_codec_test() {
  let assert Ok(tools) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  let assert Ok(city_schema) = codec.schema(apps.city_codec())
  let assert Ok(transfer_schema) = codec.schema(apps.transfer_codec())
  codec.schema_json(apps.city_codec())
  |> should.equal(Ok(
    "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"city\":{\"description\":\"City to look up\",\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}",
  ))
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
  // A record reads its fields before it reports an unknown key.
  detail |> should.equal("$[\"city\"]: missing field")
  registry.admit(tools, "lookup_weather", "{\"city\":42}")
  |> should.equal(
    Error(registry.MalformedArguments("$[\"city\"]: expected a string")),
  )
}

pub fn invocation_distinguishes_success_failure_and_uncertainty_test() {
  let assert Ok(tools) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  let invoke = fn(name, args) {
    registry.invoke(tools, Nil, call(), name, args, unsettled)
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
      call(),
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
      fn(context: String, _call, city: apps.City) {
        Ok(context <> "@" <> city.name)
      },
      fn(_: Nil) { tool.Explain("failed") },
    )
  let assert Ok(tools) = registry.new([echo_context])
  registry.invoke(
    tools,
    "alice",
    call(),
    "whoami",
    "{\"city\":\"Rome\"}",
    unsettled,
  )
  |> should.equal(invocation.Returned("\"alice@Rome\""))
}

pub fn unencodable_output_is_a_host_failure_test() {
  let refusing =
    codec.string()
    |> codec.try_map(
      decode: Ok,
      encode: fn(_: String) { Error("no") },
      placeholder: "",
    )
  let broken =
    tool.define("broken", "", apps.city_codec(), refusing)
    |> tool.bind(fn(_, _call, _) { Ok("anything") }, fn(_: Nil) {
      tool.Explain("failed")
    })
  let assert Ok(tools) = registry.new([broken])
  let assert invocation.OutputUnencodable(_) =
    registry.invoke(
      tools,
      Nil,
      call(),
      "broken",
      "{\"city\":\"Rome\"}",
      unsettled,
    )
}

/// A scripted model builds its calls from the same typed definitions the
/// tools are bound from, so their arguments always decode.
pub fn a_typed_call_encodes_its_input_with_the_definition_test() {
  testing.call(apps.transfer_definition(), "t", apps.Transfer("bob", 10))
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

/// A policy matches an action on a tool's definition and reads its typed
/// input; any other tool matches nothing, and a call of the tool's name
/// whose arguments the definition's codec refuses is an error.
pub fn a_policy_reads_the_typed_input_of_its_tool_test() {
  let action = fn(tool, arguments) {
    policy.Action(
      support.id("run-1"),
      run.ActionId(1, "t"),
      tool,
      arguments,
      policy.InvokeTool,
    )
  }
  tool.input(
    apps.transfer_definition(),
    action("transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
  )
  |> should.equal(Ok(Some(apps.Transfer("bob", 10))))
  tool.input(
    apps.transfer_definition(),
    action("lookup_weather", "{\"city\":\"Paris\"}"),
  )
  |> should.equal(Ok(None))
  let assert Error(detail) =
    tool.input(apps.transfer_definition(), action("transfer_funds", "{}"))
  string.contains(detail, "transfer_funds") |> should.be_true
}

/// A policy written as the README writes it fails closed when the
/// definition it matches on has drifted from the tool the agent runs: a
/// call of that name whose arguments the policy's codec refuses stops the
/// run as a policy failure instead of being allowed.
pub fn a_drifted_definition_fails_the_policy_closed_test() {
  let drifted =
    tool.define(
      "transfer_funds",
      "An older transfer.",
      codecs.one_field("iban", codec.string()),
      codec.string(),
    )
  let gate = fn(_context: Nil, action: policy.Action) {
    use transfer <- result.try(tool.input(drifted, action))
    case transfer {
      Some(_) -> Ok(policy.RequireApproval(run.Requirement("treasurer", 1)))
      None -> Ok(policy.Allow)
    }
  }
  let desk =
    agent.new(
      "desk",
      scripted.plan([
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":5}"),
      ]),
      [apps.transfer_tool()],
      gate,
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "Pay",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Failed(run.PolicyFailed(_, _)))) =
    fabric.await(handle, within: duration.milliseconds(5000))
}

fn call() -> tool.Call {
  tool.Call(
    run: run.issued("registry"),
    action: run.ActionId(1, "c1"),
    correlation: correlation.from_key("registry"),
  )
}
