//// Fork data inside the versioned graph record. Decoding is structural;
//// graph record validation restores each scope before accepting the record.

import fabric/graph/fork
import fabric/internal/run_id
import fabric/run
import gleam/dynamic/decode
import gleam/json

pub fn encode(saved: fork.Snapshot) -> json.Json {
  json.object([
    #("run", json.string(run.id_to_string(saved.occurrence.run))),
    #("activation", json.int(saved.occurrence.activation)),
    #("max_members", json.int(saved.max_members)),
    #("concurrency", json.int(saved.concurrency)),
    #(
      "stop",
      json.nullable(saved.stop, fn(cause) {
        case cause {
          fork.CancelledByCaller -> tagged("cancelled", [])
          fork.DeadlineElapsed(due) ->
            tagged("expired", [#("due", json.int(due))])
          fork.MemberFailed(ref) ->
            tagged("failed", [
              #("run", json.string(run.id_to_string(ref.occurrence.run))),
              #("activation", json.int(ref.occurrence.activation)),
              #("member", json.int(ref.member)),
            ])
        }
      }),
    ),
    #(
      "members",
      json.array(saved.members, fn(member) {
        json.object([
          #(
            "definition",
            json.object([
              #("name", json.string(member.request.definition.name)),
              #("version", json.int(member.request.definition.version)),
            ]),
          ),
          #("input", json.string(member.request.input)),
          #("status", case member.status {
            fork.Reserved -> tagged("reserved", [])
            fork.Pending -> tagged("pending", [])
            fork.Withdrawn -> tagged("withdrawn", [])
            fork.Rejected(reason) ->
              tagged("rejected", [#("reason", json.string(reason))])
            fork.Admitted(progress) ->
              tagged("admitted", [
                #("progress", case progress {
                  fork.Active -> tagged("active", [])
                  fork.Uncertain(reason) ->
                    tagged("uncertain", [#("reason", json.string(reason))])
                  fork.Succeeded(output) ->
                    tagged("succeeded", [#("output", json.string(output))])
                  fork.Failed(reason) ->
                    tagged("failed", [#("reason", json.string(reason))])
                  fork.Cancelled -> tagged("cancelled", [])
                }),
              ])
          }),
        ])
      }),
    ),
  ])
}

fn tagged(name: String, fields: List(#(String, json.Json))) -> json.Json {
  json.object([#("tag", json.string(name)), ..fields])
}

fn occurrence() -> decode.Decoder(fork.Occurrence) {
  use run <- decode.field("run", decode.string)
  use activation <- decode.field("activation", decode.int)
  decode.success(fork.Occurrence(run_id.from_string(run), activation))
}

fn cause() -> decode.Decoder(fork.Cause) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "cancelled" -> decode.success(fork.CancelledByCaller)
    "expired" -> {
      use due <- decode.field("due", decode.int)
      decode.success(fork.DeadlineElapsed(due))
    }
    "failed" -> {
      use occurrence <- decode.then(occurrence())
      use member <- decode.field("member", decode.int)
      decode.success(fork.MemberFailed(fork.Reference(occurrence, member)))
    }
    _ -> decode.failure(fork.CancelledByCaller, "fork stop cause")
  }
}

fn progress() -> decode.Decoder(fork.Progress) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "active" -> decode.success(fork.Active)
    "cancelled" -> decode.success(fork.Cancelled)
    "succeeded" -> {
      use output <- decode.field("output", decode.string)
      decode.success(fork.Succeeded(output))
    }
    "failed" | "uncertain" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(case tag {
        "failed" -> fork.Failed(reason)
        _ -> fork.Uncertain(reason)
      })
    }
    _ -> decode.failure(fork.Active, "fork member progress")
  }
}

fn status() -> decode.Decoder(fork.Status) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "reserved" -> decode.success(fork.Reserved)
    "pending" -> decode.success(fork.Pending)
    "withdrawn" -> decode.success(fork.Withdrawn)
    "rejected" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(fork.Rejected(reason))
    }
    "admitted" -> {
      use progress <- decode.field("progress", progress())
      decode.success(fork.Admitted(progress))
    }
    _ -> decode.failure(fork.Pending, "fork member status")
  }
}

pub fn decoder() -> decode.Decoder(fork.Snapshot) {
  use occurrence <- decode.then(occurrence())
  use maximum <- decode.field("max_members", decode.int)
  use concurrency <- decode.field("concurrency", decode.int)
  use stop <- decode.field("stop", decode.optional(cause()))
  use members <- decode.field(
    "members",
    decode.list({
      use identity <- decode.field("definition", {
        use name <- decode.field("name", decode.string)
        use version <- decode.field("version", decode.int)
        decode.success(run.DefinitionId(name, version))
      })
      use input <- decode.field("input", decode.string)
      use status <- decode.field("status", status())
      decode.success(fork.Member(fork.Request(identity, input), status))
    }),
  )
  decode.success(fork.Snapshot(occurrence, maximum, concurrency, members, stop))
}
