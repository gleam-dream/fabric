-module(fabric_copy_ffi).
-export([crossing/1, flat_bytes/1, counter/0, count/1]).

%% The bytes Term occupies when copied to another process: its flat size
%% in words times the word size. Off-heap binaries are shared, not copied,
%% and so not counted.
flat_bytes(Term) ->
    erts_debug:flat_size(Term) * erlang:system_info(wordsize).

%% Runs Body and returns {Result, IntoRunners, Largest}, measured over the
%% caller and every process started while Body runs (helpers, runners,
%% their tasks and the processes those start):
%%
%% - IntoRunners: the bytes copied into runner processes, the closures
%%   they were started with and every message sent to one. A runner is a
%%   process its store's runner factory started.
%% - Largest: the largest single copy of all, message or start closure,
%%   into any process, so that a whole agent copied on any path shows.
crossing(Body) ->
    Tracer = spawn(fun() -> collect([]) end),
    Flags = [send, procs, {tracer, Tracer}],
    erlang:trace(self(), true, Flags),
    erlang:trace(new_processes, true, Flags),
    Result = try Body() after
        erlang:trace(new_processes, false, [send, procs]),
        erlang:trace(all, false, [send, procs])
    end,
    %% Every trace message sent before tracing stopped reaches the tracer
    %% before this request does.
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    Tracer ! {events, self()},
    Events = receive {crossed, Collected} -> Collected end,
    Runners = [Pid || {start, Pid, true, _} <- Events],
    IntoRunners = lists:sum(
        [Bytes || {start, _, true, Bytes} <- Events] ++
        [Bytes || {send, To, Bytes} <- Events, lists:member(To, Runners)]),
    Largest = lists:max([0 | [Bytes || {start, _, _, Bytes} <- Events] ++
                             [Bytes || {send, _, Bytes} <- Events]]),
    {Result, IntoRunners, Largest}.

%% Sizes are taken as events arrive, and whether a started process is a
%% runner while its parent still runs.
collect(Events) ->
    receive
        {trace, _, send, Message, To} ->
            collect([{send, To, flat_bytes(Message)} | Events]);
        {trace, Pid, spawned, Parent, {_, _, Arguments}} ->
            collect([{start, Pid, is_factory(Parent), flat_bytes(Arguments)} | Events]);
        {events, Caller} -> Caller ! {crossed, Events};
        _ -> collect(Events)
    end.

is_factory(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            proplists:get_value('$initial_call', Dictionary) =:=
                {supervisor, 'gleam@otp@factory_supervisor', 1};
        undefined -> false
    end.

%% A counter shared by every process that holds it.
counter() -> atomics:new(1, []).

%% Adds one to Counter and returns its new value.
count(Counter) -> atomics:add_get(Counter, 1, 1).
