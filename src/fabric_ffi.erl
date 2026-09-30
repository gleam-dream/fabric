-module(fabric_ffi).
-export([rescue/1, random_id/0, now_ms/0, ensure_directory/1, directory_get/2,
         directory_insert/3, directory_compare_and_set/4, claim_new/0,
         claim_take/2, exit_shutdown/0, factory_name/1,
         await_or_shutdown/3, requeue_shutdown/1, take_shutdown/1, graph_child_id/2,
         family_budget_id/1, system_time_ms/0]).

family_budget_id(Root) ->
    Hash = crypto:hash(sha256, [<<"fabric.family.budget:">>, Root]),
    <<"budget-", (binary:encode_hex(Hash))/binary>>.

graph_child_id(Parent, Activation) ->
    Hash = crypto:hash(sha256, [<<"fabric.graph.child:">>, Parent, 0, integer_to_binary(Activation)]),
    <<"graph-", (binary:encode_hex(Hash))/binary>>.

%% Runs Body, turning any raised exception into {error, Description}.
rescue(Body) ->
    try {ok, Body()}
    catch Class:Reason ->
        {error, unicode:characters_to_binary(io_lib:format("~p: ~P", [Class, Reason, 20]))}
    end.

%% Exits the calling process with reason `shutdown`: a supervisor it
%% started stops its children in order, and no crash is logged.
exit_shutdown() ->
    exit(shutdown).

%% Waits for a message on the subject, or for the caller's own trapped exit
%% signal `shutdown` from Factory, whichever comes first within Timeout ms;
%% any other message stays queued.
await_or_shutdown({subject, _Owner, Tag}, Factory, Timeout) ->
    receive
        {Tag, Message} -> {answered, Message};
        {'EXIT', Factory, shutdown} -> shut_down
    after Timeout -> still_waiting
    end.

%% Queues the exit signal `shutdown` from Factory to the caller again, as
%% the message a process trapping exits receives.
requeue_shutdown(Factory) ->
    self() ! {'EXIT', Factory, shutdown},
    nil.

%% Takes the exit signal `shutdown` from Factory if it is queued, wherever
%% it waits in the mailbox; never waits.
take_shutdown(Factory) ->
    receive
        {'EXIT', Factory, shutdown} -> true
    after 0 -> false
    end.

%% The registered name of the runner factory of the store named Name.
factory_name(Name) ->
    binary_to_atom(<<(atom_to_binary(Name))/binary, "$runners">>).

%% 128 random bits as lowercase hex; unique across VM restarts.
random_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

%% Monotonic milliseconds, for process-local timeout durations only.
now_ms() ->
    erlang:monotonic_time(millisecond).

%% Stable UTC epoch for deadlines retained by an unleased local store.
system_time_ms() ->
    erlang:system_time(millisecond).

%% --- claims -----------------------------------------------------------------
%%
%% A claim is one atomics cell, 0 while open. claim_take(Claim, Taker) sets
%% it to Taker (1 or 2) only if it is still open, as one atomic step, and
%% says whether this call did.

claim_new() ->
    atomics:new(1, [{signed, false}]).

claim_take(Claim, Taker) ->
    atomics:compare_exchange(Claim, 1, 0, Taker) =:= ok.

%% --- the directory store ---------------------------------------------------
%%
%% <root>/<run>/<revision:20 digits>.json, one immutable file per revision.
%% A revision is published by writing and fsyncing a temporary file in the
%% run directory and hard-linking it under its revision name; the link fails
%% with eexist when that revision was already published, which makes
%% compare-and-set atomic across processes and VMs. Revisions are never
%% deleted, so a revision name, once published, is never reused.

ensure_directory(Path) ->
    case filelib:ensure_path(Path) of
        ok ->
            sweep(Path),
            {ok, nil};
        {error, Reason} -> {error, describe(Reason)}
    end.

%% Removes temporary files that a writer which crashed before publishing
%% left behind. A file younger than ten minutes may belong to a live
%% writer in another VM and is kept.
sweep(Root) ->
    Cutoff = erlang:system_time(second) - 600,
    case file:list_dir(Root) of
        {ok, Runs} ->
            lists:foreach(fun(Run) ->
                Dir = filename:join(Root, Run),
                case file:list_dir(Dir) of
                    {ok, Names} ->
                        [sweep_file(filename:join(Dir, N), Cutoff)
                         || N <- Names, lists:prefix(".tmp-", N)];
                    {error, _} -> ok
                end
            end, Runs);
        {error, _} -> ok
    end.

sweep_file(Path, Cutoff) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, Info} when element(6, Info) < Cutoff -> _ = file:delete(Path), ok;
        _ -> ok
    end.

directory_get(Root, Run) ->
    with_run(Run, fun() -> read_latest(filename:join(Root, Run), 5) end).

%% An empty revision was emptied after two newer ones were published
%% while this read was listing: list again.
read_latest(Dir, Tries) ->
    case latest(Dir) of
        {ok, Revision} ->
            case file:read_file(revision_path(Dir, Revision)) of
                {ok, <<>>} when Tries > 1 -> read_latest(Dir, Tries - 1);
                {ok, <<>>} -> unavailable(emptied_while_reading);
                {ok, Bin} -> {ok, {stored, Revision, Bin}};
                {error, Reason} -> unavailable(Reason)
            end;
        Other -> Other
    end.

directory_insert(Root, Run, Record) ->
    with_run(Run, fun() ->
        Dir = filename:join(Root, Run),
        case file:make_dir(Dir) of
            Made when Made =:= ok; Made =:= {error, eexist} ->
                case publish(Dir, 1, Record) of
                    ok -> {ok, nil};
                    exists -> {error, already_exists};
                    {error, Reason} -> unavailable(Reason)
                end;
            {error, Reason} -> unavailable(Reason)
        end
    end).

directory_compare_and_set(Root, Run, Expected, Record) ->
    with_run(Run, fun() ->
        Dir = filename:join(Root, Run),
        case latest(Dir) of
            {ok, Expected} ->
                case publish(Dir, Expected + 1, Record) of
                    ok ->
                        empty_old(Dir, Expected - 1),
                        {ok, nil};
                    exists -> conflict(Dir);
                    {error, Reason} -> unavailable(Reason)
                end;
            {ok, Current} -> {error, {conflict, Current}};
            Other -> Other
        end
    end).

with_run(Run, Body) ->
    case re:run(Run, <<"^[A-Za-z0-9_-]{1,128}$">>) of
        {match, _} -> Body();
        nomatch -> {error, {unavailable, <<"invalid run id">>}}
    end.

conflict(Dir) ->
    case latest(Dir) of
        {ok, Current} -> {error, {conflict, Current}};
        Other -> Other
    end.

latest(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            case [R || N <- Names, {ok, R} <- [revision_of(N)]] of
                [] -> {error, not_found};
                Revisions -> {ok, lists:max(Revisions)}
            end;
        {error, enoent} -> {error, not_found};
        {error, Reason} -> unavailable(Reason)
    end.

revision_of(Name) ->
    case re:run(Name, "^([0-9]{20})\\.json$", [{capture, [1], list}]) of
        {match, [Digits]} -> {ok, list_to_integer(Digits)};
        nomatch -> error
    end.

revision_path(Dir, Revision) ->
    filename:join(Dir, io_lib:format("~20..0B.json", [Revision])).

%% ok | exists | {error, Reason}
publish(Dir, Revision, Record) ->
    Temporary = filename:join(Dir, ".tmp-" ++ binary_to_list(random_id())),
    Result =
        case file:open(Temporary, [raw, binary, write, exclusive]) of
            {ok, File} ->
                Written =
                    case file:write(File, Record) of
                        ok -> file:sync(File);
                        Error -> Error
                    end,
                Closed = file:close(File),
                case first_error([Written, Closed]) of
                    ok ->
                        case file:make_link(Temporary, revision_path(Dir, Revision)) of
                            ok -> ok;
                            {error, eexist} -> exists;
                            {error, Reason} -> {error, Reason}
                        end;
                    {error, Reason} -> {error, Reason}
                end;
            {error, Reason} -> {error, Reason}
        end,
    _ = file:delete(Temporary),
    Result.

first_error(Results) ->
    case [E || {error, _} = E <- Results] of
        [] -> ok;
        [Error | _] -> Error
    end.

%% Revision names are never removed, so a stale writer can never publish
%% one again; the content of revisions older than the previous one is
%% dropped. The previous revision stays readable for a reader that listed
%% just before the latest was published.
empty_old(_Dir, Revision) when Revision < 1 -> ok;
empty_old(Dir, Revision) ->
    _ = file:write_file(revision_path(Dir, Revision), <<>>),
    ok.

unavailable(Reason) ->
    {error, {unavailable, describe(Reason)}}.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
