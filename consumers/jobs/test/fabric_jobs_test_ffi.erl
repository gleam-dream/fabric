-module(fabric_jobs_test_ffi).
-export([getenv/1, temp_dir/0, remove_dir/1, sha256/1]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

temp_dir() ->
    Base = os:getenv("FABRIC_JOBS_TMP"),
    Path = filename:join(Base, integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = file:make_dir(Path),
    unicode:characters_to_binary(Path).

remove_dir(Path) ->
    ok = file:del_dir_r(Path),
    nil.

sha256(Text) ->
    string:lowercase(binary:encode_hex(crypto:hash(sha256, Text))).
