-module(fabric_postgres_test_ffi).
-export([getenv/1, read_file/1, unique/0, with_process/2, kill_linked/1]).

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

with_process(Pid, Work) ->
    try Work()
    after
        unlink(Pid),
        Ref = monitor(process, Pid),
        exit(Pid, shutdown),
        receive
            {'DOWN', Ref, process, Pid, _} -> ok
        after 5000 ->
            exit(Pid, kill),
            receive {'DOWN', Ref, process, Pid, _} -> ok end
        end
    end.

%% Kills Pid, as a node's VM would die, and waits until it and every process
%% it was linked to have exited: a store it started must have unregistered
%% its name before the next one starts under that name. A linked process
%% that outlives Pid by 30 seconds is left to itself.
kill_linked(Pid) ->
    Linked = case erlang:process_info(Pid, links) of
        {links, Links} -> [L || L <- Links, is_pid(L), L =/= self()];
        undefined -> []
    end,
    Refs = [monitor(process, P) || P <- [Pid | Linked]],
    exit(Pid, kill),
    Deadline = erlang:monotonic_time(millisecond) + 30000,
    lists:foreach(fun(Ref) -> await_down(Ref, Deadline) end, Refs),
    nil.

await_down(Ref, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _, _} -> ok
    after Left ->
        demonitor(Ref, [flush])
    end.
