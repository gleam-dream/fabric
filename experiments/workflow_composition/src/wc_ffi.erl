%% THROWAWAY (workflow composition experiment): contain a callback crash.
-module(wc_ffi).
-export([rescue/1]).

rescue(F) ->
    try {ok, F()}
    catch Class:Reason -> {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.
