-module(fabric_test_ffi).
-export([temp_dir/0, remove_dir/1, list_dir/1, write_file/2]).

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
