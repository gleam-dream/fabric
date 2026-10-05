-module(fabric_postgres_peer_test_ffi).
-export([with_peer/1, start_run/3, kill_peer/1]).

%% The control channel is stdio. Neither VM joins Erlang distribution.
with_peer(Body) ->
    Paths = lists:append([["-pa", filename:absname(Path)]
                         || Path <- code:get_path(), Path =/= "."]),
    {ok, Peer, _Node} = peer:start(#{connection => standard_io,
                                   args => Paths,
                                   peer_down => stop}),
    try
        nonode@nohost = peer:call(Peer, erlang, node, []),
        [] = peer:call(Peer, erlang, nodes, []),
        {ok, _} = peer:call(Peer, application, ensure_all_started, [pog]),
        OsPid = peer:call(Peer, os, getpid, []),
        true = lists:all(fun(C) -> C >= $0 andalso C =< $9 end, OsPid),
        true = list_to_integer(OsPid) > 1,
        false = OsPid =:= os:getpid(),
        Body({Peer, OsPid})
    after
        %% Also clean up when a Gleam assertion fails before SIGKILL.
        catch peer:stop(Peer)
    end.

start_run({Peer, _OsPid}, Schema, Lease) ->
    peer:call(Peer, 'fabric_postgres@peer_test', start_owned_run,
              [Schema, Lease], 60000).

kill_peer({Peer, OsPid}) ->
    Monitor = erlang:monitor(process, Peer),
    %% OsPid was obtained from this peer and validated in with_peer/1.
    %% spawn_executable passes it as one argument without invoking a shell.
    Kill = case os:find_executable("kill") of
        false -> error(kill_executable_not_found);
        Executable -> Executable
    end,
    Port = open_port({spawn_executable, Kill},
                     [exit_status, {args, ["-KILL", OsPid]}]),
    receive
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} -> error({kill_failed, Status})
    after 5000 ->
        error(kill_timeout)
    end,
    receive
        {'DOWN', Monitor, process, Peer, _Reason} -> nil
    after 5000 ->
        erlang:demonitor(Monitor, [flush]),
        error(peer_survived_sigkill)
    end.
