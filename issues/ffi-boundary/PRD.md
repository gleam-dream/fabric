# Fabric's Erlang code depends on other libraries' internals

## Problem

`src/fabric_ffi.erl` holds 24 functions. Two of them rely on how gleam_erlang
represents things internally: the form of a message sent to a named subject,
and the tuple behind the opaque `Subject` type. Neither is documented, and
Fabric accepts any gleam_erlang 1.x. gleam_erlang 1.3.0 already changed the
subject's representation once; Fabric kept working only because the tuple
kept its size. A further eight functions do work that public Gleam packages
Fabric already depends on can do.

## Outcome

- No function in `src/fabric_ffi.erl` relies on an undocumented
  representation of another library.
- Code that needs no Erlang is Gleam.
- What Fabric still assumes about a dependency's behaviour is asserted by a
  test that names the assumption.

## Not in scope

- The thirteen functions that call documented Erlang/OTP interfaces
  (selective receive, `atomics`, `persistent_term`, file operations). Gleam
  has no public API for these.
- `factory_name`, which relies on a `Name` being an atom. gleam_erlang's
  documentation of `Name` states that.
- Proposing changes to gleam_erlang.

## Issues

- `issues/01-the-store-is-sent-to-in-gleam-erlangs-named-form.md`
- `issues/02-await-or-shutdown-takes-a-subject-apart.md`
- `issues/03-eight-foreign-functions-need-no-erlang.md`
