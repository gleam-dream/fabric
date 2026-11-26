-module(fabric_test_ffi).
-export([temp_dir/0, remove_dir/1, list_dir/1, write_file/2, read_file/1, age_file/2, waits_on/2, waits_in/2,
         suspend/1, resume/1, queued/1, leasing/0, while_leasing/1, linked/1,
         raise_atom/1, raise_tagged/1, store_sentinel/1,
         monitored_by_self/1]).

%% A fresh, empty directory under the system temporary directory.
temp_dir() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end,
    Name = "fabric-test-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase)),
    Path = filename:join(Base, Name),
    ok = file:make_dir(Path),
    unicode:characters_to_binary(Path).

remove_dir(Path) ->
    _ = file:del_dir_r(Path),
    nil.

list_dir(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> {ok, lists:sort([unicode:characters_to_binary(N) || N <- Names])};
        {error, _} -> {error, nil}
    end.

write_file(Path, Bin) ->
    case file:write_file(Path, Bin) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

age_file(Path, Seconds) ->
    Then = erlang:system_time(second) - Seconds,
    case file:change_time(Path, calendar:system_time_to_local_time(Then, second)) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

waits_on(Pid, Target) ->
    case erlang:process_info(Pid, [status, monitors]) of
        [{status, waiting}, {monitors, Monitors}] ->
            lists:member({process, Target}, Monitors);
        _ -> false
    end.

%% Whether Pid is blocked in a receive that Module's code entered directly:
%% the innermost frame of its stack outside gleam_erlang is Module's.
waits_in(Pid, Module) ->
    case erlang:process_info(Pid, [status, current_stacktrace]) of
        [{status, waiting}, {current_stacktrace, Frames}] ->
            case [M || {M, _, _, _} <- Frames,
                       M =/= gleam_erlang_ffi, M =/= 'gleam@erlang@process'] of
                [Module | _] -> true;
                _ -> false
            end;
        _ -> false
    end.

suspend(Pid) ->
    true = erlang:suspend_process(Pid),
    nil.

resume(Pid) ->
    true = erlang:resume_process(Pid),
    nil.

queued(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> 0
    end.

%% Whether `fabric/support.store` makes leased stores in this process.
leasing() ->
    get(fabric_test_leasing) =:= true.

while_leasing(Body) -> while_set(fabric_test_leasing, Body).

%% Runs Body with the process dictionary flag Key set, and restores the
%% flag's earlier value however Body ends, a failed assertion included, so
%% that one failing test cannot leave the flag set for later tests run by
%% the same process.
while_set(Key, Body) ->
    Earlier = put(Key, true),
    try Body() of
        _ -> nil
    after
        case Earlier of
            undefined -> erase(Key);
            _ -> put(Key, Earlier)
        end
    end.

%% The processes linked to Pid, other than the caller.
linked(Pid) ->
    case erlang:process_info(Pid, links) of
        {links, Links} -> [L || L <- Links, is_pid(L), L =/= self()];
        undefined -> []
    end.

%% Raises an atom made from Text, as code that turns data into an atom does.
raise_atom(Text) ->
    erlang:error(binary_to_atom(Text)).

%% Raises a tuple tagged with an atom made from Text.
raise_tagged(Text) ->
    erlang:error({binary_to_atom(Text), Text}).

%% The sentinel of the store subtree whose store process is StorePid: the
%% worker of the same supervisor that `fabric/internal/store` spawned in
%% `sentinel`.
store_sentinel(StorePid) ->
    {dictionary, Dictionary} = erlang:process_info(StorePid, dictionary),
    [Supervisor | _] = proplists:get_value('$ancestors', Dictionary),
    [Sentinel] = [Pid || {_, Pid, worker, _} <- supervisor:which_children(Supervisor),
                         is_pid(Pid), is_sentinel(Pid)],
    Sentinel.

is_sentinel(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            case proplists:get_value('$initial_call', Dictionary) of
                {'fabric@internal@store', Function, _} ->
                    lists:prefix("-sentinel/", atom_to_list(Function));
                _ -> false
            end;
        undefined -> false
    end.

%% Whether Pid is alive and monitored by the caller. The query is a signal
%% to Pid, answered after Pid has taken the caller's earlier signals, such
%% as a monitor.
monitored_by_self(Pid) ->
    case erlang:process_info(Pid, monitored_by) of
        {monitored_by, Monitors} -> lists:member(self(), Monitors);
        undefined -> false
    end.
