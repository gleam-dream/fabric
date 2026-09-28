//// Exactly one side decides a command sent to a live runner: the runner
//// that takes it applies it, and a caller that withdraws it first reports
//// it busy. A command reported busy is never applied, and one the runner
//// took is always waited for.

import fabric/internal/claim
import fabric/internal/controller
import fabric/internal/live
import fabric/internal/runner
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleeunit/should

pub fn the_first_side_to_take_a_claim_wins_test() {
  let taken = claim.new()
  claim.accept(taken) |> should.be_true
  claim.withdraw(taken) |> should.be_false
  claim.accept(taken) |> should.be_false

  let withdrawn = claim.new()
  claim.withdraw(withdrawn) |> should.be_true
  claim.accept(withdrawn) |> should.be_false
}

/// A runner and a caller racing for the same claim: exactly one wins, every
/// time.
pub fn racing_sides_never_both_win_test() {
  let results = process.new_subject()
  list.repeat(Nil, 500)
  |> list.each(fn(_) {
    let shared = claim.new()
    let go = process.new_subject()
    let racer = fn(take: fn(claim.Claim) -> Bool) {
      process.spawn(fn() {
        let start = process.new_subject()
        process.send(go, start)
        let assert Ok(Nil) = process.receive(start, 5000)
        process.send(results, take(shared))
      })
    }
    racer(claim.accept)
    racer(claim.withdraw)
    let assert Ok(first) = process.receive(go, 5000)
    let assert Ok(second) = process.receive(go, 5000)
    process.send(first, Nil)
    process.send(second, Nil)
    let assert Ok(a) = process.receive(results, 5000)
    let assert Ok(b) = process.receive(results, 5000)
    #(a, b) |> should.not_equal(#(True, True))
    #(a, b) |> should.not_equal(#(False, False))
  })
}

/// A runner that takes a command and is then descheduled past the caller's
/// window: the caller cannot withdraw it, so it waits for the outcome
/// instead of reporting the command busy.
pub fn a_command_the_runner_took_is_waited_for_test() {
  let mailboxes = process.new_subject()
  process.spawn(fn() {
    let mailbox: Subject(live.Message) = process.new_subject()
    process.send(mailboxes, mailbox)
    let assert Ok(live.Command(_, _, taken, reply)) =
      process.receive(mailbox, 5000)
    let assert True = claim.accept(taken)
    // Descheduled: the caller's window passes before the runner answers.
    process.sleep(100)
    process.send(reply, live.Accepted)
    process.send(reply, live.Refused(controller.StaleEvent))
  })
  let assert Ok(mailbox) = process.receive(mailboxes, 5000)
  runner.send_live(mailbox, fn(_) { Error(controller.StaleEvent) }, None, 10)
  |> should.equal(Error(runner.LiveRefused(controller.StaleEvent)))
}

/// A runner that reaches a command only after its caller gave up drops
/// it: the command reported busy is never applied.
pub fn a_withdrawn_command_is_never_applied_test() {
  let started = process.new_subject()
  let accepted = process.new_subject()
  process.spawn(fn() {
    let mailbox: Subject(live.Message) = process.new_subject()
    let release = process.new_subject()
    process.send(started, #(mailbox, release))
    let assert Ok(Nil) = process.receive(release, 5000)
    let assert Ok(live.Command(_, _, command, _)) =
      process.receive(mailbox, 5000)
    process.send(accepted, claim.accept(command))
  })
  let assert Ok(#(mailbox, release)) = process.receive(started, 5000)
  runner.send_live(mailbox, fn(_) { Error(controller.StaleEvent) }, None, 10)
  |> should.equal(Error(runner.LiveBusy))
  process.send(release, Nil)
  process.receive(accepted, 5000) |> should.equal(Ok(False))
}
