-module(fabric_oracle_ffi).
-export([read_file/1]).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.
