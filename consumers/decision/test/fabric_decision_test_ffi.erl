-module(fabric_decision_test_ffi).
-export([start_server/0, stop_server/1]).

start_server() ->
    Python = os:find_executable("python3"),
    Port = open_port({spawn_executable, Python}, [binary, exit_status, {line, 1024},
        {args, ["-B", "-u", "../../integrations/fabric_typesafe/test/support/server.py"]}]),
    receive {Port, {data, {eol, Url}}} -> {Port, Url}
    after 5000 -> port_close(Port), error(fixture_start_timeout) end.

stop_server(Port) ->
    port_command(Port, <<"stop\n">>),
    receive {Port, {data, {eol, <<"stopped">>}}} -> catch port_close(Port), nil
    after 5000 -> catch port_close(Port), error(fixture_stop_timeout) end.
