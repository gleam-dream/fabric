//// THROWAWAY (workflow composition experiment). The Fabric-owned agent
//// controller: a pure transition `step(state, event) -> (state, effects)`.
//// Every state is plain data with a JSON codec, so a paused run is a stored
//// record and no process holds it.
////
//// Question served: can one small pure controller carry turns, policy,
//// durable approval, cancellation, uncertain effects, and budgets, leaving
//// tool execution to a pluggable executor (plain tasks or Saga)?

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/result
import wc/model.{type Message, type Reply, type ToolCall}
import wc/tool

// --- vocabulary --------------------------------------------------------------

/// A provider call id is unique only within one model turn (lab D2).
pub type ActionId {
  ActionId(turn: Int, call_id: String)
}

pub type Decision {
  Allow
  Deny(reason: String)
  RequireApproval
}

pub type ActionRequest {
  ActionRequest(run: String, action: ActionId, name: String, arguments: String)
}

/// Externally supplied. `Error` is a policy failure: the run halts closed.
pub type Policy =
  fn(ActionRequest) -> Result(Decision, String)

pub type Kind {
  Succeeded
  Failed
  Denied
  Rejected
  UnknownTool
  Reconciled
}

pub type Status {
  /// Admitted, not started. Safe to dispatch again after a restart.
  Queued
  AwaitingApproval(revision: Int)
  /// The start was committed before the tool body ran: its effect may exist.
  Running
  Answered(content: String, kind: Kind)
  /// Uncertain effect. Blocks the next model turn until reconciled.
  Unknown(evidence: String)
  /// Withdrawn by cancellation before it started.
  NotStarted
}

pub type Action {
  Action(id: ActionId, call: ToolCall, status: Status)
}

pub type End {
  Answer(text: String)
  Cancelled(unknown_effects: List(ActionId))
  BudgetExhausted
  HostFailed(reason: String)
}

pub type Phase {
  AwaitingModel(turn: Int)
  Acting(actions: List(Action))
  Cancelling(actions: List(Action))
  Ended(End)
}

pub type State {
  State(
    run: String,
    max_turns: Int,
    turns_used: Int,
    transcript: List(Message),
    approvals_issued: Int,
    phase: Phase,
  )
}

pub type ApprovalRef {
  ApprovalRef(action: ActionId, revision: Int)
}

pub type Answer {
  Approve
  Reject
}

pub type Event {
  ModelReplied(turn: Int, reply: Reply)
  ModelFailed(turn: Int, reason: String)
  /// The executor asks to start an action; accepted only while `Queued`.
  ToolStarting(ActionId)
  ToolReported(ActionId, tool.Outcome)
  /// The executor confirms nothing of this run executes any more.
  ToolsStopped
  ApprovalAnswered(ApprovalRef, Answer)
  Reconcile(ActionId, content: String)
  Cancel
  /// A new incarnation takes over a stored record whose runner was lost.
  Recover
}

pub type Effect {
  CallModel(turn: Int, transcript: List(Message))
  Dispatch(List(#(ActionId, ToolCall)))
  StopTools
}

pub type Rejection {
  StaleEvent
  WrongAction(ActionId)
  StaleApproval(current: Int)
  AlreadyAnswered
  NotReconcilable
  RunEnded
}

pub type Config {
  Config(policy: Policy, tools: tool.Registry)
}

// --- transitions -------------------------------------------------------------

pub fn new(
  run: String,
  prompt: String,
  max_turns: Int,
) -> Result(#(State, List(Effect)), String) {
  case max_turns > 0 {
    False -> Error("max_turns must be positive")
    True -> {
      let transcript = [model.User(prompt)]
      Ok(
        #(State(run, max_turns, 1, transcript, 0, AwaitingModel(1)), [
          CallModel(1, transcript),
        ]),
      )
    }
  }
}

pub fn step(
  config: Config,
  state: State,
  event: Event,
) -> Result(#(State, List(Effect)), Rejection) {
  case state.phase, event {
    Ended(_), _ -> Error(RunEnded)

    AwaitingModel(turn), ModelReplied(t, reply) if t == turn ->
      Ok(model_replied(config, state, turn, reply))
    AwaitingModel(turn), ModelFailed(t, reason) if t == turn ->
      Ok(#(State(..state, phase: Ended(HostFailed("model: " <> reason))), []))
    AwaitingModel(_), Cancel ->
      Ok(#(State(..state, phase: Ended(Cancelled([]))), []))
    AwaitingModel(_), Recover -> Ok(next_turn(state))
    AwaitingModel(_), _ -> Error(StaleEvent)

    Acting(actions), ToolStarting(id) ->
      update(actions, id, fn(status) {
        case status {
          Queued -> Ok(Running)
          _ -> Error(StaleEvent)
        }
      })
      |> result.map(fn(actions) {
        #(State(..state, phase: Acting(actions)), [])
      })
    Acting(actions), ToolReported(id, outcome) ->
      update(actions, id, report(outcome))
      |> result.map(fn(actions) {
        settle(State(..state, phase: Acting(actions)))
      })
    Acting(actions), ApprovalAnswered(ref, answer) ->
      answer_approval(config, state, actions, ref, answer)
    Acting(actions), Reconcile(id, content) ->
      update(actions, id, fn(status) {
        case status {
          Unknown(_) -> Ok(Answered(content, Reconciled))
          _ -> Error(NotReconcilable)
        }
      })
      |> result.map(fn(actions) {
        settle(State(..state, phase: Acting(actions)))
      })
    Acting(actions), Cancel -> Ok(cancel(state, actions))
    Acting(actions), Recover -> {
      let actions =
        list.map(actions, fn(action) {
          case action.status {
            Running ->
              Action(..action, status: Unknown("runner lost while running"))
            _ -> action
          }
        })
      let #(state, effects) = settle(State(..state, phase: Acting(actions)))
      #(state, list.append(effects, dispatch(actions)))
      |> Ok
    }
    Acting(_), _ -> Error(StaleEvent)

    Cancelling(actions), ToolReported(id, outcome) ->
      update(actions, id, report(outcome))
      |> result.map(fn(actions) {
        #(State(..state, phase: Cancelling(actions)), [])
      })
    Cancelling(actions), ToolsStopped | Cancelling(actions), Recover ->
      Ok(
        #(
          State(..state, phase: Ended(Cancelled(unknown_after_stop(actions)))),
          [],
        ),
      )
    Cancelling(_), ApprovalAnswered(..) -> Error(RunEnded)
    Cancelling(_), _ -> Error(StaleEvent)
  }
}

fn model_replied(
  config: Config,
  state: State,
  turn: Int,
  reply: Reply,
) -> #(State, List(Effect)) {
  case reply {
    model.Text(text) -> #(
      State(
        ..state,
        transcript: list.append(state.transcript, [model.Assistant(text)]),
        phase: Ended(Answer(text)),
      ),
      [],
    )
    model.Calls([]) -> #(
      State(..state, phase: Ended(HostFailed("empty tool batch"))),
      [],
    )
    model.Calls(calls) -> {
      let state =
        State(
          ..state,
          transcript: list.append(state.transcript, [
            model.AssistantCalls(calls),
          ]),
        )
      let admitted =
        list.try_fold(calls, #(state.approvals_issued, []), fn(acc, call) {
          let #(issued, actions) = acc
          let id = ActionId(turn, call.id)
          use status <- result.map(admit(config, state.run, id, call, issued))
          let issued = case status {
            AwaitingApproval(_) -> issued + 1
            _ -> issued
          }
          #(issued, [Action(id, call, status), ..actions])
        })
      case admitted {
        Error(reason) -> #(State(..state, phase: Ended(HostFailed(reason))), [])
        Ok(#(issued, actions)) -> {
          let actions = list.reverse(actions)
          let #(state, effects) =
            settle(
              State(..state, approvals_issued: issued, phase: Acting(actions)),
            )
          #(state, list.append(dispatch(actions), effects))
        }
      }
    }
  }
}

fn admit(
  config: Config,
  run: String,
  id: ActionId,
  call: ToolCall,
  issued: Int,
) -> Result(Status, String) {
  case tool.has(config.tools, call.name) {
    False -> Ok(Answered(error_json("unknown_tool"), UnknownTool))
    True ->
      case config.policy(ActionRequest(run, id, call.name, call.arguments)) {
        Error(reason) -> Error("policy: " <> reason)
        Ok(Allow) -> Ok(Queued)
        Ok(Deny(reason)) -> Ok(Answered(error_json(reason), Denied))
        Ok(RequireApproval) -> Ok(AwaitingApproval(issued + 1))
      }
  }
}

fn answer_approval(
  config: Config,
  state: State,
  actions: List(Action),
  ref: ApprovalRef,
  answer: Answer,
) -> Result(#(State, List(Effect)), Rejection) {
  use action <- result.try(
    list.find(actions, fn(a) { a.id == ref.action })
    |> result.replace_error(WrongAction(ref.action)),
  )
  use Nil <- result.try(case action.status {
    AwaitingApproval(revision) if revision == ref.revision -> Ok(Nil)
    AwaitingApproval(revision) -> Error(StaleApproval(revision))
    _ -> Error(AlreadyAnswered)
  })
  // Answering rechecks policy against the current world (lab D7).
  let decision = case answer {
    Reject -> Ok(Answered(error_json("approval_rejected"), Rejected))
    Approve ->
      case
        config.policy(ActionRequest(
          state.run,
          action.id,
          action.call.name,
          action.call.arguments,
        ))
      {
        Error(reason) -> Error("policy: " <> reason)
        Ok(Deny(reason)) -> Ok(Answered(error_json(reason), Denied))
        Ok(Allow) | Ok(RequireApproval) -> Ok(Queued)
      }
  }
  case decision {
    Error(reason) -> Ok(#(State(..state, phase: Ended(HostFailed(reason))), []))
    Ok(status) -> {
      let assert Ok(actions) = update(actions, action.id, fn(_) { Ok(status) })
      let #(state, effects) = settle(State(..state, phase: Acting(actions)))
      Ok(#(
        state,
        list.append(effects, case status {
          Queued -> [Dispatch([#(action.id, action.call)])]
          _ -> []
        }),
      ))
    }
  }
}

fn cancel(state: State, actions: List(Action)) -> #(State, List(Effect)) {
  let active =
    list.any(actions, fn(a) { a.status == Running || a.status == Queued })
  let actions =
    list.map(actions, fn(action) {
      case action.status {
        Queued | AwaitingApproval(_) -> Action(..action, status: NotStarted)
        _ -> action
      }
    })
  case active {
    True -> #(State(..state, phase: Cancelling(actions)), [StopTools])
    False -> #(
      State(..state, phase: Ended(Cancelled(unknown_after_stop(actions)))),
      [],
    )
  }
}

fn unknown_after_stop(actions: List(Action)) -> List(ActionId) {
  list.filter_map(actions, fn(action) {
    case action.status {
      Running | Unknown(_) -> Ok(action.id)
      _ -> Error(Nil)
    }
  })
}

fn report(outcome: tool.Outcome) -> fn(Status) -> Result(Status, Rejection) {
  fn(status) {
    case status {
      Running ->
        Ok(case outcome {
          tool.Visible(content, False) -> Answered(content, Succeeded)
          tool.Visible(content, True) -> Answered(content, Failed)
          tool.Uncertain(evidence) -> Unknown(evidence)
          tool.BoundaryFailure(reason) -> Unknown("boundary: " <> reason)
        })
      _ -> Error(StaleEvent)
    }
  }
}

/// When every action has a model-visible answer, feed the results back in
/// the model's own call order and ask for the next turn.
fn settle(state: State) -> #(State, List(Effect)) {
  case state.phase {
    Acting(actions) ->
      case list.all(actions, fn(a) { is_answered(a.status) }) {
        False -> #(state, [])
        True -> {
          let results =
            list.map(actions, fn(action) {
              let assert Answered(content, _) = action.status
              model.ToolResult(action.call.id, content)
            })
          next_turn(
            State(..state, transcript: list.append(state.transcript, results)),
          )
        }
      }
    _ -> #(state, [])
  }
}

/// Every attempted model call counts against the budget, including a call
/// re-issued after a lost runner (lab D9).
fn next_turn(state: State) -> #(State, List(Effect)) {
  case state.turns_used >= state.max_turns {
    True -> #(State(..state, phase: Ended(BudgetExhausted)), [])
    False -> {
      let turn = state.turns_used + 1
      #(State(..state, turns_used: turn, phase: AwaitingModel(turn)), [
        CallModel(turn, state.transcript),
      ])
    }
  }
}

fn dispatch(actions: List(Action)) -> List(Effect) {
  case list.filter(actions, fn(a) { a.status == Queued }) {
    [] -> []
    queued -> [Dispatch(list.map(queued, fn(a) { #(a.id, a.call) }))]
  }
}

fn is_answered(status: Status) -> Bool {
  case status {
    Answered(..) -> True
    _ -> False
  }
}

fn update(
  actions: List(Action),
  id: ActionId,
  change: fn(Status) -> Result(Status, Rejection),
) -> Result(List(Action), Rejection) {
  case list.any(actions, fn(a) { a.id == id }) {
    False -> Error(WrongAction(id))
    True ->
      list.try_map(actions, fn(action) {
        case action.id == id {
          False -> Ok(action)
          True ->
            change(action.status)
            |> result.map(fn(status) { Action(..action, status: status) })
        }
      })
  }
}

fn error_json(reason: String) -> String {
  json.to_string(json.object([#("error", json.string(reason))]))
}

// --- read model --------------------------------------------------------------

pub type PendingApproval {
  PendingApproval(ref: ApprovalRef, name: String, arguments: String)
}

pub type RunStatus {
  Working
  WaitingForApproval(List(PendingApproval))
  NeedsReconciliation(List(ActionId))
  Finished(End)
}

/// What an application sees. `WaitingForApproval` lists every pending
/// approval, even while other tools of the batch still run; `needs_runner`
/// tells whether any process is required at all.
pub fn status(state: State) -> RunStatus {
  case state.phase {
    Ended(end) -> Finished(end)
    AwaitingModel(_) | Cancelling(_) -> Working
    Acting(actions) -> {
      let running =
        list.any(actions, fn(a) { a.status == Running || a.status == Queued })
      let unknown =
        list.filter_map(actions, fn(a) {
          case a.status {
            Unknown(_) -> Ok(a.id)
            _ -> Error(Nil)
          }
        })
      let pending =
        list.filter_map(actions, fn(a) {
          case a.status {
            AwaitingApproval(revision) ->
              Ok(PendingApproval(
                ApprovalRef(a.id, revision),
                a.call.name,
                a.call.arguments,
              ))
            _ -> Error(Nil)
          }
        })
      case running, unknown, pending {
        False, [_, ..], _ -> NeedsReconciliation(unknown)
        _, _, [_, ..] -> WaitingForApproval(pending)
        _, _, [] -> Working
      }
    }
  }
}

/// Whether a live process is needed: a model call or tools are in flight.
pub fn needs_runner(state: State) -> Bool {
  case state.phase {
    AwaitingModel(_) | Cancelling(_) -> True
    Ended(_) -> False
    Acting(actions) ->
      list.any(actions, fn(a) { a.status == Running || a.status == Queued })
  }
}

// --- persistence codec -------------------------------------------------------

pub fn encode(state: State) -> String {
  json.object([
    #("run", json.string(state.run)),
    #("max_turns", json.int(state.max_turns)),
    #("turns_used", json.int(state.turns_used)),
    #("transcript", json.array(state.transcript, model.encode_message)),
    #("approvals_issued", json.int(state.approvals_issued)),
    #("phase", encode_phase(state.phase)),
  ])
  |> json.to_string
}

pub fn decode(record: String) -> Result(State, String) {
  let decoder = {
    use run <- decode.field("run", decode.string)
    use max_turns <- decode.field("max_turns", decode.int)
    use turns_used <- decode.field("turns_used", decode.int)
    use transcript <- decode.field(
      "transcript",
      decode.list(model.message_decoder()),
    )
    use approvals_issued <- decode.field("approvals_issued", decode.int)
    use phase <- decode.field("phase", phase_decoder())
    decode.success(State(
      run,
      max_turns,
      turns_used,
      transcript,
      approvals_issued,
      phase,
    ))
  }
  json.parse(record, decoder) |> result.replace_error("corrupt run record")
}

fn encode_id(id: ActionId) -> Json {
  json.object([#("turn", json.int(id.turn)), #("call", json.string(id.call_id))])
}

fn id_decoder() -> Decoder(ActionId) {
  use turn <- decode.field("turn", decode.int)
  use call <- decode.field("call", decode.string)
  decode.success(ActionId(turn, call))
}

fn tagged(tag: String, fields: List(#(String, Json))) -> Json {
  json.object([#("tag", json.string(tag)), ..fields])
}

fn encode_phase(phase: Phase) -> Json {
  case phase {
    AwaitingModel(turn) -> tagged("awaiting_model", [#("turn", json.int(turn))])
    Acting(actions) ->
      tagged("acting", [#("actions", json.array(actions, encode_action))])
    Cancelling(actions) ->
      tagged("cancelling", [#("actions", json.array(actions, encode_action))])
    Ended(Answer(text)) -> tagged("answer", [#("text", json.string(text))])
    Ended(Cancelled(ids)) ->
      tagged("cancelled", [#("unknown", json.array(ids, encode_id))])
    Ended(BudgetExhausted) -> tagged("budget_exhausted", [])
    Ended(HostFailed(reason)) ->
      tagged("host_failed", [#("reason", json.string(reason))])
  }
}

fn phase_decoder() -> Decoder(Phase) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "awaiting_model" ->
      decode.field("turn", decode.int, fn(t) {
        decode.success(AwaitingModel(t))
      })
    "acting" ->
      decode.field("actions", decode.list(action_decoder()), fn(a) {
        decode.success(Acting(a))
      })
    "cancelling" ->
      decode.field("actions", decode.list(action_decoder()), fn(a) {
        decode.success(Cancelling(a))
      })
    "answer" ->
      decode.field("text", decode.string, fn(t) {
        decode.success(Ended(Answer(t)))
      })
    "cancelled" ->
      decode.field("unknown", decode.list(id_decoder()), fn(ids) {
        decode.success(Ended(Cancelled(ids)))
      })
    "budget_exhausted" -> decode.success(Ended(BudgetExhausted))
    "host_failed" ->
      decode.field("reason", decode.string, fn(r) {
        decode.success(Ended(HostFailed(r)))
      })
    _ -> decode.failure(Ended(BudgetExhausted), "Phase")
  }
}

fn encode_action(action: Action) -> Json {
  json.object([
    #("id", encode_id(action.id)),
    #("call", model.encode_call(action.call)),
    #("status", encode_status(action.status)),
  ])
}

fn action_decoder() -> Decoder(Action) {
  use id <- decode.field("id", id_decoder())
  use call <- decode.field("call", model.call_decoder())
  use status <- decode.field("status", status_decoder())
  decode.success(Action(id, call, status))
}

fn encode_status(status: Status) -> Json {
  case status {
    Queued -> tagged("queued", [])
    AwaitingApproval(revision) ->
      tagged("awaiting_approval", [#("revision", json.int(revision))])
    Running -> tagged("running", [])
    Answered(content, kind) ->
      tagged("answered", [
        #("content", json.string(content)),
        #("kind", json.string(kind_to_string(kind))),
      ])
    Unknown(evidence) ->
      tagged("unknown", [#("evidence", json.string(evidence))])
    NotStarted -> tagged("not_started", [])
  }
}

fn status_decoder() -> Decoder(Status) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "queued" -> decode.success(Queued)
    "awaiting_approval" ->
      decode.field("revision", decode.int, fn(r) {
        decode.success(AwaitingApproval(r))
      })
    "running" -> decode.success(Running)
    "answered" -> {
      use content <- decode.field("content", decode.string)
      use kind <- decode.field("kind", kind_decoder())
      decode.success(Answered(content, kind))
    }
    "unknown" ->
      decode.field("evidence", decode.string, fn(e) {
        decode.success(Unknown(e))
      })
    "not_started" -> decode.success(NotStarted)
    _ -> decode.failure(Queued, "Status")
  }
}

fn kind_to_string(kind: Kind) -> String {
  case kind {
    Succeeded -> "succeeded"
    Failed -> "failed"
    Denied -> "denied"
    Rejected -> "rejected"
    UnknownTool -> "unknown_tool"
    Reconciled -> "reconciled"
  }
}

fn kind_decoder() -> Decoder(Kind) {
  use text <- decode.then(decode.string)
  case text {
    "succeeded" -> decode.success(Succeeded)
    "failed" -> decode.success(Failed)
    "denied" -> decode.success(Denied)
    "rejected" -> decode.success(Rejected)
    "unknown_tool" -> decode.success(UnknownTool)
    "reconciled" -> decode.success(Reconciled)
    _ -> decode.failure(Succeeded, "Kind")
  }
}
