//// The store port: what a backend implements to keep Fabric's runs.
////
//// Most applications use `fabric/store.in_memory`, `fabric/store.directory`
//// or `fabric_postgres`; this module is for writing another backend, and
//// `fabric/store/conformance` checks one.
////
//// A run is one encoded record (versioned JSON, see `fabric` docs) with a
//// revision. A backend supplies three functions over encoded records, and
//// Fabric writes only through `insert` and `compare_and_set`, so two owners
//// can never both advance the same revision.
////
//// The backend contract:
////
//// - `get(run)` returns the latest committed record with its revision, or
////   `NotFound`.
//// - `insert(run, record)` stores `record` as revision 1, or returns
////   `AlreadyExists` when the run exists.
//// - `compare_and_set(run, expected, record)` stores `record` as revision
////   `expected + 1` if and only if `expected` is the current revision, as
////   one atomic step; otherwise it returns `Conflict(current)` (or
////   `NotFound`). Two concurrent calls with the same `expected` must not
////   both succeed, also across processes and machines that share the
////   backend.
//// - Any other failure is `Unavailable(reason)`. A backend function that
////   crashes is treated as `Unavailable`. After an `Unavailable` write,
////   Fabric reads the run back: finding exactly the record it wrote at the
////   revision it wrote confirms the write. Every record Fabric writes
////   carries a fresh write token, so another writer's record is never
////   mistaken for this one. A write that is still unconfirmed stays
////   `Unavailable`: its outcome is unknown, since the backend may still
////   perform it later.
////
//// Leases. A leased backend (`LeasedBackend`) keeps, next to each run's
//// record, a lease: an owner and an expiry judged by the backend's own
//// clock. Several nodes sharing one database use it to agree on which
//// node drives a run; the lease never authorizes a write, which the
//// revision alone decides. Its contract, over the one above:
////
//// - `get(run)` returns the record, its revision, and its `Holder`:
////   `Free`, or `Held(owner, live)`, `live` while the expiry is ahead.
//// - `insert(run, record, lease)` stores revision 1 with the lease of a
////   `Claim` or `Seize` (held by its owner for its `ttl`), and none for a
////   `Hold` or `Release`.
//// - `compare_and_set(run, expected, record, lease)` checks the revision
////   first (`NotFound`, `Conflict(current)`), then the lease condition in
////   the same atomic step: `Hold(owner)` only while `owner` holds the
////   lease (live or expired) and leaves it unchanged; `Claim(owner, ttl)`
////   only while the lease is free, held by `owner`, or expired; `Seize`
////   and `Release` whoever holds it. A refused condition is
////   `LeaseRefused(holder)` and writes nothing. After the write, a `Claim`
////   or `Seize` owner holds the lease for `ttl` and a `Release` frees it.
//// - `renew(owner, runs, ttl)` extends, to `ttl` from now, the lease of
////   each of `runs` that `owner` holds while it is still live, and
////   returns those runs. An expired lease is not renewed, so a renewal
////   sent before a handoff (which leaves the lease expired) and applied
////   after it does not make the lease live again. It changes no revision.
//// - `claim_expired(owner, ttl, limit)` claims for `owner` up to `limit`
////   runs whose lease is held and expired, and returns them. It changes
////   no revision, and concurrent calls never return the same run.
//// - `claim_ready(owner, ttl, limit)` claims free runs whose validated idle
////   dependency is unseen/changed or whose scheduled observation is due.
////   Save the observation key, dependency revision and backend claim time
////   together with the lease; a concurrent child write remains discoverable.
////   A scheduled wait is first due immediately, then after its saved interval
////   from the last ready claim. Preserve its key/time across same-key writes
////   and metadata refresh. Only the backend's clock determines eligibility.
////   An absolute `At(due)` wait is eligible when backend UTC milliseconds reach
////   `due`. Claiming it does not consume it: after release it remains eligible
////   until the execution leaves that wait. Never treat it as a polling interval.
////   `Poll` and `Changed` can also carry an absolute deadline. Either the
////   ordinary trigger or that deadline makes the wait eligible, independently.
////   Claims are disjoint and bounded, change no execution bytes/revisions or
////   retention ages, and refuse stale source revisions/projection versions.
////   Use `fabric/store/discovery` to derive metadata from supported records.
//// - `now()` returns UTC Unix milliseconds from the same backend clock used
////   for leases and discovery. Reading it changes no stored data. Clock errors
////   propagate; leased stores never substitute a node's local time. Clock
////   corrections may move time backward, so samples need not be monotonic.
////
//// `fabric/store/conformance.checks` checks a leased backend against this
//// contract; `fabric/store/conformance.memory` is one kept in memory, for
//// tests.

/// What a backend function reports. `Unavailable` is any failure other than
/// the outcomes the contract names; its outcome is unknown for a write.
pub type StoreError {
  NotFound
  AlreadyExists
  /// The expected revision is no longer current.
  Conflict(current: Int)
  /// A leased backend refused the write's lease condition (see Leases):
  /// `holder` is the run's lease as the backend found it. Nothing was
  /// written.
  LeaseRefused(holder: Holder)
  Unavailable(reason: String)
}

pub type Stored {
  Stored(revision: Int, record: String)
}

/// Who holds a run's lease in a leased backend.
pub type Holder {
  Free
  /// `live`: the lease's expiry, judged by the backend's clock, is still
  /// ahead.
  Held(owner: String, live: Bool)
}

/// A run's latest record in a leased backend, with its revision and lease.
pub type Current {
  Current(revision: Int, record: String, holder: Holder)
}

/// What a write in a leased backend does to the run's lease, in the same
/// atomic step as the record (see Leases). `ttl` is in milliseconds, from
/// the backend's clock.
pub type Lease {
  /// Only while `owner` holds the lease, live or expired; the lease is
  /// unchanged.
  Hold(owner: String)
  /// Only while the lease is free, held by `owner`, or expired; `owner`
  /// then holds it for `ttl`.
  Claim(owner: String, ttl: Int)
  /// Whoever holds the lease; `owner` then holds it for `ttl`.
  Seize(owner: String, ttl: Int)
  /// Whoever holds the lease; it is then free.
  Release
}

/// The functions of a leased backend over encoded records (see Leases).
pub type LeasedBackend {
  LeasedBackend(
    /// UTC Unix milliseconds from the backend's lease/discovery clock.
    now: fn() -> Result(Int, StoreError),
    get: fn(String) -> Result(Current, StoreError),
    /// `insert(run, record, lease)`.
    insert: fn(String, String, Lease) -> Result(Nil, StoreError),
    /// `compare_and_set(run, expected, record, lease)`.
    compare_and_set: fn(String, Int, String, Lease) -> Result(Nil, StoreError),
    /// `renew(owner, runs, ttl)`: returns the runs renewed, those whose
    /// lease `owner` holds live.
    renew: fn(String, List(String), Int) -> Result(List(String), StoreError),
    /// `claim_expired(owner, ttl, limit)`: returns the runs claimed.
    claim_expired: fn(String, Int, Int) -> Result(List(String), StoreError),
    /// Claims free runs with a changed dependency, due observation or deadline.
    /// Atomically save the observed key, dependency revision and backend claim
    /// time with its lease. Claims change no execution revision or retention age.
    claim_ready: fn(String, Int, Int) -> Result(List(String), StoreError),
  )
}
