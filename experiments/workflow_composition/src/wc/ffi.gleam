//// THROWAWAY (workflow composition experiment).

/// Runs `f`, turning any raised exception into `Error(description)`.
@external(erlang, "wc_ffi", "rescue")
pub fn rescue(f: fn() -> a) -> Result(a, String)
