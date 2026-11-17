//// The derived ids name stored records. These values were computed by the
//// Erlang functions the Gleam ones replaced; a change in any of them would
//// orphan records written before it.

import fabric/internal/ids
import gleam/string
import gleeunit/should

pub fn a_family_budget_id_is_fixed_test() {
  ids.family_budget("run-1")
  |> should.equal(
    "budget-616F5CD6BF1C99BAE627A1200E04A1CF6EA3B8E29F4D5D2B4B93EDF971AFA2F1",
  )
  ids.family_budget("")
  |> should.equal(
    "budget-1E85AC75B2BD183E111658466D6EB38C1C055D5B8B9625AEFE64D59BBD680CBE",
  )
}

pub fn a_graph_child_id_is_fixed_test() {
  ids.graph_child("run-1", 7)
  |> should.equal(
    "graph-AB48B9B5F0B3AF3E036B0540EE1662C08C31DCD2B7FE03EDC674A95F4624B3AD",
  )
  ids.graph_child("", -3)
  |> should.equal(
    "graph-6B683DD4D6203E76BD2985069C347A6D8DFF60346464341709049E0548E95F89",
  )
}

pub fn an_agent_child_id_is_fixed_test() {
  ids.agent_child("run-1", 3, "call_ü")
  |> should.equal(
    "agent-7370FE8FE205BDB1313077ED4EBD1254567D3C4B08FB10903E4B351D7F5E849E",
  )
}

pub fn a_graph_branch_id_is_fixed_test() {
  ids.graph_branch("run-1", 7, 2)
  |> should.equal(
    "branch-DCB2462C929D83C869C59333DBA953CA3B363B0051647FD2D00139234B024161",
  )
}

pub fn a_sha256_is_lowercase_hexadecimal_test() {
  ids.sha256_hex("a\u{0}b")
  |> should.equal(
    "59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138",
  )
  ids.sha256_hex("日本")
  |> should.equal(
    "cf2abf0c5be326cb922a70f8163f91079c4d9aa8655c60ead89ad545c9de2e92",
  )
}

pub fn a_random_id_is_32_lowercase_hexadecimal_digits_test() {
  let id = ids.random()
  #(string.length(id), id == string.lowercase(id), id == ids.random())
  |> should.equal(#(32, True, False))
}
