-module(fabric_postgres_test_ffi).
-export([getenv/1, read_file/1, unique/0]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, nil}
    end.

unique() ->
    erlang:unique_integer([positive]).
