-module(fabric_writing_ffi).
-export([read/1, publish/3, environment/1, now/0]).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} when byte_size(Bytes) =< 16384 ->
            case unicode:characters_to_binary(Bytes) of
                Text when is_binary(Text) -> {ok, Text};
                _ -> {error, <<"source is not UTF-8">>}
            end;
        {ok, _} -> {error, <<"source exceeds 16 KiB">>};
        {error, Reason} -> problem(Reason)
    end.

publish(Directory, Key, Body) ->
    case re:run(Key, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) of
        match ->
            Path = filename:join(Directory, <<Key/binary, ".md">>),
            case filelib:ensure_dir(Path) of
                ok -> store_once(Path, Body);
                {error, Reason} -> problem(Reason)
            end;
        nomatch -> {error, <<"invalid artifact key">>}
    end.

store_once(Path, Body) ->
    case file:read_file(Path) of
        {ok, Body} -> receipt(Path, Body);
        {ok, _} -> {error, <<"artifact key already has different content">>};
        {error, enoent} ->
            Suffix = binary:encode_hex(crypto:strong_rand_bytes(12)),
            Temporary = <<Path/binary, ".", Suffix/binary, ".tmp">>,
            try
                case file:open(Temporary, [write, binary, raw, exclusive]) of
                    {ok, File} ->
                        Written = try
                            case file:write(File, Body) of
                                ok -> file:sync(File);
                                Error -> Error
                            end
                        after file:close(File) end,
                        case Written of
                            ok ->
                                case file:make_link(Temporary, Path) of
                                    ok -> receipt(Path, Body);
                                    {error, eexist} -> store_once(Path, Body);
                                    {error, Reason} -> problem(Reason)
                                end;
                            {error, Reason} -> problem(Reason)
                        end;
                    {error, Reason} -> problem(Reason)
                end
            after file:delete(Temporary) end;
        {error, Reason} -> problem(Reason)
    end.

receipt(Path, Body) ->
    {ok, {artifact, Path, binary:encode_hex(crypto:hash(sha256, Body))}}.

problem(Reason) -> {error, atom_to_binary(Reason, utf8)}.

environment(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
now() -> erlang:monotonic_time(millisecond).
