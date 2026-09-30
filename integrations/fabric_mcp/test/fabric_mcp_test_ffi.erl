-module(fabric_mcp_test_ffi).
-export([temp_dir/0, remove_dir/1]).

temp_dir() ->
    Path = filename:join(os:getenv("TMPDIR", "/tmp"), "fabric-mcp-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    ok = file:make_dir(Path), list_to_binary(Path).

remove_dir(Path) -> ok = file:del_dir_r(Path), nil.
