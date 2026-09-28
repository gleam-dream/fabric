//// Helpers for testing an application's agents with scripted models, and
//// the checks a leased store backend must pass. Production code needs
//// nothing here.

import fabric/model.{type ToolCall}
import fabric/store.{type LeasedBackend}
import fabric/tool.{type Definition}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import json/blueprint/codec

/// A call to `definition` with `input` encoded by its input codec, as a
/// model would request it: for a scripted model (`model.new`) that calls
/// the application's tools. The arguments always decode under the tool
/// bound from the same definition.
pub fn call(
  definition: Definition(input, output),
  id: String,
  input: input,
) -> Result(ToolCall, codec.EncodeError) {
  tool.call(definition, id, input)
}

// --- leased backend conformance --------------------------------------------------

/// One property of the leased backend contract (see `fabric/store`, Leases):
/// `run` checks it and describes the first difference found.
pub type Check {
  Check(name: String, run: fn() -> Result(Nil, String))
}

/// The checks a leased backend must pass, each against a backend made by
/// `new`: compare-and-set, the lease conditions of each `store.Lease`,
/// renewal of live leases only and without a new revision, and
/// `claim_expired` with disjoint results for concurrent claimers. Run ids are fresh random ids, so a
/// backend may share its storage between checks; an expired lease is made
/// with a `ttl` of 0, so no clock control is needed. Run each check in a
/// test and fail it on `Error`.
pub fn leased_backend_checks(new: fn() -> LeasedBackend) -> List(Check) {
  [
    Check("insert stores revision 1 with its lease", fn() { inserts(new()) }),
    Check("compare_and_set advances one revision at a time", fn() {
      advances(new())
    }),
    Check("concurrent compare_and_set calls have one winner", fn() {
      one_winner(new())
    }),
    Check("claim waits for another owner's live lease", fn() { claims(new()) }),
    Check("hold requires the owner", fn() { holds(new()) }),
    Check("seize and release win over a live lease", fn() { seizes(new()) }),
    Check("renew extends its owner's live leases without a new revision", fn() {
      renews(new())
    }),
    Check("claim_expired claims only expired leases", fn() {
      claims_expired(new())
    }),
    Check("concurrent claim_expired calls are disjoint", fn() {
      disjoint_claims(new())
    }),
  ]
}

const long = 60_000

fn fresh() -> String {
  "run-" <> random_id()
}

fn expect(what: String, found: a, wanted: a) -> Result(Nil, String) {
  case found == wanted {
    True -> Ok(Nil)
    False ->
      Error(
        what
        <> ": expected "
        <> string.inspect(wanted)
        <> ", found "
        <> string.inspect(found),
      )
  }
}

fn inserts(backend: LeasedBackend) -> Result(Nil, String) {
  let #(claimed, released, held) = #(fresh(), fresh(), fresh())
  use _ <- result.try(expect(
    "insert with Claim",
    backend.insert(claimed, "a", store.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after insert with Claim",
    backend.get(claimed),
    Ok(store.Current(1, "a", store.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "insert with Release",
    backend.insert(released, "b", store.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after insert with Release",
    backend.get(released),
    Ok(store.Current(1, "b", store.Free)),
  ))
  use _ <- result.try(expect(
    "insert with Hold",
    backend.insert(held, "c", store.Hold("o1")),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after insert with Hold",
    backend.get(held),
    Ok(store.Current(1, "c", store.Free)),
  ))
  use _ <- result.try(expect(
    "insert of an existing run",
    backend.insert(claimed, "x", store.Release),
    Error(store.AlreadyExists),
  ))
  use _ <- result.try(expect(
    "get after a refused insert",
    backend.get(claimed),
    Ok(store.Current(1, "a", store.Held("o1", True))),
  ))
  expect("get of a missing run", backend.get(fresh()), Error(store.NotFound))
}

fn advances(backend: LeasedBackend) -> Result(Nil, String) {
  let run = fresh()
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", store.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "compare_and_set at the current revision",
    backend.compare_and_set(run, 1, "b", store.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after compare_and_set",
    backend.get(run),
    Ok(store.Current(2, "b", store.Free)),
  ))
  use _ <- result.try(expect(
    "compare_and_set at an older revision",
    backend.compare_and_set(run, 1, "stale", store.Release),
    Error(store.Conflict(2)),
  ))
  use _ <- result.try(expect(
    "compare_and_set at a later revision",
    backend.compare_and_set(run, 5, "ahead", store.Release),
    Error(store.Conflict(2)),
  ))
  use _ <- result.try(expect(
    "get after refused writes",
    backend.get(run),
    Ok(store.Current(2, "b", store.Free)),
  ))
  expect(
    "compare_and_set of a missing run",
    backend.compare_and_set(fresh(), 1, "x", store.Release),
    Error(store.NotFound),
  )
}

/// Runs `body(i)` for each `i` in `0..count - 1` in its own process, all
/// released together, and returns their results in order.
fn together(count: Int, body: fn(Int) -> a) -> List(a) {
  let results = process.new_subject()
  let waiting =
    list.index_map(list.repeat(Nil, count), fn(_, i) {
      let ready = process.new_subject()
      process.spawn(fn() {
        let start = process.new_subject()
        process.send(ready, start)
        process.receive_forever(start)
        process.send(results, #(i, body(i)))
      })
      process.receive_forever(ready)
    })
  list.each(waiting, process.send(_, Nil))
  list.map(waiting, fn(_) { process.receive_forever(results) })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(entry) { entry.1 })
}

fn one_winner(backend: LeasedBackend) -> Result(Nil, String) {
  let run = fresh()
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "base", store.Release),
    Ok(Nil),
  ))
  let outcomes =
    together(16, fn(i) {
      backend.compare_and_set(run, 1, "w" <> int.to_string(i), store.Release)
    })
  let winners =
    list.index_fold(outcomes, [], fn(winners, outcome, i) {
      case outcome {
        Ok(Nil) -> ["w" <> int.to_string(i), ..winners]
        Error(_) -> winners
      }
    })
  use _ <- result.try(expect("winners", list.length(winners), 1))
  use _ <- result.try(expect(
    "losers",
    list.filter(outcomes, fn(outcome) { outcome != Ok(Nil) }),
    list.repeat(Error(store.Conflict(2)), 15),
  ))
  expect(
    "the winner's record",
    backend.get(run),
    Ok(store.Current(2, list.first(winners) |> result.unwrap(""), store.Free)),
  )
}

fn claims(backend: LeasedBackend) -> Result(Nil, String) {
  let #(run, expired) = #(fresh(), fresh())
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", store.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "claim over another owner's live lease",
    backend.compare_and_set(run, 1, "b", store.Claim("o2", long)),
    Error(store.LeaseRefused(store.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "claim at an older revision",
    backend.compare_and_set(run, 0, "b", store.Claim("o1", long)),
    Error(store.Conflict(1)),
  ))
  use _ <- result.try(expect(
    "claim by the owner",
    backend.compare_and_set(run, 1, "b", store.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "release",
    backend.compare_and_set(run, 2, "c", store.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "claim of a free lease",
    backend.compare_and_set(run, 3, "d", store.Claim("o2", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after claims",
    backend.get(run),
    Ok(store.Current(4, "d", store.Held("o2", True))),
  ))
  use _ <- result.try(expect(
    "insert with an expired lease",
    backend.insert(expired, "a", store.Claim("o1", 0)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "an expired lease",
    backend.get(expired),
    Ok(store.Current(1, "a", store.Held("o1", False))),
  ))
  use _ <- result.try(expect(
    "claim of an expired lease",
    backend.compare_and_set(expired, 1, "b", store.Claim("o2", long)),
    Ok(Nil),
  ))
  expect(
    "get after claiming an expired lease",
    backend.get(expired),
    Ok(store.Current(2, "b", store.Held("o2", True))),
  )
}

fn holds(backend: LeasedBackend) -> Result(Nil, String) {
  let #(run, expired, free) = #(fresh(), fresh(), fresh())
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", store.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "hold by the owner",
    backend.compare_and_set(run, 1, "b", store.Hold("o1")),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after hold",
    backend.get(run),
    Ok(store.Current(2, "b", store.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "hold by another owner",
    backend.compare_and_set(run, 2, "c", store.Hold("o2")),
    Error(store.LeaseRefused(store.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "hold at an older revision",
    backend.compare_and_set(run, 1, "c", store.Hold("o1")),
    Error(store.Conflict(2)),
  ))
  use _ <- result.try(expect(
    "insert with an expired lease",
    backend.insert(expired, "a", store.Claim("o1", 0)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "hold of the owner's expired lease",
    backend.compare_and_set(expired, 1, "b", store.Hold("o1")),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "hold of another owner's expired lease",
    backend.compare_and_set(expired, 2, "c", store.Hold("o2")),
    Error(store.LeaseRefused(store.Held("o1", False))),
  ))
  use _ <- result.try(expect(
    "insert without a lease",
    backend.insert(free, "a", store.Release),
    Ok(Nil),
  ))
  expect(
    "hold of a free lease",
    backend.compare_and_set(free, 1, "b", store.Hold("o1")),
    Error(store.LeaseRefused(store.Free)),
  )
}

fn seizes(backend: LeasedBackend) -> Result(Nil, String) {
  let run = fresh()
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", store.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "seize at an older revision",
    backend.compare_and_set(run, 0, "b", store.Seize("o2", long)),
    Error(store.Conflict(1)),
  ))
  use _ <- result.try(expect(
    "seize of another owner's live lease",
    backend.compare_and_set(run, 1, "b", store.Seize("o2", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after seize",
    backend.get(run),
    Ok(store.Current(2, "b", store.Held("o2", True))),
  ))
  use _ <- result.try(expect(
    "release of another owner's live lease",
    backend.compare_and_set(run, 2, "c", store.Release),
    Ok(Nil),
  ))
  expect(
    "get after release",
    backend.get(run),
    Ok(store.Current(3, "c", store.Free)),
  )
}

fn renews(backend: LeasedBackend) -> Result(Nil, String) {
  let #(expired, live, other, free) = #(fresh(), fresh(), fresh(), fresh())
  use _ <- result.try(
    list.try_each(
      [
        #(expired, store.Claim("o1", 0)),
        #(live, store.Claim("o1", long)),
        #(other, store.Claim("o2", long)),
        #(free, store.Release),
      ],
      fn(entry) {
        expect("insert", backend.insert(entry.0, "a", entry.1), Ok(Nil))
      },
    ),
  )
  use renewed <- result.try(
    backend.renew("o1", [expired, live, other, free, fresh()], long)
    |> result.map_error(fn(error) { "renew: " <> string.inspect(error) }),
  )
  use _ <- result.try(expect("the runs renewed", renewed, [live]))
  use _ <- result.try(expect(
    "an expired lease is not renewed",
    backend.get(expired),
    Ok(store.Current(1, "a", store.Held("o1", False))),
  ))
  use _ <- result.try(expect(
    "another owner's lease",
    backend.get(other),
    Ok(store.Current(1, "a", store.Held("o2", True))),
  ))
  use _ <- result.try(expect(
    "a free lease",
    backend.get(free),
    Ok(store.Current(1, "a", store.Free)),
  ))
  expect(
    "compare_and_set at the revision before the renewal",
    backend.compare_and_set(live, 1, "b", store.Hold("o1")),
    Ok(Nil),
  )
}

fn claims_expired(backend: LeasedBackend) -> Result(Nil, String) {
  let expired = [fresh(), fresh(), fresh()]
  let #(live, free) = #(fresh(), fresh())
  use _ <- result.try(
    list.try_each(
      list.append(list.map(expired, fn(run) { #(run, store.Claim("o1", 0)) }), [
        #(live, store.Claim("o1", long)),
        #(free, store.Release),
      ]),
      fn(entry) {
        expect("insert", backend.insert(entry.0, "a", entry.1), Ok(Nil))
      },
    ),
  )
  use first <- result.try(
    backend.claim_expired("o2", long, 1)
    |> result.map_error(fn(error) { "claim_expired: " <> string.inspect(error) }),
  )
  use _ <- result.try(expect(
    "at most `limit` claimed",
    list.length(first) <= 1,
    True,
  ))
  use claimed <- result.try(claim_all("o2", backend, expired, first, 50))
  use _ <- result.try(
    expect(
      "live and free leases are not claimed",
      list.filter(claimed, fn(run) { run == live || run == free }),
      [],
    ),
  )
  use _ <- result.try(
    list.try_each(expired, fn(run) {
      expect(
        "a claimed lease",
        backend.get(run),
        Ok(store.Current(1, "a", store.Held("o2", True))),
      )
    }),
  )
  use _ <- result.try(expect(
    "a live lease",
    backend.get(live),
    Ok(store.Current(1, "a", store.Held("o1", True))),
  ))
  expect(
    "compare_and_set at the revision before the claim",
    backend.compare_and_set(
      list.first(expired) |> result.unwrap(""),
      1,
      "b",
      store.Hold("o2"),
    ),
    Ok(Nil),
  )
}

/// Claims expired leases for `owner` until every run of `wanted` was
/// claimed or `tries` runs out; returns every run claimed.
fn claim_all(
  owner: String,
  backend: LeasedBackend,
  wanted: List(String),
  claimed: List(String),
  tries: Int,
) -> Result(List(String), String) {
  case list.all(wanted, list.contains(claimed, _)), tries {
    True, _ -> Ok(claimed)
    False, 0 -> Error("claim_expired never claimed " <> string.inspect(wanted))
    False, _ ->
      case backend.claim_expired(owner, long, 10) {
        Ok([]) -> Error("claim_expired left " <> string.inspect(wanted))
        Ok(more) ->
          claim_all(
            owner,
            backend,
            wanted,
            list.append(claimed, more),
            tries - 1,
          )
        Error(error) -> Error("claim_expired: " <> string.inspect(error))
      }
  }
}

fn disjoint_claims(backend: LeasedBackend) -> Result(Nil, String) {
  let expired = list.map(list.repeat(Nil, 20), fn(_) { fresh() })
  use _ <- result.try(
    list.try_each(expired, fn(run) {
      expect("insert", backend.insert(run, "a", store.Claim("o1", 0)), Ok(Nil))
    }),
  )
  let claimed =
    together(8, fn(i) {
      claim_until_empty(backend, "c" <> int.to_string(i), [], 100)
    })
  use claimed <- result.try(result.all(claimed))
  let every = list.flatten(claimed)
  use _ <- result.try(expect(
    "runs claimed twice",
    list.length(every) - list.length(list.unique(every)),
    0,
  ))
  expect(
    "expired runs never claimed",
    list.filter(expired, fn(run) { !list.contains(every, run) }),
    [],
  )
}

fn claim_until_empty(
  backend: LeasedBackend,
  owner: String,
  claimed: List(String),
  tries: Int,
) -> Result(List(String), String) {
  case backend.claim_expired(owner, long, 3) {
    Ok([]) -> Ok(claimed)
    Ok(_) if tries == 0 -> Error("claim_expired kept returning runs")
    Ok(more) ->
      claim_until_empty(backend, owner, list.append(claimed, more), tries - 1)
    Error(error) -> Error("claim_expired: " <> string.inspect(error))
  }
}

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String
