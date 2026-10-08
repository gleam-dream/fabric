//// Two application-owned examples of history-aware invocation. The caller
//// owns retained messages, turn keys, authentication and result incorporation.
//// A provider is injected so the same examples run with deterministic fixtures.

import fabric/agent
import fabric/model
import fabric/policy
import fabric/tool
import gleam/erlang/process.{type Subject}
import json/blueprint/codec

pub type Editor {
  Editor(name: String, may_record: Bool, recorded: Subject(String))
}

pub type Revision {
  Revision(text: String)
}

pub type Label {
  Label(category: String)
}

pub fn revision_codec() -> codec.Codec(Revision) {
  use text <- codec.field("text", codec.string(), get: fn(r) { r.text })
  codec.success(Revision(text))
}

pub fn label_codec() -> codec.Codec(Label) {
  use category <- codec.field("category", codec.string(), get: fn(l) {
    l.category
  })
  codec.success(Label(category))
}

/// A document revision service with a native answer and a current permission
/// check. Imported `record_note` results are context, never authorization.
pub fn revision_agent(provider: model.Model) -> agent.Agent(Editor, Revision) {
  let definition =
    tool.define(
      "record_note",
      "Record an editorial note.",
      codec.string(),
      codec.string(),
    )
  let note =
    tool.bind(
      definition,
      fn(editor: Editor, _call, text) -> Result(String, Nil) {
        process.send(editor.recorded, editor.name <> ": " <> text)
        Ok(text)
      },
      fn(_) { tool.Explain("recording failed") },
    )
  let assert Ok(agent) =
    agent.new("document-revision", provider, [note], fn(editor: Editor, _) {
      Ok(case editor.may_record {
        True -> policy.Allow
        False -> policy.Deny("editor cannot record notes")
      })
    })
    |> agent.with_answer(revision_codec())
    |> agent.with_answer_attempts(2)
    |> agent.with_max_turns(5)
    |> agent.with_max_concurrency(1)
    |> agent.build
  agent
}

/// A separate classification application uses the same invocation input
/// with a different native answer and no tool authority.
pub fn label_agent(provider: model.Model) -> agent.Agent(Nil, Label) {
  let assert Ok(agent) =
    agent.new("text-label", provider, [], fn(_, _) { Ok(policy.Allow) })
    |> agent.with_answer(label_codec())
    |> agent.with_max_turns(3)
    |> agent.build
  agent
}
