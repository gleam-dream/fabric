import fabric/graph
import fabric/graph/operation
import fabric/run
import fabric/store
import fabric_writing
import fabric_writing/domain
import fabric_writing/file
import fabric_writing/provider
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit
import gleeunit/should
import json/blueprint/codec
import llm_wire/testing
import llm_wire/types

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn approval_survives_restart_without_repeating_generation_or_review_test() {
  let directory = temp_dir()
  let source = directory <> "/source.txt"
  let assert Ok(Nil) =
    write_file(source, "The library opens on 12 May. Admission is free.")
  let script =
    testing.start([
      testing.text(
        "{\"body\":\"The library opens on 12 May, with free admission.\"}",
      ),
      testing.text("{\"decision\":\"approve\"}"),
    ])
  let assert Ok(model) = types.model_id("scripted-writer")
  let generator = provider.generator(testing.config(script), model)
  let reviewer = provider.llm_reviewer(testing.config(script), model)
  let publisher = file.publisher(directory <> "/published")
  let runs = store.directory(process.new_name("writing"), directory <> "/runs")
  let owner = start_store(runs)
  let runtime = fabric_writing.runtime(runs, generator, reviewer, publisher)
  let assert Ok(handle) =
    fabric_writing.start(
      runtime,
      "article",
      source,
      "Mention the opening date and price.",
    )
  let assert Ok(before) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(first) = before.status
  file.read(directory <> "/published/article-4.md") |> should.be_error
  stop_store(owner, runs)
  let owner = start_store(runs)
  let handle =
    graph.attach(
      fabric_writing.runtime(runs, generator, reviewer, publisher),
      graph.id(handle),
    )
  let assert Ok(after) = graph.read(handle)
  after.value |> should.equal(before.value)
  after.receipts |> should.equal(before.receipts)
  after.status |> should.equal(before.status)
  let assert Ok(_) = graph.approve(handle, first)
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(domain.Published(artifact)) = done.status
  file.read(artifact.path)
  |> should.equal(Ok("The library opens on 12 May, with free admission.\n"))
  testing.requests(script) |> list.length |> should.equal(2)
  graph.approve(handle, first) |> should.be_error
  stop_store(owner, runs)
  remove_dir(directory)
}

fn start_store(runs: store.Store) -> process.Pid {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) = store.start(runs)
      process.send(ready, Nil)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  owner
}

fn stop_store(owner: process.Pid, runs: store.Store) -> Nil {
  let assert Ok(pid) = store.pid(runs)
  let down = process.monitor(pid)
  process.kill(owner)
  process.new_selector()
  |> process.select_specific_monitor(down, fn(_) { Nil })
  |> process.selector_receive_forever
}

@external(erlang, "fabric_writing_test_ffi", "temp_dir")
fn temp_dir() -> String

@external(erlang, "fabric_writing_test_ffi", "write_file")
fn write_file(path: String, text: String) -> Result(Nil, Nil)

@external(erlang, "fabric_writing_test_ffi", "remove_dir")
fn remove_dir(path: String) -> Nil

type Fixture {
  Fixture(
    directory: String,
    owner: process.Pid,
    runs: store.Store,
    handle: graph.Handle(Nil, domain.State, domain.Outcome),
    script: testing.Script,
  )
}

fn draft(body: String) -> testing.Reply {
  let assert Ok(raw) = codec.encode_json(domain.body_codec(), body)
  testing.text(raw)
}

fn review(decision: domain.Decision) -> testing.Reply {
  let assert Ok(raw) = codec.encode_json(domain.decision_codec(), decision)
  testing.text(raw)
}

fn fixture(
  replies: List(testing.Reply),
  publish: fn(String) -> operation.Operation(Nil, domain.Draft, domain.Artifact),
) -> Fixture {
  let directory = temp_dir()
  let source = directory <> "/source.txt"
  let assert Ok(Nil) =
    write_file(source, "The library opens on 12 May. Admission is free.")
  let script = testing.start(replies)
  let assert Ok(model) = types.model_id("scripted-writer")
  let runs =
    store.directory(process.new_name("writing-case"), directory <> "/runs")
  let owner = start_store(runs)
  let runtime =
    fabric_writing.runtime(
      runs,
      provider.generator(testing.config(script), model),
      provider.llm_reviewer(testing.config(script), model),
      publish(directory <> "/published"),
    )
  let assert Ok(handle) =
    fabric_writing.start(
      runtime,
      "article",
      source,
      "Mention the date and price.",
    )
  Fixture(directory, owner, runs, handle, script)
}

fn close(fixture: Fixture) -> Nil {
  stop_store(fixture.owner, fixture.runs)
  remove_dir(fixture.directory)
}

pub fn revision_has_a_saved_counter_and_stops_after_three_drafts_test() {
  let f =
    fixture(
      [
        draft("one"),
        review(domain.Revise),
        draft("two"),
        review(domain.Revise),
        draft("three"),
        review(domain.Revise),
      ],
      file.publisher,
    )
  let assert Ok(done) = graph.await(f.handle, 5000)
  done.status |> should.equal(graph.Completed(domain.RevisionLimit))
  let assert domain.Working(domain.Reviewing, saved) = done.value
  saved.generation |> should.equal(3)
  saved.text.body |> should.equal("three")
  testing.requests(f.script) |> list.length |> should.equal(6)
  // No publish activation is admitted on the exhausted review route.
  done.receipts
  |> list.map(fn(receipt) { receipt.node })
  |> should.equal([
    "source",
    "generate",
    "review",
    "generate",
    "review",
    "generate",
    "review",
  ])
  close(f)
}

pub fn rejection_and_rejected_human_approval_never_publish_test() {
  let f = fixture([draft("draft"), review(domain.Reject)], file.publisher)
  let assert Ok(done) = graph.await(f.handle, 5000)
  done.status |> should.equal(graph.Completed(domain.Rejected))
  close(f)
  let f = fixture([draft("draft"), review(domain.Approve)], file.publisher)
  let assert Ok(waiting) = graph.await(f.handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert Ok(_) = graph.reject(f.handle, approval, "do not publish")
  let assert Ok(rejected) = graph.read(f.handle)
  let assert graph.Failed(_) = rejected.status
  file.read(f.directory <> "/published/article-4.md") |> should.be_error
  close(f)
}

pub fn invalid_refused_and_incomplete_review_responses_cannot_publish_test() {
  [
    testing.text("{\"decision\":\"anything\"}"),
    testing.refusal("declined"),
    testing.output_limited("{\"decision\":"),
  ]
  |> list.each(fn(response) {
    let f = fixture([draft("draft"), response], file.publisher)
    let assert Ok(done) = graph.await(f.handle, 5000)
    let assert graph.Blocked(_, _) = done.status
    file.read(f.directory <> "/published/article-4.md") |> should.be_error
    testing.requests(f.script) |> list.length |> should.equal(2)
    close(f)
  })
}

pub fn a_corrected_draft_is_reviewed_before_approval_test() {
  let f =
    fixture(
      [
        draft("wrong date"),
        review(domain.Revise),
        draft("12 May; free admission"),
        review(domain.Approve),
      ],
      file.publisher,
    )
  let assert Ok(waiting) = graph.await(f.handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert Ok(_) = graph.approve(f.handle, approval)
  let assert Ok(done) = graph.await(f.handle, 5000)
  let assert graph.Completed(domain.Published(artifact)) = done.status
  file.read(artifact.path) |> should.equal(Ok("12 May; free admission\n"))
  testing.requests(f.script) |> list.length |> should.equal(4)
  close(f)
}

pub fn absent_source_stops_before_a_provider_call_test() {
  let directory = temp_dir()
  let runs = store.in_memory(process.new_name("absent-source"))
  let owner = start_store(runs)
  let script = testing.start([])
  let assert Ok(model) = types.model_id("unused")
  let runtime =
    fabric_writing.runtime(
      runs,
      provider.generator(testing.config(script), model),
      provider.llm_reviewer(testing.config(script), model),
      file.publisher(directory),
    )
  let assert Ok(handle) =
    fabric_writing.start(runtime, "absent", directory <> "/missing", "write")
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Failed(_) = done.status
  testing.requests(script) |> should.equal([])
  stop_store(owner, runs)
  remove_dir(directory)
}

pub fn artifact_keys_acknowledge_identical_bytes_and_refuse_conflicting_bytes_test() {
  let directory = temp_dir()
  let assert Ok(first) = file.publish(directory, "stable-1", "first")
  file.publish(directory, "stable-1", "first") |> should.equal(Ok(first))
  file.publish(directory, "stable-1", "different") |> should.be_error
  file.publish(directory, "../elsewhere", "escape") |> should.be_error
  file.read(first.path) |> should.equal(Ok("first"))
  remove_dir(directory)
}

pub fn a_saved_file_with_a_lost_graph_result_is_recovered_without_duplicate_publication_test() {
  let saved = process.new_subject()
  let publisher = fn(directory) {
    let op =
      operation.new(
        run.Identity("artifact-publish", 1),
        domain.draft_codec(),
        domain.artifact_codec(),
        fn(_, invocation, draft) {
          let key =
            run.id_to_string(invocation.run)
            <> "-"
            <> int.to_string(invocation.activation)
          let assert Ok(receipt) =
            file.publish(directory, key, draft.text.body <> "\n")
          case invocation.attempt {
            1 -> {
              process.send(saved, receipt)
              let hold: process.Subject(Nil) = process.new_subject()
              process.receive_forever(hold)
            }
            _ -> Nil
          }
          Ok(receipt)
        },
        fn(_error: Nil) { operation.UncertainEffect("lost result") },
      )
    let assert Ok(op) = operation.with_replay(op, 2)
    op
  }
  let f = fixture([draft("approved draft"), review(domain.Approve)], publisher)
  let assert Ok(waiting) = graph.await(f.handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert Ok(_) = graph.approve(f.handle, approval)
  let assert Ok(receipt) = process.receive(saved, 1000)
  stop_store(f.owner, f.runs)
  let owner = start_store(f.runs)
  let assert Ok(_) = graph.recover(f.handle)
  let assert Ok(recovered) = graph.await(f.handle, 5000)
  let assert graph.AwaitingApproval(renewed) = recovered.status
  should.be_true(renewed != approval)
  graph.approve(f.handle, approval) |> should.be_error
  let assert Ok(_) = graph.approve(f.handle, renewed)
  let assert Ok(done) = graph.await(f.handle, 5000)
  let assert graph.Completed(domain.Published(after)) = done.status
  after |> should.equal(receipt)
  file.read(after.path) |> should.equal(Ok("approved draft\n"))
  testing.requests(f.script) |> list.length |> should.equal(2)
  close(Fixture(..f, owner:))
}
