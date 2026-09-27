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
  codec.field("city", codec.string())
  |> codec.imap(City, fn(city) { city.name })
}

pub fn forecast_codec() -> Codec(Forecast) {
  codec.field("summary", codec.string())
  |> codec.imap(Forecast, fn(forecast) { forecast.summary })
}

pub fn transfer_codec() -> Codec(Transfer) {
  let assert Ok(transfer) =
    codec.record2(
      codec.required("to", codec.string()),
      codec.required("amount", codec.int()),
      Transfer,
      fn(t) { t.to },
      fn(t) { t.amount },
    )
  transfer
}

pub fn receipt_codec() -> Codec(Receipt) {
  codec.field("receipt", codec.string())
  |> codec.imap(Receipt, fn(receipt) { receipt.id })
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
  city: City,
) -> Result(Forecast, WeatherError) {
  case city.name {
    "Paris" -> Ok(Forecast("sunny"))
    other -> Error(UnknownCity(other))
  }
}

/// Weather errors are safe to show the model.
pub fn weather_tool() -> tool.Tool(ctx) {
  tool.bind_reporting(weather_definition(), lookup_weather, fn(error) {
    let UnknownCity(name) = error
    tool.Explain("unknown city: " <> name)
  })
}

/// Transfers above 100 fail with a hidden typed error; a gateway timeout is
/// an uncertain effect.
pub fn transfer(
  _context: ctx,
  transfer: Transfer,
) -> Result(Receipt, TransferError) {
  case transfer.amount {
    amount if amount > 1000 -> Error(GatewayTimeout)
    amount if amount > 100 -> Error(InsufficientFunds(amount - 100))
    _ -> Ok(Receipt("r-" <> transfer.to))
  }
}

pub fn transfer_tool() -> tool.Tool(ctx) {
  tool.bind_reporting(transfer_definition(), transfer, fn(error) {
    case error {
      InsufficientFunds(_) -> tool.Explain("insufficient funds")
      GatewayTimeout -> tool.Uncertain("gateway timed out after sending")
    }
  })
}
