//// The README's example is `readme_example.gleam` verbatim, and it runs.

import fabric
import fabric/run
import fabric_postgres/agents
import fabric_postgres/readme_example
import fabric_postgres/support
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should

pub fn the_readme_example_is_the_example_module_test() {
  let assert Ok(readme) = support.read_file("README.md")
  let assert Ok(example) =
    support.read_file("test/fabric_postgres/readme_example.gleam")
  let assert Ok(#(_, rest)) = string.split_once(readme, "```gleam\n")
  let assert Ok(#(block, _)) = string.split_once(rest, "```")
  block |> should.equal(example)
}

/// The supervised pool and store start, the schema is migrated, and a
/// run finishes on the store.
pub fn the_readme_example_runs_test() {
  let runs = readme_example.start(support.url(), "readme-node")
  let gate = agents.gate()
  let assert Ok(started) =
    fabric.start(
      runs,
      agents.agent(gate, 1),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  agents.release(agents.arrival(gate))
  fabric.await(started, within: duration.seconds(30))
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":1}"))))
}
