//// The ids and hashes Fabric makes itself. The four derived ids name stored
//// records, so their bytes must never change: `ids_test` fixes them to
//// expected values.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/string

/// 128 random bits as lowercase hexadecimal; unique across VM restarts.
pub fn random() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// The SHA-256 of `text`, in lowercase hexadecimal.
pub fn sha256_hex(text: String) -> String {
  string.lowercase(digest(<<text:utf8>>))
}

/// The id of the budget record of the run family rooted at `root`.
pub fn family_budget(root: String) -> String {
  "budget-" <> digest(<<"fabric.family.budget:":utf8, root:utf8>>)
}

/// The id of the child run that activation `activation` of the graph run
/// `parent` starts.
pub fn graph_child(parent: String, activation: Int) -> String {
  "graph-"
  <> digest(<<
    "fabric.graph.child:":utf8,
    parent:utf8,
    0,
    int.to_string(activation):utf8,
  >>)
}

/// A delegation's child run id: a domain-separated hash of the parent run
/// and the delegating action, so that it never has the shape of an id a
/// caller writes by hand (a parent id and a suffix).
pub fn agent_child(parent: String, turn: Int, call_id: String) -> String {
  "agent-"
  <> digest(<<
    "fabric.agent.child:":utf8,
    parent:utf8,
    0,
    int.to_string(turn):utf8,
    0,
    call_id:utf8,
  >>)
}

/// The id of fork member `member` of activation `activation` of `parent`.
pub fn graph_branch(parent: String, activation: Int, member: Int) -> String {
  "branch-"
  <> digest(<<
    "fabric.graph.branch:":utf8,
    parent:utf8,
    0,
    int.to_string(activation):utf8,
    0,
    int.to_string(member):utf8,
  >>)
}

/// The SHA-256 of `data`, in uppercase hexadecimal.
fn digest(data: BitArray) -> String {
  bit_array.base16_encode(crypto.hash(crypto.Sha256, data))
}
