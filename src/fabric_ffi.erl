-module(fabric_ffi).
-export([rescue/1, random_id/0, now_ms/0]).

%% Runs Body, turning any raised exception into {error, Description}.
rescue(Body) ->
    try {ok, Body()}
    catch Class:Reason ->
        {error, unicode:characters_to_binary(io_lib:format("~p: ~P", [Class, Reason, 20]))}
    end.

%% 128 random bits as lowercase hex; unique across VM restarts.
random_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

%% Monotonic milliseconds, for deadlines.
now_ms() ->
    erlang:monotonic_time(millisecond).
