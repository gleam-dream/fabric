//// The warden recipe of `fabric/approvers`, run against warden's test
//// provider: users sign in through its login page, and the provider grants
//// `approve:refund` to ada only.

import approvers_warden.{warden_approvers}
import fabric
import fabric/agent
import fabric/approvers
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/testing as fabric_testing
import fabric/tool
import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/string
import gleam/time/duration
import gleeunit
import json/blueprint/codec
import warden
import warden/config
import warden/resource
import warden/testing

pub fn main() -> Nil {
  gleeunit.main()
}

const audience = "https://desk.test"

const callback = "https://desk.test/callback"

const refund = run.Requirement("refund", 1)

type Desk {
  Desk(
    provider: testing.Provider,
    client: warden.Client,
    validator: resource.Validator,
  )
}

fn started() -> Desk {
  let assert Ok(provider) =
    testing.start_provider(
      testing.provider_options()
      |> testing.with_access_token_audiences([audience])
      |> testing.with_granted_scopes("ada", ["openid", "approve:refund"])
      |> testing.with_granted_scopes("mallory", ["openid"]),
    )
  let assert Ok(client) = warden.new(testing.config(provider, callback))
  let assert Ok(Nil) = warden.start(client)
  Desk(provider:, client:, validator: resource.new(client, audience:))
}

fn stopped(desk: Desk) -> Nil {
  warden.stop(desk.client)
  testing.stop_provider(desk.provider)
}

/// `subject` signs in through the provider's login page; the access token
/// of the session.
fn login(desk: Desk, subject: String) -> String {
  let assert Ok(redirect) =
    warden.begin_login(desk.client, request.new(), warden.default_login())
  let assert Ok(callback) = testing.authorize(desk.provider, redirect, subject:)
  let assert Ok(session) = warden.complete_login(desk.client, callback)
  let assert Ok(access) = warden.access_token(desk.client, session)
  warden.access_token_value(access.token)
}

/// A minted token for `audience` with `approve:refund`, changed by `spec`.
fn minted(desk: Desk, spec: fn(testing.TokenSpec) -> testing.TokenSpec) {
  testing.access_token("ada")
  |> testing.with_audiences([audience])
  |> testing.with_scopes(["approve:refund"])
  |> spec
  |> testing.issue_access_token(desk.provider, _)
}

/// A run of an agent whose one tool call, a refund, waits for a `refund`
/// approval answered by `approvers`.
fn waiting(
  approvers: approvers.Approvers(credential),
) -> #(fabric.Run(Nil, String), run.PendingApproval) {
  let order = {
    use id <- codec.field("order", codec.string(), get: fn(id) { id })
    codec.success(id)
  }
  let refund_tool =
    tool.define("refund", "Refund an order.", order, codec.string())
    |> tool.bind(fn(_context, _call, id) { Ok("refunded " <> id) }, fn(_) {
      tool.Explain("refund failed")
    })
  let call =
    model.tool_call(
      id: "c1",
      name: "refund",
      arguments_json: "{\"order\":\"o1\"}",
    )
  let scripted =
    model.new(fn(request: model.Request) {
      case list.length(request.messages) {
        1 -> Ok(model.ToolRequest(model.AssistantTurn("", [call], None), None))
        _ -> Ok(model.FinalAnswer("done", None))
      }
    })
  let gate = fn(_context, _action) { Ok(policy.RequireApproval(refund)) }
  let assert Ok(desk) =
    agent.new("desk", scripted, [refund_tool], gate)
    |> agent.with_approvers(approvers)
    |> agent.build
  let runs = store.in_memory(process.new_name("approvers-warden"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "refund",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(5))
  #(handle, pending)
}

pub fn a_token_with_the_scope_answers_and_is_recorded_test() {
  let desk = started()
  // Built once, at boot: the agent and the request handler share them.
  let desk_approvers = warden_approvers(desk.validator)
  let #(handle, pending) = waiting(desk_approvers)
  let assert Ok(proof) =
    approvers.check(
      desk_approvers,
      login(desk, "ada"),
      pending.reference.requirement,
    )
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, proof:, context: Nil)
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [action] = snapshot.actions
  let assert [
    run.Approval(answer: run.Approve, reviewer: Some(who), verifier:, ..),
  ] = action.approvals
  assert reviewer.subject(who) == "ada"
  assert reviewer.issuer(who) == Some(testing.issuer(desk.provider))
  assert verifier == Some("warden")
  stopped(desk)
}

pub fn a_token_without_the_scope_is_not_authorized_test() {
  let desk = started()
  let assert Error(approvers.NotAuthorized(reason)) =
    approvers.check(
      warden_approvers(desk.validator),
      login(desk, "mallory"),
      refund,
    )
  assert string.contains(reason, "approve:refund")
  stopped(desk)
}

pub fn expired_forged_foreign_and_malformed_tokens_are_not_authenticated_test() {
  let desk = started()
  let tokens = [
    minted(desk, testing.with_ttl(_, duration.seconds(-60))),
    minted(desk, testing.forged(_, testing.UnsignedToken)),
    minted(desk, testing.forged(_, testing.HmacWithPublicKey)),
    minted(desk, testing.with_audiences(_, ["https://elsewhere.test"])),
    minted(desk, testing.with_issuer(_, "https://impostor.test")),
    "not-a-token",
    "",
  ]
  list.each(tokens, fn(token) {
    let assert Error(approvers.NotAuthenticated(_)) =
      approvers.check(warden_approvers(desk.validator), token, refund)
  })
  // The same token, unchanged, is accepted.
  let assert Ok(_) =
    approvers.check(
      warden_approvers(desk.validator),
      minted(desk, fn(s) { s }),
      refund,
    )
  stopped(desk)
}

pub fn an_unreachable_key_source_is_unavailable_test() {
  let desk = started()
  let token = minted(desk, fn(spec) { spec })
  // A client whose issuer cannot be reached never loads its keys, so
  // nothing about the token is decided.
  let assert Ok(unreachable) =
    warden.new(
      config.resource_server(issuer: "https://localhost:1")
      |> config.with_destinations(config.AllowLoopbackForTesting),
    )
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(warden.supervised(unreachable))
    |> supervisor.start
  let validator = resource.new(unreachable, audience:)
  let assert Error(approvers.Unavailable(_)) =
    approvers.check(warden_approvers(validator), token, refund)
  stopped(desk)
}

pub fn a_proof_from_other_approvers_is_refused_test() {
  let desk = started()
  let desk_approvers = warden_approvers(desk.validator)
  let #(handle, pending) = waiting(desk_approvers)
  let ada = login(desk, "ada")
  // The application's test shortcut, and a permissive verifier that even
  // borrows the name: neither is the agent's approvers.
  let assert Ok(ada_reviewer) = reviewer.new("ada")
  let assert Ok(trusting) =
    approvers.check(fabric_testing.trusting_approvers(), ada_reviewer, refund)
  fabric.approve(handle, pending.reference, proof: trusting, context: Nil)
  |> should_be(
    Error(
      fabric.ProofRefused(approvers.OtherApprovers(
        "fabric/testing.trusting_approvers",
      )),
    ),
  )
  let permissive =
    approvers.new("warden", fn(token, _requirement) {
      reviewer.new(string.slice(token, 0, 8))
      |> result_to_denial
    })
  let assert Ok(forged) = approvers.check(permissive, ada, refund)
  fabric.reject(handle, pending.reference, proof: forged, reason: "no")
  |> should_be(Error(fabric.ProofRefused(approvers.OtherApprovers("warden"))))
  // The recipe built again is other approvers, even over the same
  // validator: only the value the agent was given answers.
  let assert Ok(again) =
    approvers.check(warden_approvers(desk.validator), ada, refund)
  fabric.approve(handle, pending.reference, proof: again, context: Nil)
  |> should_be(Error(fabric.ProofRefused(approvers.OtherApprovers("warden"))))
  // And over another validator, a token for another audience proves
  // nothing to this desk.
  let other = resource.new(desk.client, audience: "https://other.test")
  let elsewhere =
    minted(desk, testing.with_audiences(_, ["https://other.test"]))
  let assert Ok(foreign) =
    approvers.check(warden_approvers(other), elsewhere, refund)
  fabric.approve(handle, pending.reference, proof: foreign, context: Nil)
  |> should_be(Error(fabric.ProofRefused(approvers.OtherApprovers("warden"))))
  // Nothing was answered: the agent's own approvers still can.
  let assert Ok(proof) = approvers.check(desk_approvers, ada, refund)
  let assert Ok(_) =
    fabric.reject(handle, pending.reference, proof:, reason: "no")
  stopped(desk)
}

fn result_to_denial(
  result: Result(reviewer.Reviewer, reviewer.Error),
) -> Result(reviewer.Reviewer, approvers.Denial) {
  case result {
    Ok(reviewer) -> Ok(reviewer)
    Error(error) ->
      Error(approvers.NotAuthenticated(reviewer.describe_error(error)))
  }
}

fn should_be(actual: a, expected: a) -> Nil {
  assert actual == expected
}
