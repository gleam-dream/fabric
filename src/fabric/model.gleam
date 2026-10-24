//// The model port Fabric owns.
////
//// A `Model` is a function from a full `Request` to one `Reply`. Fabric keeps
//// the transcript itself and sends it whole on every turn, so a model never
//// needs hidden continuation state: a pure function of the request is a
//// complete, deterministic model, and `fabric/llm` adapts an llm_wire
//// provider to the same port.

import fabric/internal/model_port
import fabric/internal/run_id.{type RunId}
import fabric/internal/tool_call
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import json/blueprint/codec
import sinal/correlation.{type Correlation}

/// A tool call as the provider issued it. `id` is unique only within one
/// model turn. Build one with `tool_call`, and read it by label (`call.name`,
/// `call.arguments_json`): Fabric may add fields. `provider_id` and
/// `provider_state` carry provider replay metadata (for example a Google
/// thought signature) that must be sent back unchanged when the transcript is
/// replayed; `with_provider_replay` sets them.
pub type ToolCall =
  tool_call.ToolCall

/// A call to the tool `name` with the arguments the model sent, as JSON text.
pub fn tool_call(
  id id: String,
  name name: String,
  arguments_json arguments_json: String,
) -> ToolCall {
  tool_call.ToolCall(
    id:,
    name:,
    arguments_json:,
    provider_id: None,
    provider_state: None,
  )
}

/// Sets the provider's own call id and opaque replay state, kept with the
/// call and sent back unchanged when the transcript is replayed.
pub fn with_provider_replay(
  call: ToolCall,
  id provider_id: Option(String),
  state provider_state: Option(String),
) -> ToolCall {
  tool_call.ToolCall(..call, provider_id:, provider_state:)
}

/// Adapter-owned response metadata. `format` identifies its encoding and
/// version; only the adapter interprets `value`. Fabric stores it unchanged.
/// It must contain data only, never credentials or live process state.
pub type ProviderData {
  ProviderData(format: String, value: String)
}

/// One assistant response and the provider data that belongs to that response.
/// Plain application models use `None`; adapters retain everything needed to
/// send the turn back after a restart.
pub type AssistantTurn {
  AssistantTurn(text: String, calls: List(ToolCall), data: Option(ProviderData))
}

pub type Message {
  UserMessage(text: String)
  /// `turn.calls` is empty for a plain answer.
  AssistantMessage(turn: AssistantTurn)
  ToolResultMessage(call_id: String, content: String)
}

/// A tool declaration derived from the tool's input codec.
pub type ToolSpec {
  ToolSpec(name: String, description: String, schema: codec.Schema)
}

/// One model call. Read it by label: Fabric may add fields.
///
/// `run` and `turn` name the call: `turn` is the run's model attempt,
/// counting every retry, the same number `fabric/telemetry` reports.
/// `correlation` is the run's (see `fabric.start`): a model that makes
/// requests of its own tags them with it, as `fabric/llm` does, so one agent
/// serves every run and each call joins its run's events.
///
/// `answer` is the schema of the agent's final answer (`agent.with_answer`),
/// `None` for a plain text answer. A model that can constrain its output
/// asks the provider for it, as `fabric/llm` does; Fabric checks a
/// `FinalAnswer` against the agent's codec either way. A text it refuses
/// gets a corrective turn (`agent.with_answer_attempts`): the next request
/// holds the refused answer and a user message that says why and repeats
/// the schema. The run ends as `run.AnswerInvalid` when no attempt is left.
pub type Request {
  Request(
    run: RunId,
    turn: Int,
    correlation: Correlation,
    system: Option(String),
    messages: List(Message),
    tools: List(ToolSpec),
    answer: Option(codec.Schema),
  )
}

/// Tokens a provider reported for one reply.
pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

/// `usage` is `None` when the provider did not report it; Fabric never treats
/// a missing report as zero.
pub type Reply {
  /// The final answer. For an agent with an answer codec, `text` is the
  /// answer as JSON.
  FinalAnswer(text: String, usage: Option(Usage))
  ToolRequest(turn: AssistantTurn, usage: Option(Usage))
  Refusal(reason: String, usage: Option(Usage))
  /// The provider stopped at its output limit. Partial tool calls are dropped.
  Truncated(partial_text: String, usage: Option(Usage))
}

/// A failed model call. Build one with `error(kind, detail)`; Fabric reads
/// its kind to decide whether to try again (`is_retryable`), and waits at
/// least its `retry_after` before that attempt. Every attempt counts against
/// the run's turn limit.
pub opaque type ModelError {
  ModelError(kind: ErrorKind, detail: String, retry_after: Option(Duration))
}

/// What went wrong, as a stable classification. The first four kinds are
/// retryable: another attempt may succeed. This union may grow; match the
/// kinds you handle and keep a catch-all.
pub type ErrorKind {
  /// The provider could not be reached: the connection failed or was
  /// refused before a reply. Retryable.
  Unreachable
  /// The call did not finish in time: the agent's model timeout, a
  /// provider's deadline or HTTP 408. Retryable.
  TimedOut
  /// The provider asked to slow down (HTTP 429, or its rate-limit error).
  /// Retryable, usually after `retry_after`.
  RateLimited
  /// The provider failed or was overloaded for now (HTTP 5xx, Anthropic's
  /// 529). Retryable.
  Overloaded
  /// The provider refused the request as it was sent: a bad credential, a
  /// missing permission, an unknown model, a request it will not serve.
  /// Trying the same request again does not help.
  Rejected
  /// The request could not be built from the run's transcript and tools, so
  /// nothing was sent.
  InvalidRequest
  /// The reply could not be read: a broken stream, a protocol violation, or
  /// output beyond a limit.
  InvalidReply
  /// The model function crashed, or the process that ran it exited.
  Crashed
  /// Anything else; not retried.
  Other
}

/// A model failure of `kind`. `detail` says what happened, for logs and
/// stored records; it must not carry secrets.
pub fn error(kind: ErrorKind, detail: String) -> ModelError {
  ModelError(kind:, detail:, retry_after: None)
}

/// The provider's own delay before another attempt (its `Retry-After`).
/// Fabric waits at least this long before it retries a retryable failure,
/// and at most 10 minutes; a negative delay is no delay.
pub fn with_retry_after(error: ModelError, delay: Duration) -> ModelError {
  ModelError(..error, retry_after: Some(delay))
}

pub fn error_kind(error: ModelError) -> ErrorKind {
  error.kind
}

/// Whether another attempt may succeed: `Unreachable`, `TimedOut`,
/// `RateLimited` and `Overloaded`.
pub fn is_retryable(error: ModelError) -> Bool {
  case error.kind {
    Unreachable | TimedOut | RateLimited | Overloaded -> True
    Rejected | InvalidRequest | InvalidReply | Crashed | Other -> False
  }
}

/// The delay set with `with_retry_after`.
pub fn retry_after(error: ModelError) -> Option(Duration) {
  error.retry_after
}

/// The `detail` the error was built with.
pub fn error_detail(error: ModelError) -> String {
  error.detail
}

/// One line for logs: the kind, the detail and any provider delay.
pub fn describe_error(error: ModelError) -> String {
  let kind = case error.kind {
    Unreachable -> "provider unreachable"
    TimedOut -> "model call timed out"
    RateLimited -> "rate limited"
    Overloaded -> "provider overloaded"
    Rejected -> "request rejected"
    InvalidRequest -> "invalid request"
    InvalidReply -> "invalid reply"
    Crashed -> "model crashed"
    Other -> "model failed"
  }
  let delay = case error.retry_after {
    Some(delay) ->
      " (retry after "
      <> int.to_string(duration.to_milliseconds(delay))
      <> " ms)"
    None -> ""
  }
  kind <> ": " <> error.detail <> delay
}

/// A model: build one with `new`, or with `fabric/llm.model` for an
/// llm_wire provider.
pub type Model =
  model_port.Port(Request, Reply, ModelError)

/// Wraps a model function. The function runs in a task owned by the run; a
/// crash is contained and reported as a `Crashed` error, which is not
/// retried.
pub fn new(call: fn(Request) -> Result(Reply, ModelError)) -> Model {
  model_port.new(call)
}
