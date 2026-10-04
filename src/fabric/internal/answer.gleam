//// An agent's final answer: its schema for the model, the check a reply
//// must pass before a run commits `run.Completed`, and the decoder that
//// turns the stored text back into the answer.
////
//// A run stores the answer as the text the model sent. A plain agent's
//// answer is that text; an agent with `agent.with_answer` reads it with
//// its codec, and a stored text its codec refuses reads as
//// `run.AnswerInvalid` (a run stored before the agent had a codec, or
//// under another one).

import fabric/run.{
  type Outcome, type Snapshot, type Status, AnswerInvalid, BudgetExhausted,
  BudgetUnverifiable, Cancelled, Completed, Failed, Finished, OutputLimited,
  Refused, Snapshot, Suspended, Unattended, Working,
}
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/codec.{type Codec}

pub opaque type Answer(answer) {
  Answer(
    /// Encodes the answer as JSON: a typed answer's own codec, or
    /// `codec.string()` for the plain one.
    codec: Codec(answer),
    decode: fn(String) -> Result(answer, String),
    /// `None` for the plain answer, which declares no schema.
    schema: Option(Result(codec.Schema, codec.SchemaError)),
  )
}

/// The plain answer: the model's final text, unchecked.
pub fn text() -> Answer(String) {
  Answer(codec: codec.string(), decode: Ok, schema: None)
}

/// An answer that is JSON text `answer` decodes.
pub fn typed(answer: Codec(answer)) -> Answer(answer) {
  Answer(
    codec: answer,
    decode: fn(raw) {
      codec.decode_json(answer, raw)
      |> result.map_error(codec.describe_decode_error)
    },
    schema: Some(codec.schema(answer)),
  )
}

pub fn codec(answer: Answer(answer)) -> Codec(answer) {
  answer.codec
}

/// The schema to give the model: `Ok(None)` for the plain answer, and
/// `Error(Nil)` when a typed answer's codec has no schema.
pub fn schema(answer: Answer(answer)) -> Result(Option(codec.Schema), Nil) {
  case answer.schema {
    None -> Ok(None)
    Some(Ok(schema)) -> Ok(Some(schema))
    Some(Error(_)) -> Error(Nil)
  }
}

/// The answer the stored text `raw` stands for, or why it is not one.
pub fn decode(answer: Answer(answer), raw: String) -> Result(answer, String) {
  answer.decode(raw)
}

/// The check a reply passes before a run commits it as `Completed`.
pub fn check(answer: Answer(answer)) -> fn(String) -> Result(Nil, String) {
  fn(raw) { answer.decode(raw) |> result.replace(Nil) }
}

pub fn outcome(
  answer: Answer(answer),
  outcome: Outcome(String),
) -> Outcome(answer) {
  case outcome {
    Completed(raw) ->
      case answer.decode(raw) {
        Ok(value) -> Completed(value)
        Error(reason) -> AnswerInvalid(raw:, reason:)
      }
    AnswerInvalid(raw:, reason:) -> AnswerInvalid(raw:, reason:)
    Refused(reason) -> Refused(reason)
    OutputLimited(partial) -> OutputLimited(partial)
    BudgetExhausted(budget) -> BudgetExhausted(budget)
    BudgetUnverifiable(turn) -> BudgetUnverifiable(turn)
    Cancelled -> Cancelled
    Failed(failure) -> Failed(failure)
  }
}

pub fn status(
  answer: Answer(answer),
  status: Status(String),
) -> Status(answer) {
  case status {
    Working -> Working
    Unattended -> Unattended
    Suspended(approvals, uncertain) -> Suspended(approvals, uncertain)
    Finished(found) -> Finished(outcome(answer, found))
  }
}

pub fn snapshot(
  answer: Answer(answer),
  snapshot: Snapshot(String),
) -> Snapshot(answer) {
  Snapshot(
    run: snapshot.run,
    agent: snapshot.agent,
    incarnation: snapshot.incarnation,
    parent: snapshot.parent,
    status: status(answer, snapshot.status),
    turns_used: snapshot.turns_used,
    max_turns: snapshot.max_turns,
    usage: snapshot.usage,
    transcript: snapshot.transcript,
    actions: snapshot.actions,
  )
}
