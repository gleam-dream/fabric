//// Application values and codecs. No credential or live handle is retained.

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
  let assert Ok(c) =
    codec.record2(
      codec.required("source_path", codec.string()),
      codec.required("instructions", codec.string()),
      Brief,
      fn(v) { v.source_path },
      fn(v) { v.instructions },
    )
  c
}

pub fn text_codec() -> codec.Codec(Text) {
  let assert Ok(c) =
    codec.record3(
      codec.required("source", codec.string()),
      codec.required("brief", codec.string()),
      codec.required("body", codec.string()),
      Text,
      fn(v) { v.source },
      fn(v) { v.brief },
      fn(v) { v.body },
    )
  c
}

pub fn draft_codec() -> codec.Codec(Draft) {
  // Build the composed codec inside the callbacks so copying an operation into
  // its task does not repeatedly copy nested combinator environments.
  codec.new(fn(v) { codec.encode(draft_fields(), v) }, fn(v) {
    codec.decode(draft_fields(), v)
  })
}

fn draft_fields() -> codec.Codec(Draft) {
  let assert Ok(generation) = codec.integer_between(0, 3)
  let assert Ok(c) =
    codec.record2(
      codec.required("text", text_codec()),
      codec.required("generation", generation),
      Draft,
      fn(v) { v.text },
      fn(v) { v.generation },
    )
  c
}

pub fn body_codec() -> codec.Codec(String) {
  codec.field(
    "body",
    codec.string()
      |> codec.describe(
        "The complete draft, using only facts in the supplied source.",
      ),
  )
}

pub fn decision_codec() -> codec.Codec(Decision) {
  let assert Ok(c) =
    codec.string_enum([
      #("approve", Approve),
      #("revise", Revise),
      #("reject", Reject),
    ])
  codec.field("decision", c)
}

pub fn decision_text(decision: Decision) -> String {
  case decision {
    Approve -> "approve"
    Revise -> "revise"
    Reject -> "reject"
  }
}

pub fn artifact_codec() -> codec.Codec(Artifact) {
  let assert Ok(c) =
    codec.record2(
      codec.required("path", codec.string()),
      codec.required("sha256", codec.string()),
      Artifact,
      fn(v) { v.path },
      fn(v) { v.sha256 },
    )
  c
}

pub fn state_codec() -> codec.Codec(State) {
  codec.new(fn(v) { codec.encode(state_fields(), v) }, fn(v) {
    codec.decode(state_fields(), v)
  })
}

fn state_fields() -> codec.Codec(State) {
  let assert Ok(stages) =
    codec.string_enum([
      #("generate", Generating),
      #("review", Reviewing),
      #("publish", Publishing),
    ])
  let assert Ok(c) =
    codec.tagged(
      "loading",
      brief_codec(),
      "working",
      codec.pair(stages, draft_codec()),
    )
  codec.imap(
    c,
    fn(v) {
      case v {
        codec.Left(b) -> Loading(b)
        codec.Right(#(s, d)) -> Working(s, d)
      }
    },
    fn(v) {
      case v {
        Loading(b) -> codec.Left(b)
        Working(s, d) -> codec.Right(#(s, d))
      }
    },
  )
}

pub fn outcome_codec() -> codec.Codec(Outcome) {
  let assert Ok(stopped) =
    codec.string_enum([
      #("rejected", Rejected),
      #("revision_limit", RevisionLimit),
    ])
  let assert Ok(c) =
    codec.tagged("published", artifact_codec(), "stopped", stopped)
  codec.try_imap(
    c,
    fn(v) {
      Ok(case v {
        codec.Left(a) -> Published(a)
        codec.Right(outcome) -> outcome
      })
    },
    fn(v) {
      case v {
        Published(a) -> Ok(codec.Left(a))
        Rejected | RevisionLimit -> Ok(codec.Right(v))
      }
    },
  )
}

pub fn prompt(draft: Draft) -> String {
  let assert Ok(encoded) = codec.encode_json(draft_fields(), draft)
  encoded
}
