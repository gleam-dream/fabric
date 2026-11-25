//// Starting a runner while its factory shuts down.

import fabric/agent
import fabric/internal/runner
import fabric/internal/runner_host
import fabric/internal/store
import fabric/policy
import fabric/support/scripted
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import sinal/correlation

/// A start that is waiting when the factory's shutdown reaches the caller
/// is given up: `prepare` returns `Error`, the shutdown stays queued for the
/// caller's own receive loop, and the process that was being prepared is
/// told to abandon once it is ready.
pub fn a_start_waiting_at_the_factorys_shutdown_is_given_up_test() {
  let runs = store.in_memory(process.new_name("runner-host-shutdown"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(#(_, _, factory)) = store.runners(runs)
  let gates = process.new_subject()
  let told = process.new_subject()
  // The prepared process reports that it is ready only when the test opens
  // its gate, so the helper's answer cannot arrive before the shutdown.
  let begin = fn(_pinned, _pids, ready) {
    let gate = process.new_subject()
    process.send(gates, gate)
    process.receive_forever(gate)
    let mailbox: process.Subject(Nil) = process.new_subject()
    let go = process.new_subject()
    process.send(ready, #(mailbox, go))
    process.send(told, process.receive_forever(go))
  }
  // The factory's exit signal, as a process that traps exits receives it,
  // 20 ms into the wait.
  let caller = process.self()
  process.spawn_unlinked(fn() {
    process.sleep(20)
    erlang_send(caller, #(atom.create("EXIT"), factory, atom.create("shutdown")))
  })
  runner_host.prepare(runs, begin, "abandon") |> should.equal(Error(Nil))
  runner_host.take_shutdown(factory) |> should.be_true
  let assert Ok(gate) = process.receive(gates, 5000)
  process.send(gate, Nil)
  process.receive(told, 5000) |> should.equal(Ok("abandon"))
  store.stop(runs) |> should.equal(Ok(Nil))
}

@external(erlang, "erlang", "send")
fn erlang_send(
  pid: process.Pid,
  message: #(atom.Atom, process.Pid, atom.Atom),
) -> #(atom.Atom, process.Pid, atom.Atom)

/// A runner that receives its factory's shutdown before it is asked to
/// build its agent, and only then is asked to build it and given its first
/// state, starts draining: it starts nothing of that state.
pub fn a_shutdown_before_the_build_drains_the_runner_test() {
  let runs = store.in_memory(process.new_name("runner-host-build-shutdown"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(#(_, _, factory)) = store.runners(runs)
  let assert Ok(agent) =
    agent.build(fn() {
      agent.new("agent", scripted.plan([]), [], policy.always_allow())
    })
  let setup = runner.agent_setup(runs, agent, Nil)
  let #(state, effects) =
    runner.root_state(setup, "run-0", "go", correlation.from_key("k"))
  let go = process.new_subject()
  let built = process.new_subject()
  let self = process.self()
  erlang_send(self, #(atom.create("EXIT"), factory, atom.create("shutdown")))
  process.send(go, runner.Build(runner.carried(setup), setup.identity, built))
  process.send(go, runner.Go(1, state, effects, None))
  let assert Ok(#(_, _, _, _, _, draining)) =
    runner.first_state(go, runs, factory, None, False)
  process.receive(built, 0) |> should.equal(Ok(Ok(Nil)))
  draining |> should.be_true
  store.stop(runs) |> should.equal(Ok(Nil))
}
