//// A failed model call is an opaque `model.ModelError` with a stable kind,
//// whether another attempt may help, and the provider's delay before it.
//// `fabric/llm` maps llm_wire's typed failure and its `Retry-After`, and the
//// runner waits that delay before the retry.

import fabric
import fabric/agent
import fabric/internal/model_port
import fabric/llm
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import llm_wire
import llm_wire/message
import llm_wire/testing
import sinal/correlation

pub fn kinds_decide_whether_a_retry_may_help_test() {
  [
    #(model.Unreachable, True),
    #(model.TimedOut, True),
    #(model.RateLimited, True),
    #(model.Overloaded, True),
    #(model.Rejected, False),
    #(model.InvalidRequest, False),
    #(model.InvalidReply, False),
    #(model.Crashed, False),
    #(model.Other, False),
  ]
  |> list.each(fn(case_) {
    let #(kind, retryable) = case_
    let error = model.error(kind, "detail")
    model.error_kind(error) |> should.equal(kind)
    model.is_retryable(error) |> should.equal(retryable)
    model.retry_after(error) |> should.equal(None)
  })
}

pub fn an_error_carries_its_detail_and_delay_test() {
  let error =
    model.error(model.RateLimited, "slow down")
    |> model.with_retry_after(duration.seconds(2))
  model.error_detail(error) |> should.equal("slow down")
  model.retry_after(error) |> should.equal(Some(duration.seconds(2)))
  model.describe_error(error)
  |> should.equal("rate limited: slow down (retry after 2000 ms)")
}

/// A playback client that answers every request with `replies`, in order.
fn client(replies: List(testing.Reply), delay: Option(duration.Duration)) {
  let assert Ok(prepared) =
    llm_wire.prepare(
      testing.config(),
      llm_wire.request("m", [message.User("hi")]),
    )
  let exchanges =
    list.index_map(replies, fn(reply, index) {
      let exchange = testing.exchange(prepared, reply)
      case index, delay {
        0, Some(delay) -> testing.with_retry_after(exchange, delay)
        _, _ -> exchange
      }
    })
  let assert Ok(client) =
    http_testing.script(exchanges)
    |> http_testing.matching(fn(_, _) { True })
    |> http_testing.playback(http_config.default())
  client
}

fn request() -> model.Request {
  model.Request(
    run: run.new_id(),
    turn: 1,
    correlation: correlation.from_key("model-error"),
    system: None,
    messages: [model.UserMessage("hi")],
    tools: [],
  )
}

fn failure(client: http_gun.Client) -> model.ModelError {
  let assert Error(error) =
    model_port.call(llm.model(client, testing.config(), "m"), request())
  error
}

/// A 429 with `Retry-After` is a retryable `RateLimited` error that keeps
/// the provider's delay; the Retry-After is no longer dropped.
pub fn a_rate_limit_keeps_the_providers_delay_test() {
  let error =
    failure(client(
      [testing.rate_limited(message.Custom("scripted"))],
      Some(duration.seconds(1)),
    ))
  model.error_kind(error) |> should.equal(model.RateLimited)
  model.is_retryable(error) |> should.be_true
  model.retry_after(error) |> should.equal(Some(duration.seconds(1)))
}

pub fn statuses_map_to_kinds_test() {
  let kind = fn(status) {
    failure(client(
      [testing.http_status(message.Custom("scripted"), status, "no")],
      None,
    ))
    |> model.error_kind
  }
  kind(401) |> should.equal(model.Rejected)
  kind(503) |> should.equal(model.Overloaded)
  kind(408) |> should.equal(model.TimedOut)
}

/// The runner waits the provider's delay, not its own shorter backoff,
/// before the retry; the retry then succeeds.
pub fn a_retry_waits_the_providers_delay_test() {
  let desk =
    agent.new(
      "rate-limited",
      llm.model(
        client(
          [
            testing.rate_limited(message.Custom("scripted")),
            testing.text("done"),
          ],
          Some(duration.seconds(1)),
        ),
        testing.config(),
        "m",
      ),
      [],
      policy.always_allow(),
    )
    |> agent.with_model_retry_delay(duration.milliseconds(1))
    |> support.agent
  let started = now()
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "hi",
      correlation: None,
    )
  fabric.await(handle, within: duration.seconds(10))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  { now() - started >= 1000 } |> should.be_true
}

/// A model function's own error keeps its kind in the stored outcome.
pub fn a_stored_failure_keeps_its_kind_test() {
  let desk =
    agent.new(
      "rejected",
      model.new(fn(_) {
        Error(
          model.error(model.Rejected, "bad key")
          |> model.with_retry_after(duration.seconds(3)),
        )
      }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "hi",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
    fabric.await(handle, within: duration.seconds(5))
  error
  |> should.equal(
    model.error(model.Rejected, "bad key")
    |> model.with_retry_after(duration.seconds(3)),
  )
}

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int
