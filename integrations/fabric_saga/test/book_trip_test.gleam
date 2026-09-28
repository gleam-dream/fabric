//// A Saga workflow as one Fabric tool, with the `book_trip` shape of
//// `experiments/workflow_composition`: reserve a flight, then a hotel for
//// the flight, then charge both. A hotel failure releases the flight.
//// Steps report to the test process, which waits on those reports, never
//// on sleeps.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import fabric_saga
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import saga
import saga/execution

pub type Trip {
  Trip(city: String)
}

pub type Itinerary {
  Itinerary(flight: String, hotel: String, charge: String)
}

pub type TripError {
  NoHotel(city: String)
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
/// cannot be released; in `Slowtown` the charge waits for the test.
fn book_trip(
  reports: Subject(Report),
) -> saga.Workflow(Trip, Itinerary, TripError, UndoError) {
  let reserve_flight =
    saga.step("reserve_flight", fn(trip: Trip) {
      report(reports, "flight:reserve:" <> trip.city)
      Ok("FL-" <> trip.city)
    })
    |> saga.undo(fn(trip: Trip, flight) {
      report(reports, "flight:release:" <> flight)
      case trip.city {
        "Mordor" -> Error(ReleaseRefused(flight))
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
    |> saga.undo(fn(_, hotel) {
      report(reports, "hotel:release:" <> hotel)
      Ok(Nil)
    })
  let charge =
    saga.step("charge", fn(pair: #(#(Trip, String), String)) {
      let #(#(trip, flight), hotel) = pair
      case trip.city {
        "Slowtown" -> report(reports, "gate:charge")
        _ -> report(reports, "charge")
      }
      Ok(Itinerary(flight, hotel, "CH-1"))
    })
  let assert Ok(workflow) =
    saga.define("book_trip", fn(trip) {
      let flight = saga.perform(trip, reserve_flight)
      let hotel = saga.perform(saga.both(trip, flight), reserve_hotel)
      saga.perform(saga.both(saga.both(trip, flight), hotel), charge)
    })
  workflow
}

fn trip_definition() -> tool.Definition(Trip, Itinerary) {
  let assert Ok(itinerary) =
    codec.record3(
      codec.required("flight", codec.string()),
      codec.required("hotel", codec.string()),
      codec.required("charge", codec.string()),
      Itinerary,
      fn(i) { i.flight },
      fn(i) { i.hotel },
      fn(i) { i.charge },
    )
  tool.define(
    "book_trip",
    "Book a flight, a hotel, and the charge for a trip.",
    codec.field("city", codec.string()) |> codec.imap(Trip, fn(t) { t.city }),
    itinerary,
  )
}

fn trip_tool(reports: Subject(Report)) -> tool.Tool(Nil) {
  let assert Ok(tool) =
    fabric_saga.tool(
      trip_definition(),
      book_trip(reports),
      // A cancelled run lets an in-flight step settle this long before
      // killing it and undoing what completed.
      execution.Config(
        ..execution.config(),
        max_concurrency: 1,
        settle_timeout: 50,
      ),
      explain: fn(error) {
        let NoHotel(city) = error
        "no hotel in " <> city
      },
    )
  tool
}

/// Books `city` once, then answers with every tool result it saw.
fn traveller(city: String) -> model.Model {
  let assert Ok(call) = tool.call(trip_definition(), "c1", Trip(city))
  model.new(fn(request: model.Request) {
    let results =
      list.filter_map(request.messages, fn(message) {
        case message {
          model.ToolResultMessage(_, content) -> Ok(content)
          _ -> Error(Nil)
        }
      })
    case results {
      [] -> Ok(model.ToolRequest("", [call], None))
      seen -> Ok(model.FinalAnswer(string.join(seen, " | "), None))
    }
  })
}

fn start(city: String, reports: Subject(Report)) -> fabric.Run(Nil) {
  let agent =
    agent.new(traveller(city), [trip_tool(reports)], policy.always_allow())
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "book")
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

pub fn a_completed_workflow_is_the_tool_result_test() {
  let reports = process.new_subject()
  let run = start("Porto", reports)
  fabric.await(run, 5000)
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
  fabric.await(run, 5000)
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
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  uncertain.tool |> should.equal("book_trip")
  string.contains(uncertain.evidence, "reserve_flight") |> should.be_true
  reported(reports)
  |> should.equal([
    "flight:reserve:Mordor", "hotel:unavailable:Mordor",
    "flight:release:FL-Mordor",
  ])
}

/// Cancelling the Fabric run stops the tool, and with it the Saga run:
/// Saga compensates the steps that completed. Fabric cannot know whether
/// that compensation succeeded, so the action is an uncertain effect.
pub fn cancelling_the_run_cancels_the_workflow_test() {
  let reports = process.new_subject()
  let run = start("Slowtown", reports)
  next(reports).entry |> should.equal("flight:reserve:Slowtown")
  next(reports).entry |> should.equal("hotel:reserve:Slowtown")
  next(reports).entry |> should.equal("gate:charge")

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(_) = action_state(run)
  // Saga undoes the completed steps in reverse order.
  next(reports).entry |> should.equal("hotel:release:HT-Slowtown")
  next(reports).entry |> should.equal("flight:release:FL-Slowtown")
}

pub fn an_invalid_config_is_refused_before_anything_runs_test() {
  let reports = process.new_subject()
  fabric_saga.tool(
    trip_definition(),
    book_trip(reports),
    execution.Config(..execution.config(), max_concurrency: 0),
    explain: fn(_) { "" },
  )
  |> should.equal(Error([execution.MaxConcurrencyNotPositive(0)]))
}
