//// Answers take a proof from `approvers.check`: only the approvers of the
//// agent or graph runtime that issued the request, for its requirement,
//// within the proof lifetime. Records written before proofs still read and
//// stay answerable.

import fabric
import fabric/agent.{type Agent}
import fabric/approvers.{type Approvers}
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/controller
import fabric/internal/record
import fabric/internal/store as store_core
import fabric/policy
import fabric/reviewer.{type Reviewer}
import fabric/run.{Requirement}
import fabric/store
import fabric/support
import fabric/support/apps
import fabric/support/codecs
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

const transfer = Requirement("transfer", 1)

/// Approvers whose credential is a password: `"sesame"` proves `alice`.
fn desk_approvers(password: String) -> Approvers(String) {
  use credential, _requirement <- approvers.new("desk-sso")
  case credential == password {
    True -> Ok(support.reviewer("alice"))
    False -> Error(approvers.NotAuthenticated("wrong password"))
  }
}

fn spec() -> agent.Spec(Nil, String) {
  agent.new(
    "desk",
    scripted.plan([
      scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
    ]),
    [apps.transfer_tool()],
    fn(_, _) { Ok(policy.RequireApproval(transfer)) },
  )
}

fn built(spec: agent.Spec(Nil, String)) -> Agent(Nil, String) {
  let assert Ok(agent) = support.build(spec)
  agent
}

fn waiting(
  desk: Agent(Nil, String),
) -> #(fabric.Run(Nil, String), run.PendingApproval) {
  waiting_in(support.store(), desk)
}

fn waiting_in(
  runs: store.Store,
  desk: Agent(Nil, String),
) -> #(fabric.Run(Nil, String), run.PendingApproval) {
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "pay",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(5))
  #(handle, pending)
}

fn proof(
  approvers: Approvers(credential),
  credential: credential,
  reference: run.ApprovalRef,
) -> approvers.Proof {
  let assert Ok(proof) = approvers.check(approvers, credential, reference)
  proof
}

fn graph_proof(
  approvers: Approvers(credential),
  credential: credential,
  reference: graph.ApprovalRef,
) -> approvers.Proof {
  let assert Ok(proof) = graph.check_approval(approvers, credential, reference)
  proof
}

/// `refused` is an `OtherRequest` refusal between these run and
/// requirement pairs: the proof's and the answered request's.
fn other_request(
  refused: Result(status, fabric.Error),
  proof: #(run.RunId, run.Requirement),
  request: #(run.RunId, run.Requirement),
) -> Nil {
  let assert Error(fabric.ProofRefused(error)) = refused
  is_other_request(error, proof, request)
}

fn graph_other_request(
  refused: Result(status, graph.Error),
  proof: #(run.RunId, run.Requirement),
  request: #(run.RunId, run.Requirement),
) -> Nil {
  let assert Error(graph.ProofRefused(error)) = refused
  is_other_request(error, proof, request)
}

fn is_other_request(
  error: approvers.ProofError,
  proof: #(run.RunId, run.Requirement),
  request: #(run.RunId, run.Requirement),
) -> Nil {
  let assert approvers.OtherRequest(proof: made_for, request: answered) = error
  #(made_for.run, made_for.requirement) |> should.equal(proof)
  #(answered.run, answered.requirement) |> should.equal(request)
}

/// The run is still waiting for `pending`, unanswered.
fn still_waiting(
  handle: fabric.Run(Nil, String),
  pending: run.PendingApproval,
) {
  let assert Ok(run.Suspended([again], [])) =
    fabric.await(handle, within: duration.milliseconds(0))
  again |> should.equal(pending)
}

pub fn check_names_the_reviewer_and_the_request_test() {
  let sso = desk_approvers("sesame")
  let #(_, pending) = waiting(spec() |> agent.with_approvers(sso) |> built)
  let made = proof(sso, "sesame", pending.reference)
  approvers.reviewer(made) |> should.equal(support.reviewer("alice"))
  approvers.verifier(made) |> should.equal("desk-sso")
  let request = approvers.request(made)
  request.run |> should.equal(pending.reference.run)
  request.requirement |> should.equal(transfer)
  approvers.name(sso) |> should.equal("desk-sso")
  approvers.check(sso, "guess", pending.reference)
  |> should.equal(Error(approvers.NotAuthenticated("wrong password")))
}

pub fn the_agent_s_approvers_answer_and_are_recorded_test() {
  let sso = desk_approvers("sesame")
  let #(handle, pending) = waiting(spec() |> agent.with_approvers(sso) |> built)
  let made = proof(sso, "sesame", pending.reference)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, proof: made, context: Nil)
  let assert Ok(run.Finished(_)) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [run.ActionRecord(approvals: [approval], ..)] = snapshot.actions
  approval.reviewer |> should.equal(Some(support.reviewer("alice")))
  approval.verifier |> should.equal(Some("desk-sso"))
}

pub fn a_rejection_takes_and_records_a_proof_too_test() {
  let sso = desk_approvers("sesame")
  let #(handle, pending) = waiting(spec() |> agent.with_approvers(sso) |> built)
  let assert Ok(_) =
    fabric.reject(
      handle,
      pending.reference,
      proof: proof(sso, "sesame", pending.reference),
      reason: "not today",
    )
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [run.ActionRecord(approvals: [approval], ..)] = snapshot.actions
  approval.answer |> should.equal(run.Reject("not today"))
  approval.verifier |> should.equal(Some("desk-sso"))
}

pub fn an_agent_without_approvers_accepts_no_answer_test() {
  let #(handle, pending) = waiting(built(spec()))
  let made = proof(testing.trusting_approvers(), alice(), pending.reference)
  fabric.approve(handle, pending.reference, proof: made, context: Nil)
  |> should.equal(Error(fabric.ProofRefused(approvers.NoApprovers)))
  fabric.reject(handle, pending.reference, proof: made, reason: "no")
  |> should.equal(Error(fabric.ProofRefused(approvers.NoApprovers)))
  fabric.error_kind(fabric.ProofRefused(approvers.NoApprovers))
  |> should.equal(fabric.Refused)
  still_waiting(handle, pending)
}

pub fn a_proof_from_other_approvers_is_refused_test() {
  let sso = desk_approvers("sesame")
  let #(handle, pending) = waiting(spec() |> agent.with_approvers(sso) |> built)
  // The same function built again, even with the same password, the test
  // shortcut, and a permissive verifier that borrows the name: none is the
  // desk's.
  let others = [
    #(proof(desk_approvers("sesame"), "sesame", pending.reference), "desk-sso"),
    #(
      proof(testing.trusting_approvers(), alice(), pending.reference),
      "fabric/testing.trusting_approvers",
    ),
    #(
      proof(
        approvers.new("desk-sso", fn(_, _) { Ok(support.reviewer("mallory")) }),
        "anything",
        pending.reference,
      ),
      "desk-sso",
    ),
  ]
  list.each(others, fn(other) {
    let #(made, name) = other
    fabric.approve(handle, pending.reference, proof: made, context: Nil)
    |> should.equal(Error(fabric.ProofRefused(approvers.OtherApprovers(name))))
  })
  still_waiting(handle, pending)
}

pub fn a_proof_for_another_requirement_is_refused_test() {
  let sso = desk_approvers("sesame")
  let #(handle, pending) = waiting(spec() |> agent.with_approvers(sso) |> built)
  let elsewhere = Requirement("transfer", 2)
  let made =
    proof(
      sso,
      "sesame",
      run.ApprovalRef(..pending.reference, requirement: elsewhere),
    )
  let refused =
    fabric.approve(handle, pending.reference, proof: made, context: Nil)
  refused
  |> other_request(#(pending.reference.run, elsewhere), #(
    pending.reference.run,
    transfer,
  ))
  let assert Error(error) = refused
  fabric.describe_error(error)
  |> string.contains("transfer version 2")
  |> should.be_true
  still_waiting(handle, pending)
}

pub fn a_proof_older_than_its_lifetime_is_refused_test() {
  let sso = desk_approvers("sesame")
  let brief =
    sso
    |> approvers.with_proof_lifetime(run.After(duration.milliseconds(1)))
  let runs = support.store()
  let #(handle, pending) =
    waiting_in(runs, spec() |> agent.with_approvers(brief) |> built)
  let made = proof(brief, "sesame", pending.reference)
  process.sleep(20)
  let assert Error(fabric.ProofRefused(approvers.ProofExpired(age:, lifetime:))) =
    fabric.approve(handle, pending.reference, proof: made, context: Nil)
  lifetime |> should.equal(1)
  { age > 1 } |> should.be_true
  still_waiting(handle, pending)
  // The lifetime is the receiving agent's: under `Infinity` the same proof
  // still answers.
  let lasting = sso |> approvers.with_proof_lifetime(run.Infinity)
  let reopened = spec() |> agent.with_approvers(lasting) |> built
  let assert Ok(again) = fabric.open(runs, reopened, Nil, fabric.id(handle))
  let assert Ok(_) =
    fabric.approve(again, pending.reference, proof: made, context: Nil)
}

// --- sub-agents ----------------------------------------------------------------

fn research() -> tool.Definition(String, String) {
  tool.define(
    "research",
    "Research a topic.",
    codecs.one_field("topic", codec.string()),
    codec.string(),
  )
}

fn front(
  child: agent.Spec(Nil, String),
  approvers: Approvers(credential),
) -> Agent(Nil, String) {
  agent.new(
    "front",
    scripted.plan([scripted.call("r1", "research", "{\"topic\":\"x\"}")]),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(research(), to: built(child), prompt: fn(t) { t })
  |> agent.with_approvers(approvers)
  |> built
}

pub fn a_sub_agent_without_approvers_is_answered_with_its_parent_s_test() {
  let sso = desk_approvers("sesame")
  let #(handle, pending) = waiting(front(spec(), sso))
  // The request is the child's: its reference names the child run.
  { pending.reference.run != fabric.id(handle) } |> should.be_true
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      proof: proof(sso, "sesame", pending.reference),
      context: Nil,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, within: duration.seconds(5))
}

pub fn a_sub_agent_with_its_own_approvers_is_answered_with_them_test() {
  let own = desk_approvers("child-only")
  let sso = desk_approvers("sesame")
  let child = spec() |> agent.with_approvers(own)
  let #(handle, pending) = waiting(front(child, sso))
  fabric.approve(
    handle,
    pending.reference,
    proof: proof(sso, "sesame", pending.reference),
    context: Nil,
  )
  |> should.equal(
    Error(fabric.ProofRefused(approvers.OtherApprovers("desk-sso"))),
  )
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      proof: proof(own, "child-only", pending.reference),
      context: Nil,
    )
}

// --- graphs --------------------------------------------------------------------

fn publishing(
  runs: store.Store,
  approvers: Option(Approvers(String)),
) -> graph.Runtime(Nil, Int, Int) {
  let op =
    operation.new(
      run.DefinitionId("publish", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) { Ok(n * 2) },
      fn(_: Nil) { tool.Explain("unreachable") },
    )
  let node = definition.node_id("publish")
  let assert Ok(d) =
    definition.build(definition.new(
      run.DefinitionId("approved-publishing", 1),
      entry: node,
      nodes: [
        definition.node(
          node,
          op,
          fn(n) { Ok(n) },
          fn(state, out) { Ok(definition.Finish(state, out)) },
          [],
        ),
      ],
      state: codec.int(),
      answer: codec.int(),
    ))
  let spec =
    graph.new(d, runs, fn(_) { Nil }, fn(_, _) {
      Ok(policy.RequireApproval(Requirement("publish", 1)))
    })
  let spec = case approvers {
    Some(approvers) -> graph.with_approvers(spec, approvers)
    None -> spec
  }
  let assert Ok(runtime) = graph.build(spec)
  runtime
}

fn graph_waiting(
  runtime: graph.Runtime(Nil, Int, Int),
) -> #(graph.Handle(Nil, Int, Int), graph.ApprovalRef) {
  let assert Ok(handle) =
    graph.start(runtime, id: run.new_id(), initial: 21, correlation: None)
  let assert Ok(graph.AwaitingApproval(pending)) =
    graph.await(handle, within: duration.seconds(5))
  #(handle, pending)
}

pub fn a_graph_runtime_answers_only_with_its_approvers_test() {
  let sso = desk_approvers("sesame")
  let runs = support.store()
  let publish = Requirement("publish", 1)
  // No approvers: no answer.
  let #(handle, pending) = graph_waiting(publishing(runs, None))
  let made = graph_proof(sso, "sesame", pending)
  graph.approve(handle, pending, proof: made, context: Nil)
  |> should.equal(Error(graph.ProofRefused(approvers.NoApprovers)))
  graph.error_kind(graph.ProofRefused(approvers.NoApprovers))
  |> should.equal(fabric.Refused)
  // Other approvers, or another requirement: refused.
  let #(handle, pending) = graph_waiting(publishing(runs, Some(sso)))
  graph.approve(
    handle,
    pending,
    proof: graph_proof(testing.trusting_approvers(), alice(), pending),
    context: Nil,
  )
  |> should.equal(
    Error(
      graph.ProofRefused(approvers.OtherApprovers(
        "fabric/testing.trusting_approvers",
      )),
    ),
  )
  graph.reject(
    handle,
    pending,
    proof: graph_proof(
      sso,
      "sesame",
      graph.ApprovalRef(..pending, requirement: transfer),
    ),
    reason: "no",
  )
  |> graph_other_request(#(pending.run, transfer), #(pending.run, publish))
  // Its own approvers answer, and are recorded.
  let made = graph_proof(sso, "sesame", pending)
  let assert Ok(_) = graph.approve(handle, pending, proof: made, context: Nil)
  let assert Ok(graph.Completed(42)) =
    graph.await(handle, within: duration.seconds(5))
  let assert Ok(done) = graph.snapshot(handle)
  let assert [receipt] = done.receipts
  let assert [approval] = receipt.approvals
  approval.reviewer |> should.equal(Some(support.reviewer("alice")))
  approval.verifier |> should.equal(Some("desk-sso"))
}

// --- records written before proofs ---------------------------------------------

fn fixture(name: String) -> String {
  let assert Ok(text) = restart.read_file("test/fixtures/records/" <> name)
  text
}

/// A suspended run stored before proofs existed: a typed reviewer with its issuer and
/// no verifier. It reads, and the new approvers answer it.
pub fn a_record_stored_before_proofs_reads_and_is_answered_test() {
  let sso = desk_approvers("sesame")
  let text = fixture("legacy-v7-typed-reviewer-suspended.json")
  let assert Ok(state) = record.decode(text)
  let assert [waiting, _] = controller.snapshot(state).actions
  let assert [
    run.Approval(answer: run.Approve, reviewer: Some(alice), verifier: None, ..),
  ] = waiting.approvals
  reviewer.issuer(alice) |> should.equal(Some("https://id.example"))
  let runs = support.store()
  let assert Ok(_) =
    store_core.insert(
      runs,
      "run-round-7",
      text,
      store_core.Detached(in_flight: False, seize: False),
    )
  let desk =
    agent.new("desk", scripted.plan([]), [apps.transfer_tool()], fn(_, _) {
      Ok(policy.Allow)
    })
    |> agent.with_approvers(sso)
    |> built
  let assert Ok(handle) =
    fabric.open(runs, desk, Nil, support.id("run-round-7"))
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.milliseconds(0))
  let assert Ok(_) =
    fabric.reject(
      handle,
      pending.reference,
      proof: proof(sso, "sesame", pending.reference),
      reason: "stale",
    )
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [answered, _] = snapshot.actions
  let assert [_, latest] = answered.approvals
  latest.verifier |> should.equal(Some("desk-sso"))
}

fn alice() -> Reviewer {
  support.reviewer("alice")
}

// --- binding to the request ----------------------------------------------------

/// A proof answers the one request it was checked for. Two runs wait for
/// the same requirement (say, two tenants' transfers): a proof checked for
/// the first run's request does not answer the second's, and the verifier
/// sees which run it authorizes.
pub fn a_proof_answers_only_the_request_it_was_checked_for_test() {
  let sso = desk_approvers("sesame")
  let desk = spec() |> agent.with_approvers(sso) |> built
  let #(_, first) = waiting(desk)
  let #(second_handle, second) = waiting(desk)
  let made = proof(sso, "sesame", first.reference)
  fabric.approve(second_handle, second.reference, proof: made, context: Nil)
  |> other_request(#(first.reference.run, transfer), #(
    second.reference.run,
    transfer,
  ))
  still_waiting(second_handle, second)
}

/// The verifier sees the run whose request it authorizes, so an
/// application can refuse a credential from another tenant.
pub fn the_verifier_sees_the_run_it_authorizes_test() {
  let #(_, pending) =
    waiting(spec() |> agent.with_approvers(desk_approvers("sesame")) |> built)
  let tenant = pending.reference.run
  let scoped = {
    use _credential, request <- approvers.new("tenant-sso")
    case request.run == tenant {
      True -> Ok(support.reviewer("alice"))
      False -> Error(approvers.NotAuthorized("another tenant's run"))
    }
  }
  approvers.check(scoped, "any", pending.reference) |> should.be_ok
  approvers.check(
    scoped,
    "any",
    run.ApprovalRef(..pending.reference, run: support.id("elsewhere")),
  )
  |> should.equal(Error(approvers.NotAuthorized("another tenant's run")))
}
