-module(fabric_test_ffi).
-export([temp_dir/0, remove_dir/1, list_dir/1, write_file/2, read_file/1, age_file/2, waits_on/2,
         suspend/1, resume/1, queued/1]).

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
