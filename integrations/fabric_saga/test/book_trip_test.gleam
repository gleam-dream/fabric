//// A Saga workflow as one Fabric tool, with the `book_trip` shape of
//// `experiments/workflow_composition`: reserve a flight, then a hotel for
//// the flight, then charge both. A hotel failure releases the flight.
//// Steps report to the test process, which waits on those reports, never
//// on sleeps.
////
//// A declined charge is retried a minute later, so a cancellation after
//// the decline finds no step in flight: Saga undoes every completed step
//// and settles the stopped call with how that ended. The charge has a
//// recovery decider; Saga names every attempt that crashed, so an outcome
//// in which each action returned is definite.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/telemetry as o
import fabric/testing
import fabric/tool
import fabric_saga
import fabric_saga/support/watched
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import saga
import saga/execution
import saga/telemetry as saga_telemetry
import sinal
import sinal/correlation

pub type Trip {
  Trip(city: String)
}

pub type Itinerary {
  Itinerary(flight: String, hotel: String, charge: String)
}

pub type TripError {
  NoHotel(city: String)
  CardDeclined
}

pub type UndoError {
  ReleaseRefused(what: String)
}

/// A step body reports `entry` and, for a gated entry, waits until the test
/// releases it.
type Report {
  Report(entry: String, release: Subject(Nil))
}

fn report(reports: Subject(Report), entry: String) -> Nil {
  let release = process.new_subject()
  process.send(reports, Report(entry, release))
  case string.starts_with(entry, "gate:") {
    True -> {
      let assert Ok(Nil) = process.receive(release, 10_000)
      Nil
    }
    False -> Nil
  }
}

/// `Atlantis` has no hotel; in `Mordor` there is no hotel and the flight
/// cannot be released; in `Slowtown` the charge waits for the test. In
/// `Latetown`, `Latemordor`, and `Lateslow` the card is declined and the
/// charge is retried a minute later; the flight cannot be released in
/// `Latemordor`, and the hotel's release waits for the test in `Lateslow`.
fn book_trip(
  reports: Subject(Report),
) -> saga.Workflow(Trip, Itinerary, TripError, UndoError) {
  let reserve_flight =
    saga.step("reserve_flight", fn(trip: Trip) {
      report(reports, "flight:reserve:" <> trip.city)
      Ok("FL-" <> trip.city)
    })
    |> saga.undo(fn(undo: saga.UndoRequest(Trip, String)) {
      let saga.UndoRequest(input: trip, output: flight, ..) = undo
      report(reports, "flight:release:" <> flight)
      case trip.city {
        "Mordor" | "Latemordor" -> Error(ReleaseRefused(flight))
        _ -> Ok(Nil)
      }
    })
  let reserve_hotel =
    saga.step("reserve_hotel", fn(pair: #(Trip, String)) {
      let #(trip, _flight) = pair
      case trip.city {
        "Atlantis" | "Mordor" -> {
          report(reports, "hotel:unavailable:" <> trip.city)
          Error(NoHotel(trip.city))
        }
        city -> {
          report(reports, "hotel:reserve:" <> city)
          Ok("HT-" <> city)
        }
      }
    })
    |> saga.undo(fn(undo: saga.UndoRequest(#(Trip, String), String)) {
      let saga.UndoRequest(input: pair, output: hotel, ..) = undo
      case pair.0.city {
        "Lateslow" -> report(reports, "gate:hotel:release:" <> hotel)
        _ -> report(reports, "hotel:release:" <> hotel)
      }
      Ok(Nil)
    })
  let charge =
    saga.step("charge", fn(pair: #(#(Trip, String), String)) {
      let #(#(trip, flight), hotel) = pair
      case trip.city {
        "Slowtown" -> report(reports, "gate:charge")
        "Latetown" | "Latemordor" | "Lateslow" | "Retrytown" ->
          report(reports, "charge:declined")
        _ -> report(reports, "charge")
      }
      case string.starts_with(trip.city, "Late") || trip.city == "Retrytown" {
        True -> Error(CardDeclined)
        False -> Ok(Itinerary(flight, hotel, "CH-1"))
      }
    })
    |> saga.compensate(max_attempts: 2, with: fn(failed) {
      let #(#(trip, _), _) = failed.input
      case trip.city {
        "Retrytown" -> saga.Retry
        _ -> {
          report(reports, "charge:retry-later")
          saga.RetryAfter(duration.seconds(60))
        }
      }
    })
  let workflow =
    saga.define("book_trip", fn(trip) {
      let flight = saga.perform(trip, reserve_flight)
      let hotel = saga.perform(saga.both(trip, flight), reserve_hotel)
      saga.perform(saga.both(saga.both(trip, flight), hotel), charge)
    })
  workflow
}

fn trip_definition() -> tool.Definition(Trip, Itinerary) {
  let itinerary = {
    use flight <- codec.field("flight", codec.string(), get: fn(i) { i.flight })
    use hotel <- codec.field("hotel", codec.string(), get: fn(i) { i.hotel })
    use charge <- codec.field("charge", codec.string(), get: fn(i) { i.charge })
    codec.success(Itinerary(flight:, hotel:, charge:))
  }
  let trip = {
    use city <- codec.field("city", codec.string(), get: fn(t) { t.city })
    codec.success(Trip(city:))
  }
  tool.define(
    "book_trip",
    "Book a flight, a hotel, and the charge for a trip.",
    trip,
    itinerary,
  )
}

fn trip_tool(reports: Subject(Report), rollback_within: Int) -> tool.Tool(Nil) {
  fabric_saga.tool(
    trip_definition(),
    book_trip(reports),
    // A cancelled run lets an in-flight step settle this long before
    // killing it and undoing what completed.
    execution.config()
      |> execution.with_max_concurrency(1)
      |> execution.with_settle_timeout(duration.milliseconds(50)),
    input: fn(_, _, input) { input },
    explain: fn(error) {
      case error {
        NoHotel(city) -> "no hotel in " <> city
        CardDeclined -> "the card was declined"
      }
    },
    rollback_within: duration.milliseconds(rollback_within),
  )
}

/// Books `city` once, then answers with every tool result it saw.
fn traveller(city: String) -> model.Model {
  let assert Ok(call) = testing.call(trip_definition(), "c1", Trip(city))
  model.new(fn(request: model.Request) {
    let results =
      list.filter_map(request.messages, fn(message) {
        case message {
          model.ToolResultMessage(_, content) -> Ok(content)
          _ -> Error(Nil)
        }
      })
    case results {
      [] -> Ok(model.ToolRequest(model.AssistantTurn("", [call], None), None))
      seen -> Ok(model.FinalAnswer(string.join(seen, " | "), None))
    }
  })
}

fn start(city: String, reports: Subject(Report)) -> fabric.Run(Nil) {
  start_in(watched.memory(), city, reports, 5000)
}

fn start_in(
  store: store.Store,
  city: String,
  reports: Subject(Report),
  rollback_within: Int,
) -> fabric.Run(Nil) {
  let assert Ok(agent) =
    agent.new(
      "traveller",
      traveller(city),
      [trip_tool(reports, rollback_within)],
      policy.always_allow(),
    )
    |> agent.build
  let assert Ok(run) =
    fabric.start(
      store,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "book",
      correlation: None,
    )
  run
}

/// The reports so far, oldest first, without waiting.
fn reported(reports: Subject(Report)) -> List(String) {
  case process.receive(reports, 0) {
    Ok(Report(entry, _)) -> [entry, ..reported(reports)]
    Error(Nil) -> []
  }
}

/// Waits for the next report and returns it.
fn next(reports: Subject(Report)) -> Report {
  let assert Ok(report) = process.receive(reports, 5000)
  report
}

fn action_state(run: fabric.Run(Nil)) -> run.ActionState {
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [action] = snapshot.actions
  action.state
}

/// The charge has a recovery decider; no action crashed, so Saga reports a
/// plain `Completed` and its output is the tool result.
pub fn a_completed_workflow_is_the_tool_result_test() {
  let reports = process.new_subject()
  let run = start("Porto", reports)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "{\"flight\":\"FL-Porto\",\"hotel\":\"HT-Porto\",\"charge\":\"CH-1\"}",
      )),
    ),
  )
  reported(reports)
  |> should.equal(["flight:reserve:Porto", "hotel:reserve:Porto", "charge"])
}

/// A failed step whose completed steps were all undone is a definite,
/// typed failure: the model sees the application's explanation.
pub fn a_failure_with_compensation_completed_is_a_typed_failure_test() {
  let reports = process.new_subject()
  let run = start("Atlantis", reports)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("{\"error\":\"no hotel in Atlantis\"}"))),
  )
  action_state(run)
  |> should.equal(run.ToolFailed("{\"error\":\"no hotel in Atlantis\"}"))
  reported(reports)
  |> should.equal([
    "flight:reserve:Atlantis", "hotel:unavailable:Atlantis",
    "flight:release:FL-Atlantis",
  ])
}

/// A compensation that did not complete leaves an effect in place: the
/// action is an uncertain effect and the run waits for reconciliation.
pub fn an_incomplete_compensation_is_an_uncertain_effect_test() {
  let reports = process.new_subject()
  let run = start("Mordor", reports)
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(5000))
  uncertain.tool |> should.equal("book_trip")
  string.contains(uncertain.evidence, "reserve_flight") |> should.be_true
  reported(reports)
  |> should.equal([
    "flight:reserve:Mordor", "hotel:unavailable:Mordor",
    "flight:release:FL-Mordor",
  ])
}

/// Cancelling the Fabric run stops the tool, and with it the Saga run:
/// Saga kills the charge still in flight after its settle window and
/// undoes the steps that completed. The charge's effect is unknown, so the
/// stopped call settles as an uncertain effect that names it.
pub fn cancelling_the_run_cancels_the_workflow_test() {
  let reports = process.new_subject()
  let run = start("Slowtown", reports)
  next(reports).entry |> should.equal("flight:reserve:Slowtown")
  next(reports).entry |> should.equal("hotel:reserve:Slowtown")
  next(reports).entry |> should.equal("gate:charge")

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(evidence) = action_state(run)
  string.contains(evidence, "attempt 1 of step charge was interrupted")
  |> should.be_true
  // Saga undoes the completed steps in reverse order.
  reported(reports)
  |> should.equal(["hotel:release:HT-Slowtown", "flight:release:FL-Slowtown"])
}

/// Every attempt of the charge returned a typed error and the completed
/// steps were undone: the failure after retries is definite, with the last
/// attempt's explanation.
pub fn a_typed_failure_after_retries_is_definite_test() {
  let reports = process.new_subject()
  let run = start("Retrytown", reports)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("{\"error\":\"the card was declined\"}"))),
  )
  action_state(run)
  |> should.equal(run.ToolFailed("{\"error\":\"the card was declined\"}"))
  reported(reports)
  |> should.equal([
    "flight:reserve:Retrytown", "hotel:reserve:Retrytown", "charge:declined",
    "charge:declined", "hotel:release:HT-Retrytown",
    "flight:release:FL-Retrytown",
  ])
}

/// Waits until the charge was declined and its retry scheduled.
fn declined(reports: Subject(Report), city: String) -> Nil {
  next(reports).entry |> should.equal("flight:reserve:" <> city)
  next(reports).entry |> should.equal("hotel:reserve:" <> city)
  next(reports).entry |> should.equal("charge:declined")
  next(reports).entry |> should.equal("charge:retry-later")
}

/// Cancelled while no step is in flight, Saga undoes every completed step,
/// and every action of the run returned: the stopped call settles as a
/// definite failure, and the run ends once it has.
pub fn a_cancellation_that_undid_everything_is_definite_test() {
  let reports = process.new_subject()
  let run = start("Latetown", reports)
  declined(reports, "Latetown")

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  action_state(run)
  |> should.equal(run.ToolFailed(
    "{\"error\":\"the workflow was cancelled; every completed step was undone\"}",
  ))
  reported(reports)
  |> should.equal(["hotel:release:HT-Latetown", "flight:release:FL-Latetown"])
}

/// An undo that failed during the cancellation leaves an effect in place:
/// the stopped call settles as an uncertain effect that names it.
pub fn a_cancellation_whose_undo_failed_is_uncertain_test() {
  let reports = process.new_subject()
  let run = start("Latemordor", reports)
  declined(reports, "Latemordor")

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(evidence) = action_state(run)
  string.contains(evidence, "not undone reserve_flight") |> should.be_true
}

/// Saga's rollback outlasts the call's bound: the run ends with an
/// uncertain effect. The outcome that arrives afterwards is refused: it is
/// read against the record, nothing is written, the record is unchanged,
/// and the refusal is observed with a summary of Saga's report.
pub fn an_outcome_after_the_run_ended_is_refused_test() {
  let reports = process.new_subject()
  let backend = watched.new()
  let run = start_in(watched.store(backend), "Lateslow", reports, 20)
  declined(reports, "Lateslow")

  let assert Ok(_) = fabric.cancel(run)
  let undo = next(reports)
  undo.entry |> should.equal("gate:hotel:release:HT-Lateslow")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(evidence) = action_state(run)
  string.contains(evidence, "no settlement") |> should.be_true
  let assert Ok(before) = fabric.snapshot(run)
  let writes = watched.writes(backend)

  let read = watched.notify_reads(backend)
  let refused = process.new_subject()
  let attached =
    sinal.observe(o.settlement_refused(), fn(_, refusal) {
      process.send(refused, refusal)
    })
  process.send(undo.release, Nil)
  next(reports).entry |> should.equal("flight:release:FL-Lateslow")
  let assert Ok(_) = process.receive(read, 5000)
  let assert Ok(refusal) = process.receive(refused, 5000)
  let _ = sinal.detach(attached)
  watched.writes(backend) |> should.equal(writes)
  fabric.snapshot(run) |> should.equal(Ok(before))
  refusal.reason |> should.equal(o.NotAwaited)
  refusal.action.tool |> should.equal("book_trip")
  string.contains(refusal.summary, "Saga reported cancelled")
  |> should.be_true
  string.contains(refusal.summary, "undone reserve_hotel, reserve_flight")
  |> should.be_true
}

/// Saga checks the configuration when the call starts the workflow: a
/// configuration it refuses is a definite failure that names the violation,
/// and no step runs.
pub fn an_invalid_config_fails_the_call_before_any_step_runs_test() {
  let reports = process.new_subject()
  let misconfigured =
    fabric_saga.tool(
      trip_definition(),
      book_trip(reports),
      execution.config() |> execution.with_max_concurrency(0),
      input: fn(_, _, input) { input },
      explain: fn(_) { "" },
      rollback_within: duration.milliseconds(5000),
    )
  let assert Ok(agent) =
    agent.new(
      "traveller",
      traveller("Porto"),
      [misconfigured],
      policy.always_allow(),
    )
    |> agent.build
  let assert Ok(run) =
    fabric.start(
      watched.memory(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "book",
      correlation: None,
    )
  let message =
    "{\"error\":\"the workflow is misconfigured: "
    <> execution.describe_config_error(execution.MaxConcurrencyNotPositive(0))
    <> "\"}"
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed(message))))
  action_state(run) |> should.equal(run.ToolFailed(message))
  reported(reports) |> should.equal([])
}

/// The workflow's input is built from the run's context, the call and the
/// tool's input, and the Saga run carries the Fabric run's correlation.
pub fn the_workflow_gets_the_call_and_the_runs_correlation_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let attachment =
    sinal.observe(saga_telemetry.run_started(), fn(_, metadata) {
      process.send(seen, metadata.correlation)
    })
  let trip =
    fabric_saga.tool(
      trip_definition(),
      book_trip(reports),
      execution.config(),
      input: fn(_context, call: tool.Call, trip: Trip) {
        Trip(trip.city <> "-" <> call.action.call_id)
      },
      explain: fn(_) { "failed" },
      rollback_within: duration.seconds(5),
    )
  let assert Ok(agent) =
    agent.new("traveller", traveller("Porto"), [trip], policy.always_allow())
    |> agent.build
  let ticket = correlation.from_key("trip-ticket")
  let assert Ok(handle) =
    fabric.start(
      watched.memory(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "book",
      correlation: Some(ticket),
    )
  let assert Ok(run.Finished(run.Completed(text))) =
    fabric.await(handle, within: duration.seconds(5))
  let _ = sinal.detach(attachment)
  string.contains(text, "FL-Porto-c1") |> should.be_true
  process.receive(seen, 1000) |> should.equal(Ok(ticket))
}
