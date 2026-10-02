//// Application values and codecs. No credential or live handle is retained.

import gleam/option.{None}
import json/blueprint/codec

pub type Brief {
  Brief(source_path: String, instructions: String)
}

pub type Text {
  Text(source: String, brief: String, body: String)
}

pub type Draft {
  Draft(text: Text, generation: Int)
}

pub type Stage {
  Generating
  Reviewing
  Publishing
}

pub type State {
  Loading(Brief)
  Working(Stage, Draft)
}

pub type Decision {
  Approve
  Revise
  Reject
}

pub type Artifact {
  Artifact(path: String, sha256: String)
}

pub type Outcome {
  Published(Artifact)
  Rejected
  RevisionLimit
}

pub fn brief_codec() -> codec.Codec(Brief) {
  use source_path <- codec.field("source_path", codec.string(), fn(v: Brief) {
    v.source_path
  })
  use instructions <- codec.field("instructions", codec.string(), fn(v: Brief) {
    v.instructions
  })
  codec.success(Brief(source_path:, instructions:))
}

pub fn text_codec() -> codec.Codec(Text) {
  use source <- codec.field("source", codec.string(), fn(v: Text) { v.source })
  use brief <- codec.field("brief", codec.string(), fn(v: Text) { v.brief })
  use body <- codec.field("body", codec.string(), fn(v: Text) { v.body })
  codec.success(Text(source:, brief:, body:))
}

pub fn draft_codec() -> codec.Codec(Draft) {
  // Build the composed codec inside the callbacks so copying an operation into
  // its task does not repeatedly copy nested combinator environments.
  codec.custom(
    encode: fn(v) { codec.encode(draft_fields(), v) },
    decode: fn(v) { codec.decode(draft_fields(), v) },
    schema: None,
    placeholder: Draft(Text("", "", ""), 0),
  )
}

fn draft_fields() -> codec.Codec(Draft) {
  use text <- codec.field("text", text_codec(), fn(v: Draft) { v.text })
  use generation <- codec.field(
    "generation",
    codec.integer_between(0, 3),
    fn(v: Draft) { v.generation },
  )
  codec.success(Draft(text:, generation:))
}

pub fn body_codec() -> codec.Codec(String) {
  let body =
    codec.string()
    |> codec.describe(
      "The complete draft, using only facts in the supplied source.",
    )
  use body <- codec.field("body", body, fn(body) { body })
  codec.success(body)
}

pub fn decision_codec() -> codec.Codec(Decision) {
  let decision =
    codec.string_enum([
      #("approve", Approve),
      #("revise", Revise),
      #("reject", Reject),
    ])
  use decision <- codec.field("decision", decision, fn(decision) { decision })
  codec.success(decision)
}

pub fn decision_text(decision: Decision) -> String {
  case decision {
    Approve -> "approve"
    Revise -> "revise"
    Reject -> "reject"
  }
}

pub fn artifact_codec() -> codec.Codec(Artifact) {
  use path <- codec.field("path", codec.string(), fn(v: Artifact) { v.path })
  use sha256 <- codec.field("sha256", codec.string(), fn(v: Artifact) {
    v.sha256
  })
  codec.success(Artifact(path:, sha256:))
}

pub fn state_codec() -> codec.Codec(State) {
  codec.custom(
    encode: fn(v) { codec.encode(state_fields(), v) },
    decode: fn(v) { codec.decode(state_fields(), v) },
    schema: None,
    placeholder: Loading(Brief("", "")),
  )
}

fn state_fields() -> codec.Codec(State) {
  let stages =
    codec.string_enum([
      #("generate", Generating),
      #("review", Reviewing),
      #("publish", Publishing),
    ])
  codec.union({
    use loading <- codec.variant("loading", brief_codec(), Loading)
    use working <- codec.variant(
      "working",
      codec.pair(stages, draft_codec()),
      fn(pair) { Working(pair.0, pair.1) },
    )
    codec.match(fn(state) {
      case state {
        Loading(brief) -> loading(brief)
        Working(stage, draft) -> working(#(stage, draft))
      }
    })
  })
}

pub fn outcome_codec() -> codec.Codec(Outcome) {
  let stopped =
    codec.string_enum([
      #("rejected", Rejected),
      #("revision_limit", RevisionLimit),
    ])
  codec.union({
    use published <- codec.variant("published", artifact_codec(), Published)
    use stopped <- codec.variant("stopped", stopped, fn(outcome) { outcome })
    codec.match(fn(outcome) {
      case outcome {
        Published(artifact) -> published(artifact)
        Rejected | RevisionLimit -> stopped(outcome)
      }
    })
  })
}

pub fn prompt(draft: Draft) -> String {
  let assert Ok(encoded) = codec.encode_json(draft_fields(), draft)
  encoded
}
