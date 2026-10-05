import fabric/approvers
import fabric/classify_support as support
import fabric/graph
import fabric/graph/classify as decision
import fabric/graph/definition
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/testing as fabric_testing
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun/config as http_config
import http_gun/telemetry as http_telemetry
import json/blueprint/codec
import json/blueprint/value
import llm_wire/classify
import llm_wire/classify/question
import llm_wire/message
import simplifile
import sinal
import sinal/correlation

type Decision {
  Approve
  Revise
}

type Answers =
  #(question.Noul, #(question.Choice(Decision), question.Score))

fn questions() -> question.Batch(Answers) {
  let noul = question.noul(value.String("Is the statement correct?"), None)
  let choice =
    question.choice(value.String("What should happen?"), [
      question.alternative("approve", Approve, value.String("Correct")),
      question.alternative("revise", Revise, value.String("Incorrect")),
    ])
  let score =
    question.score(value.String("How correct?"), [
      value.String("incorrect"),
      value.String("partial"),
      value.String("correct"),
    ])
  let first = question.ask("correct", noul)
  let second = question.ask("decision", choice)
  let third = question.ask("quality", score)
  let rest = question.combine(second, third)
  let batch = question.combine(first, rest)
  batch
}

fn runtime(
  runs: store.Store,
  config: support.Config,
  policy: policy.Policy(support.Config),
) -> graph.Runtime(support.Config, String, classify.Outcome(Answers)) {
  let op =
    decision.decision(
      run.DefinitionId("classify", 1),
      codec.string(),
      questions(),
      config.settings,
      fn(settings: support.Config, input) {
        decision.call(settings.http, "jev-latest", value.String(input))
      },
    )
  let node_id = definition.node_id("classify")
  let node =
    definition.node(
      node_id,
      op,
      fn(state) { Ok(state) },
      fn(state, receipt) { Ok(definition.Finish(state, receipt)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("classifier-graph", 1),
        entry: node_id,
        nodes: [node],
        state: codec.string(),
        answer: classify.receipt_codec(support.settings(), questions()),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { config }, policy)
  |> graph.with_approvers(fabric_testing.trusting_approvers())
  |> graph.build
  |> should.be_ok
}

pub fn an_http_classifier_batch_retains_native_answers_models_usage_and_rubric_test() {
  use url <- support.fixture
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), support.config(url, "/v1/systemone"), allow),
      id("batch"),
      "2 + 2 = 4",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  let assert graph.Completed(receipt) = done.status
  receipt.requested_model |> should.equal("jev-latest")
  receipt.resolved_model |> should.equal("protocol-fixture-only")
  receipt.usage |> should.equal(message.Usage(12, 8, 20))
  let #(noul, #(choice, score)) = receipt.answer
  noul.yes |> should.equal(0.9)
  choice.selected |> should.equal(Approve)
  score.position |> should.equal(1.8)
  list.length(score.levels) |> should.equal(3)
  string.contains(receipt.request_json, "test-key") |> should.be_false
  let assert [saved] = done.receipts
  codec.decode_json(
    classify.receipt_codec(support.settings(), questions()),
    saved.output_json,
  )
  |> should.equal(Ok(receipt))
}

/// The classifier request goes through the caller's HTTP Gun client and
/// its events carry the graph run's correlation.
pub fn the_request_carries_the_runs_correlation_test() {
  use url <- support.fixture
  let label = "typesafe-correlation-test"
  let http =
    support.http_with(http_config.default() |> http_config.with_label(label))
  let seen = process.new_subject()
  let attachment =
    sinal.observe(http_telemetry.event(), fn(_, metadata) {
      case metadata.client == Some(label) {
        True -> process.send(seen, metadata.correlation)
        False -> Nil
      }
    })
  let ticket = correlation.from_key("classifier-ticket")
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), support.config_over(http, url, "/v1/systemone"), allow),
      id("correlated"),
      "2 + 2 = 4",
      correlation: Some(ticket),
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let _ = sinal.detach(attachment)
  let assert Ok(graph.Snapshot(status: graph.Completed(_), ..)) =
    graph.snapshot(handle)
  process.receive(seen, 1000) |> should.equal(Ok(Some(ticket)))
  Nil
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
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting
  support.stats(url, "calls") |> should.equal(0)
  graph.approve(
    handle,
    approval,
    proof: proof_for(approval.requirement, as_reviewer("reviewer")),
    context: support.config(url, "/v1/systemone"),
  )
  |> should.be_ok
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Completed(_) = done
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
        correlation: None,
      )
    let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
    let assert Ok(blocked) = graph.snapshot(handle)
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
  let config =
    support.config_over(
      support.http_with(
        http_config.default() |> http_config.with_max_request_body_bytes(16),
      ),
      url,
      "/v1/systemone",
    )
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), config, allow),
      id("too-large"),
      "sample",
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Failed(graph.OperationFailed(_)) = done
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
      correlation: None,
    )
  await_stat(url, "calls", 1, 100)
  graph.cancel(handle) |> should.be_ok
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
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
        graph.start(
          runtime(runs, config, allow),
          id("saved"),
          "sample",
          correlation: None,
        )
      process.send(ready, #(runs, handle))
      process.receive_forever(process.new_subject())
    })
  let #(runs, handle) = process.receive_forever(ready)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(before) = graph.snapshot(handle)
  let assert graph.Completed(_) = before.status
  support.stats(url, "calls") |> should.equal(1)
  process.kill(owner)
  let assert Ok(Nil) = store.stop(runs)
  support.stop(server)
  let handle = open_graph(runtime(directory(path), config, allow), id("saved"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(after) = graph.snapshot(handle)
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
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Completed(receipt) = done
  let codec = classify.receipt_codec(support.settings(), questions())
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
  let different = question.noul(value.String("A different question"), None)
  let different = question.ask("correct", different)
  codec.decode(classify.receipt_codec(support.settings(), different), saved)
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

fn allow(
  _: support.Config,
  _: policy.Action,
) -> Result(policy.Decision, String) {
  Ok(policy.Allow)
}

fn open_graph(
  runtime: graph.Runtime(context, state, answer),
  id: run.RunId,
) -> graph.Handle(context, state, answer) {
  let assert Ok(handle) = graph.open(runtime, id)
  handle
}

fn as_reviewer(subject: String) -> reviewer.Reviewer {
  let assert Ok(reviewer) = reviewer.new(subject)
  reviewer
}

/// A proof that `reviewer` answers a request waiting for `requirement`,
/// from the trusting approvers the test's agents and runtimes are given.
fn proof_for(
  requirement: run.Requirement,
  reviewer: reviewer.Reviewer,
) -> approvers.Proof {
  let assert Ok(proof) =
    approvers.check(fabric_testing.trusting_approvers(), reviewer, requirement)
  proof
}

pub fn pre_round9_receipt_and_graph_store_read_without_a_provider_test() {
  let receipt_codec = classify.receipt_codec(support.settings(), questions())
  let receipt =
    simplifile.read("test/fixtures/records/pre-round9-classifier-receipt.json")
    |> should.be_ok
  let restored = codec.decode_json(receipt_codec, receipt) |> should.be_ok
  restored.answer.0.yes |> should.equal(0.9)
  restored.answer.1.0.selected |> should.equal(Approve)
  let path = support.temp_dir()
  let target = path <> "/round9-old-classifier"
  simplifile.create_directory(target) |> should.be_ok
  list.each(
    [
      "00000000000000000001",
      "00000000000000000002",
      "00000000000000000003",
      "00000000000000000004",
    ],
    fn(revision) {
      let contents =
        simplifile.read(
          "test/fixtures/records/pre-round9-classifier-" <> revision <> ".json",
        )
        |> should.be_ok
      simplifile.write(target <> "/" <> revision <> ".json", contents)
      |> should.be_ok
    },
  )
  let runs = directory(path)
  let settings = support.Config(support.http(), support.settings())
  let handle =
    open_graph(runtime(runs, settings, allow), id("round9-old-classifier"))
  let snapshot = graph.snapshot(handle) |> should.be_ok
  let assert graph.Completed(answer) = snapshot.status
  answer |> should.equal(restored)
  store.stop(runs) |> should.be_ok
  support.remove_dir(path)
}
