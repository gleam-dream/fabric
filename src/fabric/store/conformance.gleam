//// Checks a store backend against the contract of `fabric/store/backend`,
//// and a leased backend kept in memory for tests. A backend author runs
//// every check of `checks` in a test.

import fabric/graph/job
import fabric/graph/operation
import fabric/internal/graph/attachment
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/leased_memory
import fabric/internal/run_id
import fabric/run
import fabric/store/backend.{type LeasedBackend, Current, Held, Release}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// One property of the leased backend contract (see `fabric/store/backend`, Leases):
/// `run` checks it and describes the first difference found.
pub type Check {
  Check(name: String, run: fn() -> Result(Nil, String))
}

/// The checks a leased backend must pass, each against a backend made by
/// `new`: compare-and-set, the lease conditions of each `backend.Lease`,
/// renewal of live leases only and without a new revision, and
/// `claim_expired` with disjoint results for concurrent claimers, also
/// while a `Hold` races it. `claim_expired` claims any expired lease in
/// the backend's storage, so each call of `new` must return a backend over
/// storage of its own that starts empty (a fresh table, schema, or
/// process), and the checks must run one at a time. An expired lease is
/// made with a `ttl` of 0, so no clock control is needed. Run each check
/// in a test and fail it on `Error`.
pub fn checks(new: fn() -> LeasedBackend) -> List(Check) {
  [
    Check("backend time reads preserve records and lease ownership", fn() {
      clock_reads(new())
    }),
    Check(
      "absolute deadline claims use backend time and preserve executions",
      fn() { deadline_claims(new()) },
    ),
    Check(
      "scheduled claims are disjoint, keep revisions and retain their interval",
      fn() { scheduled_claims(new()) },
    ),
    Check(
      "idle claims preserve revisions and suppress unchanged dependencies",
      fn() { unchanged_dependencies(new()) },
    ),
    Check("child changes during a claim remain discoverable", fn() {
      changed_dependencies(new())
    }),
    Check(
      "concurrent idle claims are disjoint and failed claims remain recoverable",
      fn() { disjoint_dependencies(new()) },
    ),
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
    Check(
      "a hold racing claim_expired keeps the lease and record consistent",
      fn() { hold_races_claim(new()) },
    ),
  ]
}

const long = 60_000

fn clock_reads(backend: LeasedBackend) -> Result(Nil, String) {
  let id = fresh()
  use _ <- result.try(expect(
    "insert for clock read",
    backend.insert(id, "clock", backend.Claim("owner", long)),
    Ok(Nil),
  ))
  use before <- result.try(backend.get(id) |> result.map_error(string.inspect))
  use _ <- result.try(backend.now() |> result.map_error(string.inspect))
  expect(
    "clock read leaves revision, record and lease unchanged",
    backend.get(id),
    Ok(before),
  )
}

fn deadline_claims(backend: LeasedBackend) -> Result(Nil, String) {
  use now <- result.try(backend.now() |> result.map_error(string.inspect))
  let due = fresh()
  let future = fresh()
  use _ <- result.try(
    list.try_each([#(due, now - 1), #(future, now + long)], fn(entry) {
      let #(id, at) = entry
      let assert Ok(#(state, _)) =
        graph.start(
          id,
          graph.Definition(run.DefinitionId("deadline", 1), "v1", 1),
          "0",
          graph.Prepared(
            "signal",
            run.DefinitionId("signal", 1),
            "0",
            operation.RequireReconciliation,
            operation.Signal,
            Some(1),
          ),
        )
      let assert graph.Ready(a) = state.phase
      let waiting =
        graph.State(
          ..state,
          phase: graph.WaitingSignal(graph.Activation(..a, deadline: Some(at))),
        )
      let assert Ok(encoded) = graph_record.encode(waiting)
      backend.insert(id, encoded, Release) |> result.map_error(string.inspect)
    }),
  )
  use before <- result.try(backend.get(due) |> result.map_error(string.inspect))
  use _ <- result.try(expect(
    "only overdue wait is eligible",
    backend.claim_ready("deadline-owner", long, 10),
    Ok([due]),
  ))
  use after <- result.try(backend.get(due) |> result.map_error(string.inspect))
  use _ <- result.try(
    expect(
      "deadline claim preserves execution",
      #(after.record, after.revision),
      #(before.record, before.revision),
    ),
  )
  use _ <- result.try(expect(
    "live deadline claim is disjoint",
    backend.claim_ready("another-owner", long, 10),
    Ok([]),
  ))
  use _ <- result.try(
    backend.compare_and_set(due, after.revision, after.record, Release)
    |> result.map_error(string.inspect),
  )
  // A scheduling claim alone does not consume an absolute deadline. A clock
  // correction can make recovery release it; it must remain discoverable.
  expect(
    "released overdue wait remains due",
    backend.claim_ready("next-owner", long, 10),
    Ok([due]),
  )
}

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
    backend.insert(claimed, "a", backend.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after insert with Claim",
    backend.get(claimed),
    Ok(backend.Current(1, "a", backend.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "insert with Release",
    backend.insert(released, "b", backend.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after insert with Release",
    backend.get(released),
    Ok(backend.Current(1, "b", backend.Free)),
  ))
  use _ <- result.try(expect(
    "insert with Hold",
    backend.insert(held, "c", backend.Hold("o1")),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after insert with Hold",
    backend.get(held),
    Ok(backend.Current(1, "c", backend.Free)),
  ))
  use _ <- result.try(expect(
    "insert of an existing run",
    backend.insert(claimed, "x", backend.Release),
    Error(backend.AlreadyExists),
  ))
  use _ <- result.try(expect(
    "get after a refused insert",
    backend.get(claimed),
    Ok(backend.Current(1, "a", backend.Held("o1", True))),
  ))
  expect("get of a missing run", backend.get(fresh()), Error(backend.NotFound))
}

fn advances(backend: LeasedBackend) -> Result(Nil, String) {
  let run = fresh()
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", backend.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "compare_and_set at the current revision",
    backend.compare_and_set(run, 1, "b", backend.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after compare_and_set",
    backend.get(run),
    Ok(backend.Current(2, "b", backend.Free)),
  ))
  use _ <- result.try(expect(
    "compare_and_set at an older revision",
    backend.compare_and_set(run, 1, "stale", backend.Release),
    Error(backend.Conflict(2)),
  ))
  use _ <- result.try(expect(
    "compare_and_set at a later revision",
    backend.compare_and_set(run, 5, "ahead", backend.Release),
    Error(backend.Conflict(2)),
  ))
  use _ <- result.try(expect(
    "get after refused writes",
    backend.get(run),
    Ok(backend.Current(2, "b", backend.Free)),
  ))
  expect(
    "compare_and_set of a missing run",
    backend.compare_and_set(fresh(), 1, "x", backend.Release),
    Error(backend.NotFound),
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
    backend.insert(run, "base", backend.Release),
    Ok(Nil),
  ))
  let outcomes =
    together(16, fn(i) {
      backend.compare_and_set(run, 1, "w" <> int.to_string(i), backend.Release)
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
    list.repeat(Error(backend.Conflict(2)), 15),
  ))
  expect(
    "the winner's record",
    backend.get(run),
    Ok(backend.Current(
      2,
      list.first(winners) |> result.unwrap(""),
      backend.Free,
    )),
  )
}

fn claims(backend: LeasedBackend) -> Result(Nil, String) {
  let #(run, expired) = #(fresh(), fresh())
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", backend.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "claim over another owner's live lease",
    backend.compare_and_set(run, 1, "b", backend.Claim("o2", long)),
    Error(backend.LeaseRefused(backend.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "claim at an older revision",
    backend.compare_and_set(run, 0, "b", backend.Claim("o1", long)),
    Error(backend.Conflict(1)),
  ))
  use _ <- result.try(expect(
    "claim by the owner",
    backend.compare_and_set(run, 1, "b", backend.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "release",
    backend.compare_and_set(run, 2, "c", backend.Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "claim of a free lease",
    backend.compare_and_set(run, 3, "d", backend.Claim("o2", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after claims",
    backend.get(run),
    Ok(backend.Current(4, "d", backend.Held("o2", True))),
  ))
  use _ <- result.try(expect(
    "insert with an expired lease",
    backend.insert(expired, "a", backend.Claim("o1", 0)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "an expired lease",
    backend.get(expired),
    Ok(backend.Current(1, "a", backend.Held("o1", False))),
  ))
  use _ <- result.try(expect(
    "claim of an expired lease",
    backend.compare_and_set(expired, 1, "b", backend.Claim("o2", long)),
    Ok(Nil),
  ))
  expect(
    "get after claiming an expired lease",
    backend.get(expired),
    Ok(backend.Current(2, "b", backend.Held("o2", True))),
  )
}

fn holds(backend: LeasedBackend) -> Result(Nil, String) {
  let #(run, expired, free) = #(fresh(), fresh(), fresh())
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", backend.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "hold by the owner",
    backend.compare_and_set(run, 1, "b", backend.Hold("o1")),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after hold",
    backend.get(run),
    Ok(backend.Current(2, "b", backend.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "hold by another owner",
    backend.compare_and_set(run, 2, "c", backend.Hold("o2")),
    Error(backend.LeaseRefused(backend.Held("o1", True))),
  ))
  use _ <- result.try(expect(
    "hold at an older revision",
    backend.compare_and_set(run, 1, "c", backend.Hold("o1")),
    Error(backend.Conflict(2)),
  ))
  use _ <- result.try(expect(
    "insert with an expired lease",
    backend.insert(expired, "a", backend.Claim("o1", 0)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "hold of the owner's expired lease",
    backend.compare_and_set(expired, 1, "b", backend.Hold("o1")),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "hold of another owner's expired lease",
    backend.compare_and_set(expired, 2, "c", backend.Hold("o2")),
    Error(backend.LeaseRefused(backend.Held("o1", False))),
  ))
  use _ <- result.try(expect(
    "insert without a lease",
    backend.insert(free, "a", backend.Release),
    Ok(Nil),
  ))
  expect(
    "hold of a free lease",
    backend.compare_and_set(free, 1, "b", backend.Hold("o1")),
    Error(backend.LeaseRefused(backend.Free)),
  )
}

fn seizes(backend: LeasedBackend) -> Result(Nil, String) {
  let run = fresh()
  use _ <- result.try(expect(
    "insert",
    backend.insert(run, "a", backend.Claim("o1", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "seize at an older revision",
    backend.compare_and_set(run, 0, "b", backend.Seize("o2", long)),
    Error(backend.Conflict(1)),
  ))
  use _ <- result.try(expect(
    "seize of another owner's live lease",
    backend.compare_and_set(run, 1, "b", backend.Seize("o2", long)),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "get after seize",
    backend.get(run),
    Ok(backend.Current(2, "b", backend.Held("o2", True))),
  ))
  use _ <- result.try(expect(
    "release of another owner's live lease",
    backend.compare_and_set(run, 2, "c", backend.Release),
    Ok(Nil),
  ))
  expect(
    "get after release",
    backend.get(run),
    Ok(backend.Current(3, "c", backend.Free)),
  )
}

fn renews(backend: LeasedBackend) -> Result(Nil, String) {
  let #(expired, live, other, free) = #(fresh(), fresh(), fresh(), fresh())
  use _ <- result.try(
    list.try_each(
      [
        #(expired, backend.Claim("o1", 0)),
        #(live, backend.Claim("o1", long)),
        #(other, backend.Claim("o2", long)),
        #(free, backend.Release),
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
    Ok(backend.Current(1, "a", backend.Held("o1", False))),
  ))
  use _ <- result.try(expect(
    "another owner's lease",
    backend.get(other),
    Ok(backend.Current(1, "a", backend.Held("o2", True))),
  ))
  use _ <- result.try(expect(
    "a free lease",
    backend.get(free),
    Ok(backend.Current(1, "a", backend.Free)),
  ))
  expect(
    "compare_and_set at the revision before the renewal",
    backend.compare_and_set(live, 1, "b", backend.Hold("o1")),
    Ok(Nil),
  )
}

fn claims_expired(backend: LeasedBackend) -> Result(Nil, String) {
  let expired = [fresh(), fresh(), fresh()]
  let #(live, free) = #(fresh(), fresh())
  use _ <- result.try(
    list.try_each(
      list.append(
        list.map(expired, fn(run) { #(run, backend.Claim("o1", 0)) }),
        [
          #(live, backend.Claim("o1", long)),
          #(free, backend.Release),
        ],
      ),
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
        Ok(backend.Current(1, "a", backend.Held("o2", True))),
      )
    }),
  )
  use _ <- result.try(expect(
    "a live lease",
    backend.get(live),
    Ok(backend.Current(1, "a", backend.Held("o1", True))),
  ))
  expect(
    "compare_and_set at the revision before the claim",
    backend.compare_and_set(
      list.first(expired) |> result.unwrap(""),
      1,
      "b",
      backend.Hold("o2"),
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
      expect(
        "insert",
        backend.insert(run, "a", backend.Claim("o1", 0)),
        Ok(Nil),
      )
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

/// Holds (a record written by the owner of an expired lease) race a claim
/// of every expired lease by another owner. For each run, either the claim
/// took it, and the hold was refused by the claimed lease or wrote the
/// record before the claim; or the claim skipped it, and the hold wrote the
/// record with the lease unchanged. The claim never changes a revision and
/// never loses a hold's record.
fn hold_races_claim(backend: LeasedBackend) -> Result(Nil, String) {
  let runs = list.map(list.repeat(Nil, 10), fn(_) { fresh() })
  use _ <- result.try(
    list.try_each(runs, fn(run) {
      expect(
        "insert",
        backend.insert(run, "a", backend.Claim("o1", 0)),
        Ok(Nil),
      )
    }),
  )
  let outcomes =
    together(list.length(runs) + 1, fn(i) {
      case list.drop(runs, i) {
        [run, ..] ->
          Error(backend.compare_and_set(run, 1, "held", backend.Hold("o1")))
        [] -> Ok(backend.claim_expired("o2", long, 100))
      }
    })
  use claimed <- result.try(case list.last(outcomes) {
    Ok(Ok(Ok(claimed))) -> Ok(claimed)
    other -> Error("claim_expired: " <> string.inspect(other))
  })
  list.zip(runs, outcomes)
  |> list.try_each(fn(entry) {
    let #(run, outcome) = entry
    let hold = case outcome {
      Error(hold) -> hold
      Ok(_) -> Error(backend.Unavailable("no hold"))
    }
    let found = backend.get(run)
    case list.contains(claimed, run), hold {
      True, Ok(Nil) ->
        expect(
          "a run held, then claimed",
          found,
          Ok(backend.Current(2, "held", backend.Held("o2", True))),
        )
      True, _ -> {
        use _ <- result.try(expect(
          "a hold after the claim",
          hold,
          Error(backend.LeaseRefused(backend.Held("o2", True))),
        ))
        expect(
          "a run claimed, then refused to the hold",
          found,
          Ok(backend.Current(1, "a", backend.Held("o2", True))),
        )
      }
      False, _ -> {
        use _ <- result.try(expect("a hold of a run not claimed", hold, Ok(Nil)))
        expect(
          "a run held and not claimed",
          found,
          Ok(backend.Current(2, "held", backend.Held("o1", False))),
        )
      }
    }
  })
}

// A retained graph attachment with a real reciprocal child record. Backend
// conformance needs encoded states, without running application callbacks.
fn idle_pair(
  backend: LeasedBackend,
) -> Result(#(String, String, String, String), String) {
  let root = fresh()
  let prepared =
    graph.Prepared(
      "child",
      run.DefinitionId("child", 1),
      "0",
      operation.RequireReconciliation,
      operation.Subgraph,
      None,
    )
  let definition = graph.Definition(run.DefinitionId("parent", 1), "v1", 1)
  let assert Ok(#(state, _)) = graph.start(root, definition, "0", prepared)
  let assert graph.Ready(a) = state.phase
  let child_id = attachment.reserved_id(root, 1)
  let parent = graph.State(..state, phase: graph.WaitingChild(a, child_id))
  let assert Ok(parent_record) = graph_record.encode(parent)
  let assert Ok(#(child_state, _)) =
    graph.start(
      child_id,
      definition,
      "0",
      graph.Prepared(..prepared, kind: operation.Activity),
    )
  let assert graph.Ready(c) = child_state.phase
  let child_state =
    graph.State(
      ..child_state,
      parent: Some(run.GraphParent(run_id.from_string(root), 1)),
      phase: graph.Ended(graph.Cancelled(c, graph.BeforeStart)),
    )
  let assert Ok(child_record) = graph_record.encode(child_state)
  use _ <- result.try(expect(
    "parent insert",
    backend.insert(root, parent_record, Release),
    Ok(Nil),
  ))
  use _ <- result.map(expect(
    "child insert",
    backend.insert(child_id, child_record, Release),
    Ok(Nil),
  ))
  #(root, parent_record, child_id, child_record)
}

fn unchanged_dependencies(backend: LeasedBackend) -> Result(Nil, String) {
  use #(root, encoded, _, _) <- result.try(idle_pair(backend))
  use _ <- result.try(expect(
    "zero limit",
    backend.claim_ready("a", long, 0),
    Ok([]),
  ))
  use _ <- result.try(expect(
    "first observation",
    backend.claim_ready("a", long, 1),
    Ok([root]),
  ))
  use _ <- result.try(expect(
    "claim preserves bytes and revision",
    backend.get(root),
    Ok(Current(1, encoded, Held("a", True))),
  ))
  use _ <- result.try(expect(
    "no foreign live claim",
    backend.claim_ready("b", long, 1),
    Ok([]),
  ))
  use _ <- result.try(expect(
    "release observed wait",
    backend.compare_and_set(root, 1, encoded, Release),
    Ok(Nil),
  ))
  expect("unchanged dependency", backend.claim_ready("b", long, 1), Ok([]))
}

fn changed_dependencies(backend: LeasedBackend) -> Result(Nil, String) {
  use #(root, encoded, child, child_record) <- result.try(idle_pair(backend))
  use _ <- result.try(expect(
    "first observation",
    backend.claim_ready("a", long, 1),
    Ok([root]),
  ))
  use _ <- result.try(expect(
    "child changed while parent claimed",
    backend.compare_and_set(child, 1, child_record, Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "release observed wait",
    backend.compare_and_set(root, 1, encoded, Release),
    Ok(Nil),
  ))
  use _ <- result.try(expect(
    "changed dependency",
    backend.claim_ready("b", long, 1),
    Ok([root]),
  ))
  expect(
    "second claim preserves parent revision",
    backend.get(root),
    Ok(Current(2, encoded, Held("b", True))),
  )
}

fn disjoint_dependencies(backend: LeasedBackend) -> Result(Nil, String) {
  use roots <- result.try(
    list.try_map(list.repeat(Nil, 8), fn(_) {
      idle_pair(backend) |> result.map(fn(pair) { pair.0 })
    }),
  )
  let claimed =
    together(8, fn(n) {
      backend.claim_ready("claimer-" <> int.to_string(n), 0, 1)
    })
  use groups <- result.try(
    list.try_map(claimed, fn(result) {
      result |> result.map_error(string.inspect)
    }),
  )
  let ids = list.flatten(groups)
  use _ <- result.try(expect(
    "disjoint claims",
    list.length(list.unique(ids)),
    8,
  ))
  use _ <- result.try(expect(
    "all waits found",
    list.all(roots, list.contains(ids, _)),
    True,
  ))
  use _ <- result.try(expect(
    "expired claims are not free claims",
    backend.claim_ready("next", long, 8),
    Ok([]),
  ))
  use recovered <- result.try(
    backend.claim_expired("recovery", long, 8)
    |> result.map_error(string.inspect),
  )
  expect(
    "failed observation remains recoverable",
    list.all(roots, list.contains(recovered, _)),
    True,
  )
}

// --- a leased backend in memory ---------------------------------------------------

fn scheduled_claims(backend: LeasedBackend) -> Result(Nil, String) {
  use records <- result.try(
    list.try_map(list.repeat(Nil, 4), fn(_) {
      let id = "poll-" <> random_id()
      let prepared =
        graph.Prepared(
          "observe",
          run.DefinitionId("job", 1),
          "0",
          operation.RequireReconciliation,
          operation.Job(job.Every(60_000)),
          None,
        )
      let assert Ok(#(state, _)) =
        graph.start(
          id,
          graph.Definition(run.DefinitionId("polling", 1), "v1", 1),
          "0",
          prepared,
        )
      let assert graph.Ready(a) = state.phase
      let assert Ok(encoded) =
        graph_record.encode(graph.State(..state, phase: graph.WaitingJob(a)))
      backend.insert(id, encoded, Release)
      |> result.map_error(string.inspect)
      |> result.map(fn(_) { #(id, encoded) })
    }),
  )
  use claimed <- result.try(
    together(4, fn(n) {
      backend.claim_ready("poller-" <> int.to_string(n), long, 1)
    })
    |> list.try_map(fn(reply) { reply |> result.map_error(string.inspect) }),
  )
  let ids = list.flatten(claimed)
  use _ <- result.try(expect(
    "each poll claimed once",
    list.length(list.unique(ids)),
    4,
  ))
  use _ <- result.try(expect("one row per claim", list.length(ids), 4))
  use _ <- result.try(
    list.try_each(records, fn(record) {
      use current <- result.try(
        backend.get(record.0) |> result.map_error(string.inspect),
      )
      use _ <- result.try(expect(
        "claim preserves execution revision",
        current.revision,
        1,
      ))
      use _ <- result.try(expect(
        "claim preserves execution bytes",
        current.record,
        record.1,
      ))
      backend.compare_and_set(record.0, 1, record.1, Release)
      |> result.map_error(string.inspect)
    }),
  )
  expect(
    "released polls retain their due time",
    backend.claim_ready("later", long, 4),
    Ok([]),
  )
}

/// A leased backend kept in memory by one process, shared by every store
/// given `backend` in this VM, and a clock that tests can move forward.
pub type LeasedMemory {
  LeasedMemory(
    backend: LeasedBackend,
    /// Moves the backend's clock forward by this many milliseconds.
    advance: fn(Int) -> Nil,
  )
}

/// A leased backend in memory (see `fabric/store/backend`, Leases), for tests: it
/// stands for a database that several nodes share, each node a leased
/// store of its own node id over `backend`; not for runs that must outlive
/// the VM. Its process stops when the process that called this exits. Its
/// clock is UTC system time, moved forward by `advance`.
pub fn leased_memory() -> LeasedMemory {
  let memory = leased_memory.system()
  LeasedMemory(backend: memory.backend, advance: memory.advance)
}

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String
