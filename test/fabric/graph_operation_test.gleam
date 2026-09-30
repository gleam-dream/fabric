import fabric/graph/operation
import fabric/graph/signal
import fabric/run
import gleam/erlang/process
import gleeunit/should
import json/blueprint/codec

fn invocation(attempt: Int) -> operation.Invocation {
  let assert Ok(id) = run.parse_id("effect-key")
  operation.Invocation(id, 3, attempt)
}

fn no_error(_error: Nil) -> operation.Failure {
  operation.DefiniteFailure("cannot fail")
}

pub fn native_body_receives_the_stable_logical_identity_and_current_attempt_test() {
  let calls = process.new_subject()
  let op =
    operation.new(
      run.Identity("counter", 1),
      codec.int(),
      codec.int(),
      fn(calls, invocation, n) {
        process.send(calls, invocation)
        Ok(n + 1)
      },
      no_error,
    )
  operation.invoke(op, calls, invocation(1), "6") |> should.equal(Ok("7"))
  operation.invoke(op, calls, invocation(2), "6") |> should.equal(Ok("7"))
  let assert Ok(first) = process.receive(calls, 1000)
  let assert Ok(second) = process.receive(calls, 1000)
  first.run |> should.equal(second.run)
  first.activation |> should.equal(second.activation)
  first.attempt |> should.equal(1)
  second.attempt |> should.equal(2)
  operation.with_replay(op, 0)
  |> should.equal(Error(operation.InvalidAttemptBound(0)))
  let assert Ok(replayable) = operation.with_replay(op, 2)
  operation.recovery(replayable) |> should.equal(operation.ReplayInterrupted(2))
}

pub fn undecodable_input_does_not_enter_the_native_body_test() {
  let calls = process.new_subject()
  let op =
    operation.new(
      run.Identity("counter", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        process.send(calls, Nil)
        Ok(n)
      },
      no_error,
    )
  let assert Error(operation.InputDecodingFailed(_)) =
    operation.invoke(op, Nil, invocation(1), "true")
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn unusable_output_retains_evidence_of_the_returned_value_test() {
  let reason = codec.CannotEncode(codec.CustomEncodeReason("not persistable"))
  let output = codec.new(fn(_n: Int) { Error(reason) }, codec.decode_int_value)
  let op =
    operation.new(
      run.Identity("counter", 1),
      codec.int(),
      output,
      fn(_, _, n) { Ok(n + 1) },
      no_error,
    )
  operation.invoke(op, Nil, invocation(1), "6")
  |> should.equal(Error(operation.OutputEncodingFailed("7", reason)))
}

type DomainFailure {
  Rejected
  LostReceipt
}

pub fn application_error_classification_preserves_uncertainty_test() {
  let op =
    operation.new(
      run.Identity("external", 1),
      codec.int(),
      codec.int(),
      fn(failure: DomainFailure, _, _) { Error(failure) },
      fn(failure) {
        case failure {
          Rejected -> operation.DefiniteFailure("rejected before submission")
          LostReceipt ->
            operation.UncertainEffect("submission may have succeeded")
        }
      },
    )
  operation.invoke(op, Rejected, invocation(1), "0")
  |> should.equal(
    Error(
      operation.BodyFailed(operation.DefiniteFailure(
        "rejected before submission",
      )),
    ),
  )
  operation.invoke(op, LostReceipt, invocation(1), "0")
  |> should.equal(
    Error(
      operation.BodyFailed(operation.UncertainEffect(
        "submission may have succeeded",
      )),
    ),
  )
}

pub fn signal_operations_cannot_be_executed_or_declared_replayable_test() {
  let op =
    operation.await_signal(
      codec.int(),
      signal.new(run.Identity("human", 1), codec.bool()),
    )
  operation.kind(op) |> should.equal(operation.Signal)
  operation.invoke(op, Nil, invocation(1), "1")
  |> should.equal(Error(operation.NotExecutable))
  operation.with_replay(op, 2)
  |> should.equal(Error(operation.ReplayRequiresActivity))
}
