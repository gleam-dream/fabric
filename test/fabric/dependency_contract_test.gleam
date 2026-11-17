//// What Fabric assumes about a dependency's behaviour beyond what that
//// dependency documents. Each test names one assumption, so that a release
//// which changes the behaviour fails here, by name.

import gleam/erlang/atom
import gleam/erlang/process
import gleam/string
import gleeunit/should

/// `process.select_record` hands its mapping the whole tuple, tag included.
/// gleam_erlang's documentation does not say which value the mapping
/// receives. The store's process reads the message sent straight to it from
/// the second element (`direct_message` in `fabric/internal/store`).
pub fn select_record_hands_its_mapping_the_whole_tuple_test() {
  let tag = atom.create("fabric_contract_record")
  let _ = erlang_send(process.self(), #(tag, "payload"))
  process.new_selector()
  |> process.select_record(tag, 1, string.inspect)
  |> process.selector_receive(0)
  |> should.equal(Ok(string.inspect(#(tag, "payload"))))
}

@external(erlang, "erlang", "send")
fn erlang_send(
  pid: process.Pid,
  message: #(atom.Atom, String),
) -> #(atom.Atom, String)
