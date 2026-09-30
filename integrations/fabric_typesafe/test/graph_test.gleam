import fabric/graph
import fabric/graph/definition
import fabric/policy
import fabric/run
import fabric/store
import fabric_typesafe
import fabric_typesafe/client
import fabric_typesafe/question
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import support

type Decision {
  Approve
  Revise
}

type Answers =
  #(question.Noul, #(question.Choice(Decision), question.Score))

fn questions() -> question.Batch(Answers) {
  let assert Ok(noul) =
    question.noul(value.String("Is the statement correct?"), None)
  let assert Ok(choice) =
    question.choice(value.String("What should happen?"), [
      question.Alternative("approve", Approve, value.String("Correct")),
      question.Alternative("revise", Revise, value.String("Incorrect")),
    ])
  let assert Ok(score) =
    question.score(value.String("How correct?"), [
      value.String("incorrect"),
      value.String("partial"),
      value.String("correct"),
    ])
  let assert Ok(first) = question.ask("correct", noul)
  let assert Ok(second) = question.ask("decision", choice)
  let assert Ok(third) = question.ask("quality", score)
  let assert Ok(rest) = question.combine(second, third)
  let assert Ok(batch) = question.combine(first, rest)
  batch
}

fn runtime(
  runs: store.Store,
  config: client.Config,
  policy: graph.Policy(client.Config),
) -> graph.Runtime(client.Config, String, fabric_typesafe.Receipt(Answers)) {
  let op =
    fabric_typesafe.new(
      run.Identity("classify", 1),
      codec.string(),
      questions(),
      fn(settings, input) {
        #(settings, fabric_typesafe.Request("jev-latest", value.String(input)))
      },
    )
  let assert Ok(node_id) = definition.node_id("classify")
  let node =
    definition.node(
      node_id,
      op,
      fn(state) { Ok(state) },
      fn(state, receipt) { Ok(definition.Finish(state, receipt)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("classifier-graph", 1),
      node_id,
      [node],
      codec.string(),
      fabric_typesafe.receipt_codec(questions()),
      1,
    ))
  graph.new(spec, runs, fn() { config }, policy)
}

pub fn an_http_classifier_batch_retains_native_answers_models_usage_and_rubric_test() {
  use url <- support.fixture
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), support.config(url, "/v1/systemone"), allow),
      id("batch"),
      "2 + 2 = 4",
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  receipt.requested_model |> should.equal("jev-latest")
  receipt.resolved_model |> should.equal("protocol-fixture-only")
  receipt.usage |> should.equal(fabric_typesafe.Usage(12, 8))
  let #(noul, #(choice, score)) = receipt.answer
  noul.yes |> should.equal(0.9)
  choice.selected |> should.equal(Approve)
  score.position |> should.equal(1.8)
  list.length(score.levels) |> should.equal(3)
  string.contains(receipt.request_json, "test-key") |> should.be_false
  let assert [saved] = done.receipts
  codec.decode_json(
    fabric_typesafe.receipt_codec(questions()),
    saved.output_json,
  )
  |> should.equal(Ok(receipt))
}

pub fn approval_precedes_request_construction_and_the_http_call_test() {
  use url <- support.fixture
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), support.config(url, "/v1/systemone"), fn(_, _) {
        Ok(policy.RequireApproval(run.Requirement("classifier-cost", 1)))
      }),
      id("approval"),
      "sample",
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  support.stats(url, "calls") |> should.equal(0)
  graph.approve(handle, approval) |> should.be_ok
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(_) = done.status
  support.stats(url, "calls") |> should.equal(1)
  Nil
}

pub fn malformed_results_rate_limits_and_lost_replies_never_route_or_retry_test() {
  list.each(["/wrong", "/duplicate", "/drop", "/busy", "/redirect"], fn(path) {
    use url <- support.fixture
    let assert Ok(handle) =
      graph.start(
        runtime(memory(), support.config(url, path), allow),
        id("uncertain"),
        "sample",
      )
    let assert Ok(blocked) = graph.await(handle, 5000)
    let assert graph.Blocked(_, graph.EffectUncertain(detail)) = blocked.status
    string.contains(detail, "private diagnostic body") |> should.be_false
    string.contains(detail, "test-key") |> should.be_false
    blocked.receipts |> should.equal([])
    graph.recover(handle) |> should.be_ok
    support.stats(url, "calls") |> should.equal(1)
    Nil
  })
}

pub fn an_unsent_request_is_a_definite_failure_test() {
  use url <- support.fixture
  let assert Ok(config) =
    client.with_bounds(
      support.config(url, "/v1/systemone"),
      client.Bounds(..client.bounds(), request_bytes: 16),
    )
  let assert Ok(handle) =
    graph.start(runtime(memory(), config, allow), id("too-large"), "sample")
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Failed(graph.OperationFailed(_)) = done.status
  support.stats(url, "calls") |> should.equal(0)
  Nil
}

pub fn cancellation_closes_local_work_and_preserves_remote_uncertainty_test() {
  use url <- support.fixture
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), support.config(url, "/hold"), allow),
      id("cancel"),
      "sample",
    )
  await_stat(url, "calls", 1, 100)
  graph.cancel(handle) |> should.be_ok
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Cancelled(graph.Unresolved(_, _)) = done.status
  await_stat(url, "disconnected", 1, 100)
  done.receipts |> should.equal([])
}

pub fn recovery_after_store_loss_reuses_the_receipt_with_the_server_stopped_test() {
  let #(server, url) = support.start()
  let path = support.temp_dir()
  let ready = process.new_subject()
  let config = support.config(url, "/v1/systemone")
  let owner =
    process.spawn_unlinked(fn() {
      let runs = directory(path)
      let assert Ok(handle) =
        graph.start(runtime(runs, config, allow), id("saved"), "sample")
      process.send(ready, #(runs, handle))
      process.receive_forever(process.new_subject())
    })
  let #(runs, handle) = process.receive_forever(ready)
  let assert Ok(before) = graph.await(handle, 5000)
  let assert graph.Completed(_) = before.status
  support.stats(url, "calls") |> should.equal(1)
  let assert Ok(pid) = store.pid(runs)
  let monitor = process.monitor(pid)
  process.kill(owner)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
  support.stop(server)
  let handle =
    graph.attach(runtime(directory(path), config, allow), id("saved"))
  let assert Ok(after) = graph.recover(handle)
  after.status |> should.equal(before.status)
  after.receipts |> should.equal(before.receipts)
  support.remove_dir(path)
}

pub fn corrupt_receipts_and_changed_question_meaning_cannot_restore_test() {
  use url <- support.fixture
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), support.config(url, "/v1/systemone"), allow),
      id("codec"),
      "sample",
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  let codec = fabric_typesafe.receipt_codec(questions())
  codec.encode(
    codec,
    fabric_typesafe.Receipt(..receipt, usage: fabric_typesafe.Usage(0, 0)),
  )
  |> should.be_error
  codec.encode(
    codec,
    fabric_typesafe.Receipt(..receipt, resolved_model: "other"),
  )
  |> should.be_error
  codec.decode(
    codec,
    value.Array([
      value.String("future"),
      value.String(receipt.request_json),
      value.String(receipt.response_json),
    ]),
  )
  |> should.be_error
  list.each(
    [
      #(
        string.replace(receipt.request_json, "jev-latest", "   "),
        receipt.response_json,
      ),
      #(
        receipt.request_json,
        string.replace(receipt.response_json, "protocol-fixture-only", "   "),
      ),
    ],
    fn(raw) {
      codec.decode(
        codec,
        value.Array([
          value.String("fabric.typesafe.receipt.v1"),
          value.String(raw.0),
          value.String(raw.1),
        ]),
      )
      |> should.be_error
    },
  )
  let assert Ok(saved) = codec.encode(codec, receipt)
  let assert Ok(different) =
    question.noul(value.String("A different question"), None)
  let assert Ok(different) = question.ask("correct", different)
  codec.decode(fabric_typesafe.receipt_codec(different), saved)
  |> should.be_error
  Nil
}

fn await_stat(url: String, key: String, expected: Int, left: Int) -> Nil {
  case support.stats(url, key) == expected, left {
    True, _ -> Nil
    False, 0 -> panic as "classifier event was not observed"
    False, _ -> {
      process.sleep(10)
      await_stat(url, key, expected, left - 1)
    }
  }
}

fn memory() -> store.Store {
  let runs = store.in_memory(process.new_name("classifier"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn directory(path: String) -> store.Store {
  let runs = store.directory(process.new_name("classifier"), path)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn id(text: String) -> run.RunId {
  let assert Ok(id) = run.parse_id(text)
  id
}

fn allow(_: client.Config, _: graph.Action) -> Result(policy.Decision, String) {
  Ok(policy.Allow)
}
