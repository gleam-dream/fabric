//// Versioned graph records contain data only. Structural validation runs on
//// both writes and reads; binding to deployed native codecs and the exact
//// definition is an additional check before recovery may perform effects.
//// Encode once per write and reuse those bytes for acknowledgement recovery.

import fabric/graph/child
import fabric/graph/operation
import fabric/internal/graph/controller as g
import fabric/run
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const format = "fabric.graph"

pub const version = 3

pub type EncodeError {
  InvalidState(detail: String)
}

pub type DecodeError {
  UnsupportedVersion(found: Int)
  Corrupt(detail: String)
}

pub fn encode(state: g.State) -> Result(String, EncodeError) {
  use _ <- result.try(validate(state) |> result.map_error(InvalidState))
  Ok(
    json.object([
      #("format", json.string(format)),
      #("version", json.int(version)),
      #("write", json.string(write_token())),
      #("run", json.string(state.run)),
      #(
        "definition",
        json.object([
          #("identity", identity_json(state.definition.identity)),
          #("signature", json.string(state.definition.signature)),
          #("max_activations", json.int(state.definition.max_activations)),
        ]),
      ),
      #("incarnation", json.int(state.incarnation)),
      #("allocated", json.int(state.allocated)),
      #("approvals_issued", json.int(state.approvals_issued)),
      #("value", json.string(state.value)),
      #("initial", json.string(state.initial)),
      #(
        "parent",
        json.nullable(state.parent, fn(parent) {
          json.object([
            #("run", json.string(parent.run)),
            #("activation", json.int(parent.activation)),
          ])
        }),
      ),
      #(
        "receipts",
        json.array(state.receipts, fn(receipt) {
          json.object([
            #("activation", activation_json(receipt.activation)),
            #("output", json.string(receipt.output)),
            #("state", json.string(receipt.state)),
            #("route", route_json(receipt.route)),
          ])
        }),
      ),
      #("phase", phase_json(state.phase)),
    ])
    |> json.to_string,
  )
}

@external(erlang, "fabric_ffi", "random_id")
fn write_token() -> String

fn tag(name: String, fields: List(#(String, Json))) -> Json {
  json.object([#("tag", json.string(name)), ..fields])
}

fn identity_json(identity: run.Identity) -> Json {
  json.object([
    #("name", json.string(identity.name)),
    #("version", json.int(identity.version)),
  ])
}

fn prepared_json(prepared: g.Prepared) -> Json {
  json.object([
    #("node", json.string(prepared.node)),
    #("operation", identity_json(prepared.operation)),
    #("input", json.string(prepared.input)),
    #(
      "kind",
      json.string(case prepared.kind {
        operation.Activity -> "activity"
        operation.Signal -> "signal"
        operation.Subgraph -> "subgraph"
      }),
    ),
    #("recovery", case prepared.recovery {
      operation.RequireReconciliation -> tag("reconcile", [])
      operation.ReplayInterrupted(max) ->
        tag("replay", [#("max_attempts", json.int(max))])
    }),
  ])
}

fn activation_json(activation: g.Activation) -> Json {
  json.object([
    #("id", json.int(activation.id)),
    #("attempt", json.int(activation.attempt)),
    #("prepared", prepared_json(activation.prepared)),
  ])
}

fn approval_json(approval: g.Approval) -> Json {
  json.object([
    #("activation", json.int(approval.activation)),
    #("attempt", json.int(approval.attempt)),
    #("revision", json.int(approval.revision)),
    #(
      "requirement",
      json.object([
        #("name", json.string(approval.requirement.name)),
        #("version", json.int(approval.requirement.version)),
      ]),
    ),
  ])
}

fn route_json(route: g.Route) -> Json {
  case route {
    g.Next(node) -> tag("next", [#("node", json.string(node))])
    g.Finished -> tag("finished", [])
    g.Canceled -> tag("canceled", [])
  }
}

fn problem_json(problem: g.Problem) -> Json {
  case problem {
    g.Uncertain(evidence) ->
      tag("uncertain", [#("evidence", json.string(evidence))])
    g.InvalidResult(output, reason) ->
      tag("invalid_result", [
        #("output", json.string(output)),
        #("reason", json.string(reason)),
      ])
  }
}

fn fault_json(fault: g.Fault) -> Json {
  let #(name, reason) = case fault {
    g.Denied(reason) -> #("denied", reason)
    g.PolicyFailed(reason) -> #("policy_failed", reason)
    g.OperationFailed(reason) -> #("operation_failed", reason)
  }
  tag(name, [#("reason", json.string(reason))])
}

fn cancellation_json(cancellation: g.Cancellation) -> Json {
  case cancellation {
    g.BeforeStart -> tag("before_start", [])
    g.AfterResult -> tag("after_result", [])
    g.AfterFailure(fault) ->
      tag("after_failure", [#("fault", fault_json(fault))])
    g.AfterChild(id) -> tag("after_child", [#("child", json.string(id))])
    g.UnresolvedCancellation(problem) ->
      tag("unresolved", [#("problem", problem_json(problem))])
  }
}

fn outcome_json(outcome: g.Outcome) -> Json {
  case outcome {
    g.Completed(answer) -> tag("completed", [#("answer", json.string(answer))])
    g.Failed(activation, fault) ->
      tag("failed", [
        #("activation", activation_json(activation)),
        #("fault", fault_json(fault)),
      ])
    g.Exhausted(next) -> tag("exhausted", [#("next", prepared_json(next))])
    g.Cancelled(activation, disposition) ->
      tag("cancelled", [
        #("activation", activation_json(activation)),
        #("disposition", cancellation_json(disposition)),
      ])
  }
}

fn phase_json(phase: g.Phase) -> Json {
  case phase {
    g.ChildBlocked(a, id, reason) ->
      tag("child_blocked", [
        #("activation", activation_json(a)),
        #("child", json.string(id)),
        #("reason", json.string(reason)),
      ])
    g.Joining(a, id) ->
      tag("joining", [
        #("activation", activation_json(a)),
        #("child", json.string(id)),
      ])
    g.StoppingChild(a, id) ->
      tag("stopping_child", [
        #("activation", activation_json(a)),
        #("child", json.string(id)),
      ])
    g.Ready(a) -> tag("ready", [#("activation", activation_json(a))])
    g.Queued(a) -> tag("queued", [#("activation", activation_json(a))])
    g.Running(a) -> tag("running", [#("activation", activation_json(a))])
    g.Stopping(a) -> tag("stopping", [#("activation", activation_json(a))])
    g.WaitingSignal(a) ->
      tag("waiting_signal", [#("activation", activation_json(a))])
    g.AwaitingApproval(a, approval) ->
      tag("awaiting_approval", [
        #("activation", activation_json(a)),
        #("approval", approval_json(approval)),
      ])
    g.Blocked(a, problem) ->
      tag("blocked", [
        #("activation", activation_json(a)),
        #("problem", problem_json(problem)),
      ])
    g.Ended(outcome) -> tag("ended", [#("outcome", outcome_json(outcome))])
  }
}

pub fn decode(text: String) -> Result(g.State, DecodeError) {
  let header = {
    use found_format <- decode.field("format", decode.string)
    use found_version <- decode.field("version", decode.int)
    decode.success(#(found_format, found_version))
  }
  case json.parse(text, header) {
    Error(error) -> Error(Corrupt(string.inspect(error)))
    Ok(#(found, _)) if found != format ->
      Error(Corrupt("not a Fabric graph record: " <> found))
    Ok(#(_, found)) if found != version -> Error(UnsupportedVersion(found))
    Ok(_) -> {
      use state <- result.try(
        json.parse(text, state_decoder())
        |> result.map_error(fn(error) { Corrupt(string.inspect(error)) }),
      )
      use _ <- result.try(validate(state) |> result.map_error(Corrupt))
      Ok(state)
    }
  }
}

fn tagged(
  zero: a,
  select: fn(String) -> Result(Decoder(a), Nil),
) -> Decoder(a) {
  use name <- decode.field("tag", decode.string)
  case select(name) {
    Ok(decoder) -> decoder
    Error(Nil) -> decode.failure(zero, "a known graph record tag, not " <> name)
  }
}

fn identity_decoder() -> Decoder(run.Identity) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.int)
  decode.success(run.Identity(name, version))
}

fn prepared_decoder() -> Decoder(g.Prepared) {
  use node <- decode.field("node", decode.string)
  use operation <- decode.field("operation", identity_decoder())
  use input <- decode.field("input", decode.string)
  use kind <- decode.field("kind", {
    use name <- decode.then(decode.string)
    case name {
      "activity" -> decode.success(operation.Activity)
      "signal" -> decode.success(operation.Signal)
      "subgraph" -> decode.success(operation.Subgraph)
      _ -> decode.failure(operation.Activity, "a known operation kind")
    }
  })
  use recovery <- decode.field("recovery", {
    use name <- tagged(operation.RequireReconciliation)
    case name {
      "reconcile" -> Ok(decode.success(operation.RequireReconciliation))
      "replay" ->
        Ok({
          use max <- decode.field("max_attempts", decode.int)
          decode.success(operation.ReplayInterrupted(max))
        })
      _ -> Error(Nil)
    }
  })
  decode.success(g.Prepared(node, operation, input, recovery, kind))
}

fn activation_decoder() -> Decoder(g.Activation) {
  use id <- decode.field("id", decode.int)
  use attempt <- decode.field("attempt", decode.int)
  use prepared <- decode.field("prepared", prepared_decoder())
  decode.success(g.Activation(id, attempt, prepared))
}

fn approval_decoder() -> Decoder(g.Approval) {
  use activation <- decode.field("activation", decode.int)
  use attempt <- decode.field("attempt", decode.int)
  use revision <- decode.field("revision", decode.int)
  use requirement <- decode.field("requirement", {
    use name <- decode.field("name", decode.string)
    use version <- decode.field("version", decode.int)
    decode.success(run.Requirement(name, version))
  })
  decode.success(g.Approval(activation, attempt, revision, requirement))
}

fn route_decoder() -> Decoder(g.Route) {
  use name <- tagged(g.Finished)
  case name {
    "next" ->
      Ok({
        use node <- decode.field("node", decode.string)
        decode.success(g.Next(node))
      })
    "finished" -> Ok(decode.success(g.Finished))
    "canceled" -> Ok(decode.success(g.Canceled))
    _ -> Error(Nil)
  }
}

fn problem_decoder() -> Decoder(g.Problem) {
  use name <- tagged(g.Uncertain(""))
  case name {
    "uncertain" ->
      Ok({
        use evidence <- decode.field("evidence", decode.string)
        decode.success(g.Uncertain(evidence))
      })
    "invalid_result" ->
      Ok({
        use output <- decode.field("output", decode.string)
        use reason <- decode.field("reason", decode.string)
        decode.success(g.InvalidResult(output, reason))
      })
    _ -> Error(Nil)
  }
}

fn fault_decoder() -> Decoder(g.Fault) {
  use name <- tagged(g.OperationFailed(""))
  let constructor = case name {
    "denied" -> Ok(g.Denied)
    "policy_failed" -> Ok(g.PolicyFailed)
    "operation_failed" -> Ok(g.OperationFailed)
    _ -> Error(Nil)
  }
  use constructor <- result.try(constructor)
  Ok({
    use reason <- decode.field("reason", decode.string)
    decode.success(constructor(reason))
  })
}

fn cancellation_decoder() -> Decoder(g.Cancellation) {
  use name <- tagged(g.BeforeStart)
  case name {
    "before_start" -> Ok(decode.success(g.BeforeStart))
    "after_child" ->
      Ok({
        use id <- decode.field("child", decode.string)
        decode.success(g.AfterChild(id))
      })
    "after_result" -> Ok(decode.success(g.AfterResult))
    "after_failure" ->
      Ok({
        use fault <- decode.field("fault", fault_decoder())
        decode.success(g.AfterFailure(fault))
      })
    "unresolved" ->
      Ok({
        use problem <- decode.field("problem", problem_decoder())
        decode.success(g.UnresolvedCancellation(problem))
      })
    _ -> Error(Nil)
  }
}

fn outcome_decoder() -> Decoder(g.Outcome) {
  use name <- tagged(g.Completed(""))
  case name {
    "completed" ->
      Ok({
        use answer <- decode.field("answer", decode.string)
        decode.success(g.Completed(answer))
      })
    "failed" ->
      Ok({
        use activation <- decode.field("activation", activation_decoder())
        use fault <- decode.field("fault", fault_decoder())
        decode.success(g.Failed(activation, fault))
      })
    "exhausted" ->
      Ok({
        use next <- decode.field("next", prepared_decoder())
        decode.success(g.Exhausted(next))
      })
    "cancelled" ->
      Ok({
        use activation <- decode.field("activation", activation_decoder())
        use disposition <- decode.field("disposition", cancellation_decoder())
        decode.success(g.Cancelled(activation, disposition))
      })
    _ -> Error(Nil)
  }
}

fn phase_decoder() -> Decoder(g.Phase) {
  use name <- tagged(g.Ended(g.Completed("")))
  case name {
    "child_blocked" ->
      Ok({
        use a <- decode.field("activation", activation_decoder())
        use id <- decode.field("child", decode.string)
        use reason <- decode.field("reason", decode.string)
        decode.success(g.ChildBlocked(a, id, reason))
      })
    "joining" | "stopping_child" ->
      Ok({
        use a <- decode.field("activation", activation_decoder())
        use id <- decode.field("child", decode.string)
        decode.success(case name {
          "joining" -> g.Joining(a, id)
          _ -> g.StoppingChild(a, id)
        })
      })
    "waiting_signal" ->
      Ok({
        use activation <- decode.field("activation", activation_decoder())
        decode.success(g.WaitingSignal(activation))
      })
    "ready" | "queued" | "running" | "stopping" ->
      Ok({
        use activation <- decode.field("activation", activation_decoder())
        decode.success(case name {
          "ready" -> g.Ready(activation)
          "queued" -> g.Queued(activation)
          "running" -> g.Running(activation)
          _ -> g.Stopping(activation)
        })
      })
    "awaiting_approval" ->
      Ok({
        use activation <- decode.field("activation", activation_decoder())
        use approval <- decode.field("approval", approval_decoder())
        decode.success(g.AwaitingApproval(activation, approval))
      })
    "blocked" ->
      Ok({
        use activation <- decode.field("activation", activation_decoder())
        use problem <- decode.field("problem", problem_decoder())
        decode.success(g.Blocked(activation, problem))
      })
    "ended" ->
      Ok({
        use outcome <- decode.field("outcome", outcome_decoder())
        decode.success(g.Ended(outcome))
      })
    _ -> Error(Nil)
  }
}

fn state_decoder() -> Decoder(g.State) {
  use run <- decode.field("run", decode.string)
  use definition <- decode.field("definition", {
    use identity <- decode.field("identity", identity_decoder())
    use signature <- decode.field("signature", decode.string)
    use max <- decode.field("max_activations", decode.int)
    decode.success(g.Definition(identity, signature, max))
  })
  use incarnation <- decode.field("incarnation", decode.int)
  use allocated <- decode.field("allocated", decode.int)
  use approvals <- decode.field("approvals_issued", decode.int)
  use value <- decode.field("value", decode.string)
  use initial <- decode.field("initial", decode.string)
  use parent <- decode.field(
    "parent",
    decode.optional({
      use run <- decode.field("run", decode.string)
      use activation <- decode.field("activation", decode.int)
      decode.success(child.Parent(run, activation))
    }),
  )
  use receipts <- decode.field(
    "receipts",
    decode.list({
      use activation <- decode.field("activation", activation_decoder())
      use output <- decode.field("output", decode.string)
      use state <- decode.field("state", decode.string)
      use route <- decode.field("route", route_decoder())
      decode.success(g.Receipt(activation, output, state, route))
    }),
  )
  use phase <- decode.field("phase", phase_decoder())
  decode.success(g.State(
    run,
    definition,
    incarnation,
    allocated,
    approvals,
    value,
    receipts,
    phase,
    initial,
    parent,
  ))
}

fn require(condition: Bool, detail: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(detail)
  }
}

fn json_value(text: String) -> Result(Nil, String) {
  json.parse(text, decode.dynamic)
  |> result.replace(Nil)
  |> result.replace_error("an accepted application value is not JSON")
}

fn check_prepared(prepared: g.Prepared) -> Result(Nil, String) {
  use _ <- result.try(
    g.check_prepared(prepared)
    |> result.replace_error("invalid prepared operation"),
  )
  json_value(prepared.input)
}

fn check_activation(activation: g.Activation) -> Result(Nil, String) {
  use _ <- result.try(check_prepared(activation.prepared))
  let max = case activation.prepared.recovery {
    operation.RequireReconciliation -> 1
    operation.ReplayInterrupted(max) -> max
  }
  require(
    activation.id >= 1 && activation.attempt >= 1 && activation.attempt <= max,
    "invalid activation identity or attempt",
  )
}

/// Validate cross-field invariants before trusting a persisted control state.
@internal
pub fn validate(state: g.State) -> Result(Nil, String) {
  use _ <- result.try(
    run.parse_id(state.run) |> result.replace_error("invalid run identity"),
  )
  use _ <- result.try(
    g.check_definition(state.definition)
    |> result.replace_error("invalid graph definition"),
  )
  use _ <- result.try(require(
    state.incarnation >= 1
      && state.allocated >= 1
      && state.allocated <= state.definition.max_activations
      && state.approvals_issued >= 0,
    "invalid owner, activation or approval counters",
  ))
  use _ <- result.try(json_value(state.value))
  use _ <- result.try(json_value(state.initial))
  use _ <- result.try(case state.parent {
    None -> Ok(Nil)
    Some(parent) -> {
      use _ <- result.try(
        run.parse_id(parent.run) |> result.replace_error("invalid parent run"),
      )
      require(
        parent.activation > 0
          && state.run == child.reserved_id(parent.run, parent.activation),
        "child record does not match its parent reservation",
      )
    }
  })
  use last <- result.try(check_receipts(state.receipts, 1, None))
  use _ <- result.try(case last {
    None -> Ok(Nil)
    Some(receipt) ->
      require(
        receipt.state == state.value,
        "application state differs from its last accepted receipt",
      )
  })
  let count = list.length(state.receipts)
  case state.phase {
    g.Blocked(a, g.InvalidResult(_, _))
      if a.prepared.kind == operation.Subgraph
    -> pending(state, count, last, a)
    g.Joining(a, id) | g.StoppingChild(a, id) | g.ChildBlocked(a, id, _) -> {
      use _ <- result.try(require(
        a.prepared.kind == operation.Subgraph
          && id == child.reserved_id(state.run, a.id),
        "invalid child reservation",
      ))
      pending(state, count, last, a)
    }
    g.Ready(a) -> pending(state, count, last, a)
    g.Queued(a) | g.Running(a) | g.Stopping(a) | g.Blocked(a, _) -> {
      use _ <- result.try(require(
        a.prepared.kind == operation.Activity,
        "a signal wait cannot enter an activity phase",
      ))
      pending(state, count, last, a)
    }
    g.WaitingSignal(a) -> {
      use _ <- result.try(require(
        a.prepared.kind == operation.Signal,
        "an activity cannot wait for a signal",
      ))
      pending(state, count, last, a)
    }
    g.AwaitingApproval(a, approval) -> {
      use _ <- result.try(pending(state, count, last, a))
      require(
        approval.activation == a.id
          && approval.attempt == a.attempt
          && approval.revision == state.approvals_issued
          && approval.revision >= 1
          && string.trim(approval.requirement.name) != ""
          && approval.requirement.version >= 1,
        "approval does not identify the current activation and requirement",
      )
    }
    g.Ended(g.Failed(a, _)) -> pending(state, count, last, a)
    g.Ended(g.Completed(answer)) -> {
      use _ <- result.try(finished(state, count, last, g.Finished))
      json_value(answer)
    }
    g.Ended(g.Exhausted(next)) -> {
      use _ <- result.try(check_prepared(next))
      use _ <- result.try(require(
        state.allocated == state.definition.max_activations,
        "activation limit was not exhausted",
      ))
      finished(state, count, last, g.Next(next.node))
    }
    g.Ended(g.Cancelled(a, g.AfterResult)) -> {
      use _ <- result.try(require(
        a.prepared.kind == operation.Activity,
        "a canceled signal cannot have a result",
      ))
      use _ <- result.try(check_activation(a))
      use _ <- result.try(finished(state, count, last, g.Canceled))
      case last {
        Some(receipt) ->
          require(
            receipt.activation == a,
            "cancelled result belongs to a different activation",
          )
        None -> Error("cancelled result has no receipt")
      }
    }
    g.Ended(g.Cancelled(a, disposition)) -> {
      use _ <- result.try(case disposition {
        g.AfterChild(id) ->
          require(
            a.prepared.kind == operation.Subgraph
              && id == child.reserved_id(state.run, a.id),
            "cancellation does not identify its child",
          )
        _ -> Ok(Nil)
      })
      use _ <- result.try(require(
        a.prepared.kind != operation.Signal || disposition == g.BeforeStart,
        "a canceled signal cannot have an activity disposition",
      ))
      pending(state, count, last, a)
    }
  }
}

fn check_receipts(
  receipts: List(g.Receipt),
  ordinal: Int,
  previous: Option(g.Receipt),
) -> Result(Option(g.Receipt), String) {
  case receipts {
    [] -> Ok(previous)
    [receipt, ..rest] -> {
      use _ <- result.try(check_activation(receipt.activation))
      use _ <- result.try(require(
        receipt.activation.id == ordinal,
        "receipt ordinals are not contiguous",
      ))
      use _ <- result.try(follows(previous, receipt.activation.prepared.node))
      use _ <- result.try(case previous, receipt.route {
        Some(previous), g.Canceled ->
          require(
            receipt.state == previous.state,
            "cancelled result changed application state",
          )
        _, _ -> Ok(Nil)
      })
      use _ <- result.try(json_value(receipt.output))
      use _ <- result.try(json_value(receipt.state))
      check_receipts(rest, ordinal + 1, Some(receipt))
    }
  }
}

fn follows(previous: Option(g.Receipt), node: String) -> Result(Nil, String) {
  case previous {
    None -> Ok(Nil)
    Some(g.Receipt(route: g.Next(next), ..)) ->
      require(
        next == node,
        "receipt route does not reach the following activation",
      )
    Some(_) -> Error("work follows a terminal receipt")
  }
}

fn pending(
  state: g.State,
  count: Int,
  last: Option(g.Receipt),
  activation: g.Activation,
) -> Result(Nil, String) {
  use _ <- result.try(check_activation(activation))
  use _ <- result.try(require(
    activation.id == state.allocated && count == state.allocated - 1,
    "pending activation disagrees with reserved work and receipt count",
  ))
  follows(last, activation.prepared.node)
}

fn finished(
  state: g.State,
  count: Int,
  last: Option(g.Receipt),
  route: g.Route,
) -> Result(Nil, String) {
  use _ <- result.try(require(
    count == state.allocated,
    "terminal outcome disagrees with receipt count",
  ))
  case last {
    Some(receipt) ->
      require(
        receipt.route == route,
        "terminal outcome disagrees with last route",
      )
    None -> Error("terminal outcome has no receipt")
  }
}
