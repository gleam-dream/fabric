-module(fabric_writing_test_ffi).
-export([temp_dir/0, write_file/2, remove_dir/1]).
temp_dir() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "fabric-writing-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    unicode:characters_to_binary(Dir).
write_file(Path, Text) ->
    case file:write_file(Path, Text) of ok -> {ok, nil}; _ -> {error, nil} end.
remove_dir(Path) -> file:del_dir_r(Path), nil.
