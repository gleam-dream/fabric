//// THROWAWAY (workflow composition experiment). Variant C: the whole agent
//// loop expressed as one Saga workflow, using only Saga's shipped API.
////
//// The graph is fixed at `define` time, so the loop is unrolled into
//// `max_turns` stages of two steps: a model step, then one step for the
//// whole tool batch (the batch size is unknown until the model replies).
//// Saga has no suspension, so approval is either an in-process wait inside
//// the batch step (`WaitInStep`) or a terminal `Hold` (`HoldForApproval`).

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import saga
import wc/agent
import wc/model.{type Message, type Model, type ToolCall}
import wc/tool

pub type ApprovalRequest {
  ApprovalRequest(call: ToolCall, reply: Subject(Bool))
}

pub type ApprovalMode {
  /// The batch step blocks on a Subject until a human answers. It holds a
  /// concurrency slot, is bounded by the step timeout, and dies with its run.
  WaitInStep(approver: Subject(ApprovalRequest))
  /// The batch step stops the run with `Hold`: a terminal `Unresolved`.
  HoldForApproval
}

pub type Conversation {
  Conversation(transcript: List(Message), answer: Option(String))
}

pub type LoopError {
  NeedsApproval(List(ToolCall))
  UncertainEffect(ToolCall, String)
  ModelFailed(String)
}

pub fn define(
  model: Model,
  tools: tool.Registry,
  policy: agent.Policy,
  mode: ApprovalMode,
  max_turns: Int,
) -> Result(
  saga.Workflow(Conversation, Conversation, LoopError, Nil),
  List(saga.DefinitionError),
) {
  saga.define("agent", fn(start) {
    int.range(from: 1, to: max_turns + 1, with: start, run: fn(port, turn) {
      port
      |> saga.perform(model_step(model, turn))
      |> saga.perform(batch_step(tools, policy, mode, turn))
    })
  })
}

pub fn begin(prompt: String) -> Conversation {
  Conversation([model.User(prompt)], None)
}

fn model_step(
  model: Model,
  turn: Int,
) -> saga.Step(Conversation, Conversation, LoopError, Nil) {
  saga.step("model-" <> int.to_string(turn), fn(conversation: Conversation) {
    case conversation.answer {
      Some(_) -> Ok(conversation)
      None ->
        case model(conversation.transcript) {
          Error(reason) -> Error(ModelFailed(reason))
          Ok(model.Text(text)) ->
            Ok(Conversation(
              list.append(conversation.transcript, [model.Assistant(text)]),
              Some(text),
            ))
          Ok(model.Calls(calls)) ->
            Ok(Conversation(
              list.append(conversation.transcript, [model.AssistantCalls(calls)]),
              None,
            ))
        }
    }
  })
}

fn batch_step(
  tools: tool.Registry,
  policy: agent.Policy,
  mode: ApprovalMode,
  turn: Int,
) -> saga.Step(Conversation, Conversation, LoopError, Nil) {
  saga.step("tools-" <> int.to_string(turn), fn(conversation: Conversation) {
    case conversation.answer, list.last(conversation.transcript) {
      None, Ok(model.AssistantCalls(calls)) -> {
        let results =
          list.try_map(calls, fn(call) {
            run_call(tools, policy, mode, turn, call)
          })
        case results {
          Error(error) -> Error(error)
          Ok(results) ->
            Ok(Conversation(list.append(conversation.transcript, results), None))
        }
      }
      _, _ -> Ok(conversation)
    }
  })
  // Neither an approval pause nor an uncertain effect is a failure to roll
  // back: the only non-terminal-failure option Saga offers is `Hold`.
  |> saga.compensate(max_attempts: 1, with: fn(failed) {
    case failed.failure {
      saga.Returned(error) -> saga.Hold(error)
      saga.Crashed(crash) ->
        saga.Hold(UncertainEffect(model.ToolCall("?", "?", "?"), crash.reason))
      saga.TimedOut ->
        saga.Hold(UncertainEffect(model.ToolCall("?", "?", "?"), "timed out"))
    }
  })
}

fn run_call(
  tools: tool.Registry,
  policy: agent.Policy,
  mode: ApprovalMode,
  turn: Int,
  call: ToolCall,
) -> Result(Message, LoopError) {
  let request =
    agent.ActionRequest(
      "saga",
      agent.ActionId(turn, call.id),
      call.name,
      call.arguments,
    )
  case tool.lookup(tools, call.name), policy(request) {
    Error(Nil), _ ->
      Ok(model.ToolResult(call.id, "{\"error\":\"unknown_tool\"}"))
    _, Error(reason) -> Error(ModelFailed("policy: " <> reason))
    _, Ok(agent.Deny(reason)) ->
      Ok(model.ToolResult(call.id, "{\"error\":\"" <> reason <> "\"}"))
    Ok(t), Ok(agent.Allow) -> invoke(t, call)
    Ok(t), Ok(agent.RequireApproval) ->
      case mode {
        HoldForApproval -> Error(NeedsApproval([call]))
        WaitInStep(approver) -> {
          let reply = process.new_subject()
          process.send(approver, ApprovalRequest(call, reply))
          case process.receive_forever(reply) {
            True -> invoke(t, call)
            False ->
              Ok(model.ToolResult(call.id, "{\"error\":\"approval_rejected\"}"))
          }
        }
      }
  }
}

fn invoke(t: tool.Tool, call: ToolCall) -> Result(Message, LoopError) {
  case tool.invoke(t, call.arguments) {
    tool.Visible(content, _) -> Ok(model.ToolResult(call.id, content))
    tool.Uncertain(evidence) -> Error(UncertainEffect(call, evidence))
    tool.BoundaryFailure(reason) -> Error(UncertainEffect(call, reason))
  }
}
