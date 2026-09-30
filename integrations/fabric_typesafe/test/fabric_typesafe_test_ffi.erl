-module(fabric_typesafe_test_ffi).
-export([start_server/0, stop_server/1, temp_dir/0, remove_dir/1]).

start_server() ->
    Python = os:find_executable("python3"),
    Port = open_port({spawn_executable, Python}, [binary, exit_status, {line, 1024},
        {args, ["-B", "-u", "test/support/server.py"]}]),
    receive {Port, {data, {eol, Url}}} -> {Port, Url}
    after 5000 -> port_close(Port), error(fixture_start_timeout) end.

stop_server(Port) ->
    port_command(Port, <<"stop\n">>),
    receive {Port, {data, {eol, <<"stopped">>}}} -> catch port_close(Port), nil
    after 5000 -> catch port_close(Port), error(fixture_stop_timeout) end.

temp_dir() ->
    Path = filename:join(os:getenv("TMPDIR", "/tmp"), "fabric-classifier-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    ok = file:make_dir(Path), list_to_binary(Path).
remove_dir(Path) -> ok = file:del_dir_r(Path), nil.
