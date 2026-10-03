//// Application-owned typed tools shared by the Fabric tests. Each tool has
//// its own input, output, and error types; only `fabric/tool` erases them.

import fabric/tool
import json/blueprint/codec.{type Codec}

pub type City {
  City(name: String)
}

pub type Forecast {
  Forecast(summary: String)
}

pub type WeatherError {
  UnknownCity(String)
}

pub type Transfer {
  Transfer(to: String, amount: Int)
}

pub type Receipt {
  Receipt(id: String)
}

pub type TransferError {
  InsufficientFunds(missing: Int)
  GatewayTimeout
}

pub fn city_codec() -> Codec(City) {
  use name <- codec.field(
    "city",
    codec.describe(codec.string(), "City to look up"),
    get: fn(city) { city.name },
  )
  codec.success(City(name))
}

pub fn forecast_codec() -> Codec(Forecast) {
  use summary <- codec.field("summary", codec.string(), get: fn(forecast) {
    forecast.summary
  })
  codec.success(Forecast(summary))
}

pub fn transfer_codec() -> Codec(Transfer) {
  use to <- codec.field(
    "to",
    codec.describe(codec.string(), "Recipient account"),
    get: fn(t) { t.to },
  )
  use amount <- codec.field(
    "amount",
    codec.describe(codec.int(), "Amount in cents"),
    get: fn(t) { t.amount },
  )
  codec.success(Transfer(to:, amount:))
}

pub fn receipt_codec() -> Codec(Receipt) {
  use id <- codec.field("receipt", codec.string(), get: fn(receipt) {
    receipt.id
  })
  codec.success(Receipt(id))
}

pub fn weather_definition() -> tool.Definition(City, Forecast) {
  tool.define(
    "lookup_weather",
    "Look up the weather forecast for a city.",
    city_codec(),
    forecast_codec(),
  )
}

pub fn transfer_definition() -> tool.Definition(Transfer, Receipt) {
  tool.define(
    "transfer_funds",
    "Transfer an amount to a recipient.",
    transfer_codec(),
    receipt_codec(),
  )
}

/// `Paris` is sunny; any other city is unknown (a typed failure).
pub fn lookup_weather(
  _context: ctx,
  _call: tool.Call,
  city: City,
) -> Result(Forecast, WeatherError) {
  case city.name {
    "Paris" -> Ok(Forecast("sunny"))
    other -> Error(UnknownCity(other))
  }
}

/// Weather errors are safe to show the model.
pub fn weather_tool() -> tool.Tool(ctx) {
  tool.bind(weather_definition(), lookup_weather, fn(error) {
    let UnknownCity(name) = error
    tool.Explain("unknown city: " <> name)
  })
}

/// Transfers above 100 fail with a hidden typed error; a gateway timeout is
/// an uncertain effect.
pub fn transfer(
  _context: ctx,
  _call: tool.Call,
  transfer: Transfer,
) -> Result(Receipt, TransferError) {
  case transfer.amount {
    amount if amount > 1000 -> Error(GatewayTimeout)
    amount if amount > 100 -> Error(InsufficientFunds(amount - 100))
    _ -> Ok(Receipt("r-" <> transfer.to))
  }
}

pub fn transfer_tool() -> tool.Tool(ctx) {
  tool.bind(transfer_definition(), transfer, fn(error) {
    case error {
      InsufficientFunds(_) -> tool.Explain("insufficient funds")
      GatewayTimeout -> tool.Uncertain("gateway timed out after sending")
    }
  })
}
