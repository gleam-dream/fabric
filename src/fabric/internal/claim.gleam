//// A one-shot decision between a command's caller and the runner it is
//// sent to: exactly one of them takes it. The runner that takes it applies
//// the command; a caller that takes it first (it stopped waiting) has
//// withdrawn it, and the runner drops it. No clock is involved, so a runner
//// descheduled between reading a deadline and applying a command can never
//// apply one its caller already reported as not applied.

/// Shared by the two sides of one command.
pub type Claim

@external(erlang, "fabric_ffi", "claim_new")
pub fn new() -> Claim

/// The runner takes the command: `True` if it may apply it.
pub fn accept(claim: Claim) -> Bool {
  take(claim, 1)
}

/// The caller withdraws the command: `True` if the runner had not taken
/// it, which now never will.
pub fn withdraw(claim: Claim) -> Bool {
  take(claim, 2)
}

@external(erlang, "fabric_ffi", "claim_take")
fn take(claim: Claim, taker: Int) -> Bool
