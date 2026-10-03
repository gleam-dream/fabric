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
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire
import llm_wire/testing

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn approval_survives_restart_without_repeating_generation_or_review_test() {
  let directory = temp_dir()
  let source = directory <> "/source.txt"
  let assert Ok(Nil) =
    write_file(source, "The library opens on 12 May. Admission is free.")
  // Exactly one generation and one review: a repeated call after the
  // restart would find no matching exchange.
  let client =
    script("Mention the opening date and price.", [
      draft("The library opens on 12 May, with free admission."),
      review(domain.Approve),
    ])
  let generator = provider.generator(client, testing.config(), model())
  let reviewer = provider.llm_reviewer(client, testing.config(), model())
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
  graph.approve(handle, first) |> should.be_error
  stop_store(owner, runs)
  http_gun.stop(client)
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
    client: http_gun.Client,
  )
}

const source_text = "The library opens on 12 May. Admission is free."

fn model() -> String {
  "scripted-writer"
}

/// One provider request the graph is expected to make, with its reply.
type Turn {
  Generate(body: String)
  Review(reply: testing.Reply)
}

fn draft(body: String) -> Turn {
  Generate(body)
}

fn review(decision: domain.Decision) -> Turn {
  let assert Ok(raw) = codec.encode_json(domain.decision_codec(), decision)
  Review(testing.text(raw))
}

/// An offline HTTP Gun client that answers exactly these requests, in this
/// order, for `brief` over the source text. Any other or further request
/// fails without network access.
fn script(brief: String, turns: List(Turn)) -> http_gun.Client {
  let start = domain.Draft(domain.Text(source_text, brief, ""), 0)
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script(exchanges(start, turns, [])),
      http_config.default(),
    )
  client
}

/// Follows the graph's drafts: a generation sets the body and advances the
/// generation; a review, including a revision, keeps the reviewed draft.
fn exchanges(
  current: domain.Draft,
  turns: List(Turn),
  done: List(http_testing.Exchange),
) -> List(http_testing.Exchange) {
  case turns {
    [] -> list.reverse(done)
    [Generate(body), ..rest] -> {
      let assert Ok(call) =
        llm_wire.prepare(
          testing.config(),
          provider.generation_request(model(), current)
            |> llm_wire.with_output("draft", domain.body_codec()),
        )
      let assert Ok(raw) = codec.encode_json(domain.body_codec(), body)
      let next =
        domain.Draft(domain.Text(..current.text, body:), current.generation + 1)
      exchanges(next, rest, [testing.exchange(call, testing.text(raw)), ..done])
    }
    [Review(reply), ..rest] -> {
      let assert Ok(call) =
        llm_wire.prepare(
          testing.config(),
          provider.review_request(model(), current)
            |> llm_wire.with_output("review", domain.decision_codec()),
        )
      exchanges(current, rest, [testing.exchange(call, reply), ..done])
    }
  }
}

fn fixture(
  turns: List(Turn),
  publish: fn(String) -> operation.Operation(Nil, domain.Draft, domain.Artifact),
) -> Fixture {
  let directory = temp_dir()
  let source = directory <> "/source.txt"
  let assert Ok(Nil) = write_file(source, source_text)
  let client = script("Mention the date and price.", turns)
  let runs =
    store.directory(process.new_name("writing-case"), directory <> "/runs")
  let owner = start_store(runs)
  let runtime =
    fabric_writing.runtime(
      runs,
      provider.generator(client, testing.config(), model()),
      provider.llm_reviewer(client, testing.config(), model()),
      publish(directory <> "/published"),
    )
  let assert Ok(handle) =
    fabric_writing.start(
      runtime,
      "article",
      source,
      "Mention the date and price.",
    )
  Fixture(directory, owner, runs, handle, client)
}

fn close(fixture: Fixture) -> Nil {
  stop_store(fixture.owner, fixture.runs)
  http_gun.stop(fixture.client)
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
    let f = fixture([draft("draft"), Review(response)], file.publisher)
    let assert Ok(done) = graph.await(f.handle, 5000)
    let assert graph.Blocked(_, _) = done.status
    file.read(f.directory <> "/published/article-4.md") |> should.be_error
    done.receipts
    |> list.map(fn(receipt) { receipt.node })
    |> should.equal(["source", "generate"])
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
  close(f)
}

pub fn absent_source_stops_before_a_provider_call_test() {
  let directory = temp_dir()
  let runs = store.in_memory(process.new_name("absent-source"))
  let owner = start_store(runs)
  let client = script("write", [])
  let runtime =
    fabric_writing.runtime(
      runs,
      provider.generator(client, testing.config(), model()),
      provider.llm_reviewer(client, testing.config(), model()),
      file.publisher(directory),
    )
  let assert Ok(handle) =
    fabric_writing.start(runtime, "absent", directory <> "/missing", "write")
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Failed(_) = done.status
  // The source activation failed, so no generation was ever started.
  done.receipts |> should.equal([])
  http_gun.stop(client)
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
  close(Fixture(..f, owner:))
}
