//// THROWAWAY (workflow composition experiment). Application-author code
//// shared by every variant: typed tools, the external policy, a Saga
//// workflow used as a tool, a sub-agent tool, and the scripted model.
//// Tools report to a `Probe` so tests can count effects and hold barriers.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import saga
import saga/execution
import wc/agent
import wc/codec.{type Codec, Codec}
import wc/inline
import wc/model.{type Message, type Model, type ToolCall, ToolCall}
import wc/probe.{type Probe}
import wc/saga_tool
import wc/tool.{type Tool}

// --- typed tool vocabulary (the application's own types) -----------------------

pub type Forecast {
  Forecast(city: String, celsius: Int)
}

pub type WeatherError {
  UnknownCity(String)
}

pub type Transfer {
  Transfer(from: String, to: String, cents: Int)
}

pub type Receipt {
  Receipt(reference: String)
}

pub type TransferError {
  InsufficientFunds
}

pub type TripError {
  NoHotel(city: String)
}

pub type Itinerary {
  Itinerary(flight: String, hotel: String, charge: String)
}

// --- tools -------------------------------------------------------------------

pub fn lookup_weather(probe: Probe) -> Tool {
  tool.define(
    "lookup_weather",
    codec.field("city", codec.string()),
    forecast_codec(),
    Codec(
      fn(e) {
        let UnknownCity(city) = e
        json.object([#("unknown_city", json.string(city))])
      },
      decode.field("unknown_city", decode.string, fn(c) {
        decode.success(UnknownCity(c))
      }),
    ),
    fn(city) {
      probe.record(probe, "weather:start:" <> city)
      case string.starts_with(city, "gated") {
        True -> probe.gate(probe, city)
        False -> Nil
      }
      probe.record(probe, "weather:end:" <> city)
      case city {
        "Atlantis" -> Error(UnknownCity(city))
        _ -> Ok(Forecast(city, 21))
      }
    },
  )
}

pub fn transfer_funds(probe: Probe) -> Tool {
  tool.define_reporting(
    "transfer_funds",
    transfer_codec(),
    Codec(
      fn(r: Receipt) { json.object([#("receipt", json.string(r.reference))]) },
      decode.field("receipt", decode.string, fn(r) {
        decode.success(Receipt(r))
      }),
    ),
    Codec(fn(_) { json.string("insufficient_funds") }, {
      use _ <- decode.then(decode.string)
      decode.success(InsufficientFunds)
    }),
    fn(transfer) {
      probe.record(probe, "transfer:start:" <> transfer.to)
      case string.starts_with(transfer.to, "gated") {
        True -> probe.gate(probe, transfer.to)
        False -> Nil
      }
      probe.record(probe, "transfer:end:" <> transfer.to)
      case transfer.to, transfer.cents > 1_000_000 {
        "flaky-bank", _ -> tool.EffectUncertain("bank timed out after submit")
        _, True -> tool.Done(Error(InsufficientFunds))
        _, False -> tool.Done(Ok(Receipt("rcpt-" <> transfer.to)))
      }
    },
  )
}

/// A real multi-step Saga workflow exposed as one tool: the hotel depends on
/// the flight, the charge on both; a hotel failure releases the flight.
pub fn book_trip(probe: Probe) -> Tool {
  let reserve_flight =
    saga.step("reserve_flight", fn(city: String) {
      probe.record(probe, "flight:reserve:" <> city)
      Ok("FL-" <> city)
    })
    |> saga.undo(fn(_, flight) {
      probe.record(probe, "flight:release:" <> flight)
      Ok(Nil)
    })
  let reserve_hotel =
    saga.step("reserve_hotel", fn(pair: #(String, String)) {
      let #(city, _flight) = pair
      case city {
        "Atlantis" -> {
          probe.record(probe, "hotel:unavailable:" <> city)
          Error(NoHotel(city))
        }
        _ -> {
          probe.record(probe, "hotel:reserve:" <> city)
          Ok("HT-" <> city)
        }
      }
    })
    |> saga.undo(fn(_, hotel) {
      probe.record(probe, "hotel:release:" <> hotel)
      Ok(Nil)
    })
  let charge =
    saga.step("charge", fn(pair: #(String, String)) {
      probe.record(probe, "charge")
      Ok(Itinerary(pair.0, pair.1, "CH-1"))
    })
  let assert Ok(workflow) =
    saga.define("book_trip", fn(city) {
      let flight = saga.perform(city, reserve_flight)
      let hotel = saga.perform(saga.both(city, flight), reserve_hotel)
      saga.perform(saga.both(flight, hotel), charge)
    })
  saga_tool.from_workflow(
    "book_trip",
    codec.field("city", codec.string()),
    Codec(
      fn(i: Itinerary) {
        json.object([
          #("flight", json.string(i.flight)),
          #("hotel", json.string(i.hotel)),
          #("charge", json.string(i.charge)),
        ])
      },
      decode.failure(Itinerary("", "", ""), "unused"),
    ),
    Codec(
      fn(e: TripError) { json.object([#("no_hotel", json.string(e.city))]) },
      decode.failure(NoHotel(""), "unused"),
    ),
    workflow,
    execution.Config(..execution.config(), max_concurrency: 1),
  )
}

/// Starting a sub-agent is itself an action the parent's policy gates.
pub fn delegate_task(probe: Probe) -> Tool {
  tool.define(
    "delegate",
    codec.field("task", codec.string()),
    codec.field("answer", codec.string()),
    codec.string(),
    fn(task) {
      probe.record(probe, "delegate:start")
      let assert Ok(tools) = tool.registry([lookup_weather(probe)])
      case inline.run(child_model(probe), tools, allow_all, "child", task, 3) {
        Ok(answer) -> Ok(answer)
        Error(_) -> Error("child did not finish")
      }
    },
  )
}

pub fn all_tools(probe: Probe) -> tool.Registry {
  let assert Ok(registry) =
    tool.registry([
      lookup_weather(probe),
      transfer_funds(probe),
      book_trip(probe),
      delegate_task(probe),
    ])
  registry
}

// --- externally supplied policy ---------------------------------------------

pub fn policy(request: agent.ActionRequest) -> Result(agent.Decision, String) {
  case request.name {
    "transfer_funds" | "delegate" -> Ok(agent.RequireApproval)
    _ -> Ok(agent.Allow)
  }
}

pub fn allow_all(_: agent.ActionRequest) -> Result(agent.Decision, String) {
  Ok(agent.Allow)
}

// --- scripted models ---------------------------------------------------------

/// Transcript-pure: the first reply depends only on the prompt, the second
/// echoes every tool result with its call id, in transcript order.
pub fn scripted(probe: Probe) -> Model {
  fn(transcript: List(Message)) {
    probe.record(probe, "model:" <> int.to_string(list.length(transcript)))
    case list.last(transcript) {
      Ok(model.User(prompt)) -> Ok(model.Calls(first_calls(prompt)))
      _ -> Ok(model.Text(echo_results(transcript)))
    }
  }
}

fn child_model(probe: Probe) -> Model {
  fn(transcript: List(Message)) {
    probe.record(probe, "child-model")
    case list.last(transcript) {
      Ok(model.User(_)) -> Ok(model.Calls([weather_call("k1", "Oslo")]))
      _ -> Ok(model.Text("child:" <> echo_results(transcript)))
    }
  }
}

pub fn echo_results(transcript: List(Message)) -> String {
  list.filter_map(transcript, fn(m) {
    case m {
      model.ToolResult(id, content) -> Ok(id <> "=" <> content)
      _ -> Error(Nil)
    }
  })
  |> string.join(";")
}

fn first_calls(prompt: String) -> List(ToolCall) {
  case prompt {
    "weather and transfer" -> [
      weather_call("c1", "Lisbon"),
      transfer_call("c2", "acct-b", 2500),
    ]
    "weather and gated transfer" -> [
      weather_call("c1", "Lisbon"),
      transfer_call("c2", "gated-bank", 2500),
    ]
    "gated weather and gated transfer" -> [
      weather_call("c1", "gated-Lisbon"),
      transfer_call("c2", "gated-bank", 2500),
    ]
    "gated weather and transfer" -> [
      weather_call("c1", "gated-Lisbon"),
      transfer_call("c2", "acct-b", 2500),
    ]
    "three gated lookups" -> [
      weather_call("c1", "gated-1"),
      weather_call("c2", "gated-2"),
      weather_call("c3", "gated-3"),
    ]
    "fast and gated" -> [
      weather_call("c1", "Lisbon"),
      weather_call("c2", "gated-Faro"),
    ]
    "failures" -> [
      weather_call("c1", "Atlantis"),
      transfer_call("c2", "flaky-bank", 100),
    ]
    "trip Porto" -> [ToolCall("c1", "book_trip", city_json("Porto"))]
    "trip Atlantis" -> [ToolCall("c1", "book_trip", city_json("Atlantis"))]
    "delegate" -> [
      ToolCall(
        "c1",
        "delegate",
        json.to_string(json.object([#("task", json.string("weather in Oslo"))])),
      ),
    ]
    _ -> [weather_call("c1", "Lisbon")]
  }
}

pub fn weather_call(id: String, city: String) -> ToolCall {
  ToolCall(id, "lookup_weather", city_json(city))
}

fn transfer_call(id: String, to: String, cents: Int) -> ToolCall {
  ToolCall(
    id,
    "transfer_funds",
    codec.to_string(transfer_codec(), Transfer("acct-a", to, cents)),
  )
}

fn city_json(city: String) -> String {
  json.to_string(json.object([#("city", json.string(city))]))
}

// --- codecs ------------------------------------------------------------------

fn forecast_codec() -> Codec(Forecast) {
  Codec(
    fn(f: Forecast) {
      json.object([
        #("city", json.string(f.city)),
        #("celsius", json.int(f.celsius)),
      ])
    },
    {
      use city <- decode.field("city", decode.string)
      use celsius <- decode.field("celsius", decode.int)
      decode.success(Forecast(city, celsius))
    },
  )
}

fn transfer_codec() -> Codec(Transfer) {
  Codec(
    fn(t: Transfer) {
      json.object([
        #("from", json.string(t.from)),
        #("to", json.string(t.to)),
        #("cents", json.int(t.cents)),
      ])
    },
    {
      use from <- decode.field("from", decode.string)
      use to <- decode.field("to", decode.string)
      use cents <- decode.field("cents", decode.int)
      decode.success(Transfer(from, to, cents))
    },
  )
}
