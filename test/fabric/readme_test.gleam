//// The README's usage example, run: every call it shows, with the
//// application's own values supplied by the shared test tools. The Saga
//// tool is left to `consumers/app`.

import fabric
import fabric/agent.{type Agent}
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/apps
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleeunit/should

/// A transfer above 10 waits for a treasurer; anything else is allowed.
fn my_policy(_context: Nil, action: policy.Action) {
  case tool.input(apps.transfer_definition(), action) {
    Ok(transfer) if transfer.amount > 10 ->
      Ok(policy.RequireApproval(run.Requirement("treasurer", 1)))
    _ -> Ok(policy.Allow)
  }
}

fn desk(model: model.Model) -> Agent(Nil) {
  let weather_definition = apps.weather_definition()
  let weather =
    tool.bind(weather_definition, apps.lookup_weather, fn(error) {
      let apps.UnknownCity(name) = error
      tool.Explain("unknown city: " <> name)
    })
  let assert Ok(desk) =
    agent.new("desk", model, [weather, apps.transfer_tool()], my_policy)
    |> agent.with_limits(
      agent.Limits(
        ..agent.default_limits(),
        max_turns: 6,
        token_budget: Some(20_000),
      ),
    )
    |> agent.build
  desk
}

fn transfer(amount: String) -> model.Model {
  scripted.plan([
    scripted.call(
      "t",
      "transfer_funds",
      "{\"to\":\"bob\",\"amount\":" <> amount <> "}",
    ),
  ])
}

pub fn the_readme_example_runs_test() {
  let dir = restart.temp_dir()
  let runs = store.directory(process.new_name("runs"), dir)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start

  // Approved.
  let assert Ok(handle) = fabric.start(runs, desk(transfer("50")), Nil, "Pay")
  let assert Ok(run.Suspended([pending, ..], _)) = fabric.await(handle, 5000)
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      reviewer: Some("alice"),
      context: Nil,
    )
  fabric.await(handle, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"receipt\":\"r-bob\"}"))),
  )

  // Rejected, after a restart: the id is parsed from where it was kept.
  let assert Ok(handle) = fabric.start(runs, desk(transfer("50")), Nil, "Pay")
  let stored_id = run.id_to_string(fabric.id(handle))
  let assert Ok(id) = run.parse_id(stored_id)
  let assert Ok(handle) = fabric.recover(runs, desk(transfer("50")), Nil, id)
  let assert Ok(run.Suspended([pending, ..], _)) = fabric.await(handle, 5000)
  let assert Ok(_) =
    fabric.reject(
      handle,
      pending.reference,
      reason: "not today",
      reviewer: Some("alice"),
    )
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(handle, 5000)

  // Reconciled: the gateway timed out after sending.
  let assert Ok(handle) = fabric.start(runs, desk(transfer("5000")), Nil, "Pay")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(handle, 5000)
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      reviewer: Some("alice"),
      context: Nil,
    )
  let assert Ok(run.Suspended([], [uncertain, ..])) = fabric.await(handle, 5000)
  let assert Ok(_) =
    fabric.reconcile(handle, uncertain.reference, "{\"receipt\":\"r-1\"}")
  fabric.await(handle, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"receipt\":\"r-1\"}"))),
  )
  restart.remove_dir(dir)
}

pub fn the_readme_sub_agent_and_settling_tool_build_test() {
  let researcher = desk(scripted.plan([]))
  let assert Ok(_front_desk) =
    agent.new("front-desk", scripted.plan([]), [], my_policy)
    |> agent.with_sub_agent(
      apps.weather_definition(),
      to: researcher,
      prompt: fn(city: apps.City) { city.name },
      output: fn(answer) { Ok(apps.Forecast(answer)) },
    )
    |> agent.build
  let lookup =
    tool.bind_settling(
      apps.weather_definition(),
      fn(_, city: apps.City, _settlement) { apps.lookup_weather(Nil, city) },
      fn(_) { tool.Explain("unknown city") },
      within: 5000,
    )
  agent.new("looker", scripted.plan([]), [lookup], my_policy)
  |> support.agent
  |> fn(_) { Nil }
}
