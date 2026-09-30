-module(fabric_mcp_stdio).
-export([start/5, request/4, stop/1]).

%% A connection outlives request tasks, but never its application owner.
start(Command, Args, Env, MaxBytes, MaxNotifications) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Owner = monitor(process, Parent),
        case open(Command, Args, Env, MaxBytes) of
            {ok, Port} ->
                Parent ! {Ref, {ok, self()}},
                try loop(Port, Owner, 1, MaxBytes, MaxNotifications, MaxNotifications)
                after catch port_close(Port) end;
            error -> Parent ! {Ref, {error, <<"could not start MCP stdio server">>}}
        end
    end),
    receive
        {Ref, Reply} -> demonitor(Mon, [flush]), Reply;
        {'DOWN', Mon, process, Pid, _} -> {error, <<"MCP connection failed to start">>}
    after 5000 ->
        exit(Pid, kill), demonitor(Mon, [flush]),
        {error, <<"MCP connection startup timed out">>}
    end.

open(Command, Args, Env, MaxBytes) ->
    try
        Executable = case os:find_executable(binary_to_list(Command)) of
            false -> error(executable_not_found);
            Path -> Path
        end,
        {ok, open_port({spawn_executable, Executable}, [binary, exit_status,
            {line, MaxBytes}, {args, [binary_to_list(A) || A <- Args]},
            {env, [{binary_to_list(K), binary_to_list(V)} || {K,V} <- Env]}])}
    catch _:_ -> error end.

request(Pid, Method, Params, Timeout) ->
    case is_process_alive(Pid) of
        false -> {error, {before_send, <<"MCP connection is closed">>}};
        true -> request_live(Pid, Method, Params, Timeout)
    end.

request_live(Pid, Method, Params, Timeout) ->
    Ref = alias(), Mon = monitor(process, Pid),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Pid ! {request, self(), Ref, Method, Params, Deadline},
    try receive
        {Ref, Reply} -> Reply;
        {'DOWN', Mon, process, Pid, _} -> {error, {after_send, <<"MCP connection was lost; dispatch is unknown">>}}
    after min(4294967295, Timeout + 1000) ->
        Pid ! {abandon, self(), Ref},
        {error, {after_send, <<"MCP request acknowledgement timed out">>}}
    end after unalias(Ref), demonitor(Mon, [flush]) end.

stop(Pid) ->
    Mon = monitor(process, Pid), Pid ! stop,
    receive {'DOWN', Mon, process, Pid, _} -> nil
    after 5000 -> exit(Pid, kill), demonitor(Mon, [flush]), nil
    end.

loop(Port, Owner, NextId, MaxBytes, MaxNotifications, IdleNotes) ->
    receive
        {'DOWN', Owner, process, _, _} -> ok;
        stop -> ok;
        {Port, {exit_status, _}} -> ok;
        {Port, {data, {eol, Line}}} when byte_size(Line) =< MaxBytes, IdleNotes > 0 ->
            case 'fabric_mcp@client':admit_frame(Line) of
                notification -> loop(Port, Owner, NextId, MaxBytes, MaxNotifications, IdleNotes-1);
                {reply, Old, _} when Old < NextId -> loop(Port, Owner, NextId, MaxBytes, MaxNotifications, IdleNotes-1);
                _ -> ok
            end;
        {Port, {data, _}} -> ok;
        {abandon, _, _} -> loop(Port, Owner, NextId, MaxBytes, MaxNotifications, IdleNotes);
        {request, Caller, Ref, Method, Params, Deadline} ->
            CallerMon = monitor(process, Caller),
            Body = iolist_to_binary([<<"{\"jsonrpc\":\"2.0\",\"id\":" >>,
                integer_to_binary(NextId), <<",\"method\":" >>, json:encode(Method),
                <<",\"params\":" >>, Params, <<"}\n">>]),
            Result = case {is_process_alive(Caller), left(Deadline), byte_size(Body) =< MaxBytes, NextId =< 9007199254740991} of
                {false, _, _, _} -> {reply, {error, {before_send, <<"request owner exited before dispatch">>}}};
                {_, Remaining, _, _} when Remaining =< 0 -> {reply, {error, {before_send, <<"deadline expired before dispatch">>}}};
                {_, _, false, _} -> {reply, {error, {before_send, <<"request exceeds byte limit">>}}};
                {_, _, _, false} -> {broken, {before_send, <<"MCP request ID range exhausted">>}};
                {true, _, true, true} ->
                    case catch port_command(Port, Body, [nosuspend]) of
                        true -> wait(Port, Owner, CallerMon, Caller, Ref, NextId, Deadline, MaxBytes, MaxNotifications);
                        false -> {reply, {error, {before_send, <<"MCP output is busy">>}}};
                        _ -> {broken, {after_send, <<"could not confirm request dispatch">>}}
                    end
            end,
            demonitor(CallerMon, [flush]),
            case Result of
                {reply, Reply} -> Ref ! {Ref, Reply}, loop(Port, Owner, NextId+1, MaxBytes, MaxNotifications, MaxNotifications);
                {broken, Reason} -> Ref ! {Ref, {error, Reason}};
                stop -> ok
            end
    end.

wait(Port, Owner, CallerMon, Caller, Ref, Id, Deadline, MaxBytes, LeftNotes) ->
    Remaining = left(Deadline),
    case Remaining =< 0 of
        true -> expire(Port, Id);
        false -> receive
            {'DOWN', Owner, process, _, _} -> cancel(Port, Id), stop;
            {'DOWN', CallerMon, process, Caller, _} -> cancel(Port, Id), {reply, {error, {after_send, <<"request owner exited">>}}};
            {abandon, Caller, Ref} -> cancel(Port, Id), {reply, {error, {after_send, <<"request abandoned">>}}};
            stop -> cancel(Port, Id), stop;
            {Port, {exit_status, _}} -> {broken, {after_send, <<"MCP server exited before its response">>}};
            {Port, {data, {eol, Line}}} when byte_size(Line) =< MaxBytes ->
                Frame = 'fabric_mcp@client':admit_frame(Line),
                case left(Deadline) > 0 of
                    false -> expire(Port, Id);
                    true -> case Frame of
                        {reply, Id, Reply} -> {reply, Reply};
                        {reply, Old, _} when Old < Id, LeftNotes > 0 ->
                            wait(Port, Owner, CallerMon, Caller, Ref, Id, Deadline, MaxBytes, LeftNotes-1);
                        notification when LeftNotes > 0 ->
                            wait(Port, Owner, CallerMon, Caller, Ref, Id, Deadline, MaxBytes, LeftNotes-1);
                        {invalid_frame, Reason} -> {broken, {invalid_response, Reason}};
                        _ -> cancel(Port, Id), {broken, {after_send, <<"MCP correlation or ignored message limit exceeded">>}}
                    end
                end;
            {Port, {data, _}} -> {broken, {after_send, <<"response exceeds line byte limit">>}}
        after Remaining -> expire(Port, Id)
        end
    end.

expire(Port, Id) ->
    cancel(Port, Id), {reply, {error, {after_send, <<"MCP response deadline exceeded">>}}}.

cancel(Port, Id) ->
    Body = iolist_to_binary(json:encode(#{<<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/cancelled">>,
        <<"params">> => #{<<"requestId">> => Id, <<"reason">> => <<"caller stopped waiting">>}})),
    catch port_command(Port, <<Body/binary, "\n">>, [nosuspend]), ok.

left(Deadline) -> Deadline - erlang:monotonic_time(millisecond).
