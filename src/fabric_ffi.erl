-module(fabric_ffi).
-export([rescue/1, random_id/0, now_ms/0, ensure_directory/1, directory_get/2,
         directory_insert/3, directory_compare_and_set/4]).

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
        ok -> {ok, nil};
        {error, Reason} -> {error, describe(Reason)}
    end.

directory_get(Root, Run) ->
    with_run(Run, fun() ->
        Dir = filename:join(Root, Run),
        case latest(Dir) of
            {ok, Revision} ->
                case file:read_file(revision_path(Dir, Revision)) of
                    {ok, Bin} -> {ok, {stored, Revision, Bin}};
                    {error, Reason} -> unavailable(Reason)
                end;
            Other -> Other
        end
    end).

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
                    ok -> {ok, nil};
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
                ok = file:close(File),
                case Written of
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

unavailable(Reason) ->
    {error, {unavailable, describe(Reason)}}.

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
