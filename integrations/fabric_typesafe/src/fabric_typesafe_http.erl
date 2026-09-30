-module(fabric_typesafe_http).
-export([request/7]).

request(Host, Port, Path, Tls, Key, Body, {bounds, Timeout, _, MaxBody, MaxHeaders}) ->
    Owner = self(), Reply = alias(),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    {Worker, Monitor} = spawn_monitor(fun() ->
        OwnerMonitor = monitor(process, Owner),
        Result = try
            {ok, _} = application:ensure_all_started(gun),
            open(Host, Port, Path, Tls, Key, Body, Deadline, MaxBody, MaxHeaders, OwnerMonitor)
        catch _:_ -> {error, {after_send, <<"classifier transport failed; dispatch is unknown">>}}
        end,
        Reply ! {Reply, Result}
    end),
    try receive
        {Reply, Result} -> Result;
        {'DOWN', Monitor, process, Worker, _} -> {error, {after_send, <<"classifier transport owner exited; dispatch is unknown">>}}
    after Timeout + 1000 ->
        exit(Worker, kill), {error, {after_send, <<"classifier request deadline exceeded; dispatch is unknown">>}}
    end after unalias(Reply), demonitor(Monitor, [flush]) end.

open(Host, Port, Path, Tls, Key, Body, Deadline, MaxBody, MaxHeaders, OwnerMonitor) ->
    TlsOptions = case Tls of
        true -> [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
            {server_name_indication, binary_to_list(Host)},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}];
        false -> []
    end,
    Options = #{transport => case Tls of true -> tls; false -> tcp end,
        protocols => [http], retry => 0, tls_opts => TlsOptions,
        connect_timeout => remaining(Deadline), tls_handshake_timeout => remaining(Deadline),
        http_opts => #{max_headers => 100, max_header_block_size => MaxHeaders, max_trailer_block_size => MaxHeaders}},
    case gun:open(binary_to_list(Host), Port, Options) of
        {error, _} -> {error, {before_send, <<"classifier connection could not start">>}};
        {ok, Connection} ->
            Monitor = monitor(process, Connection),
            try
                case await_up(Connection, Monitor, OwnerMonitor, Deadline) of
                    ok ->
                        Stream = gun:post(Connection, Path, [
                            {<<"authorization">>, <<"Bearer ", Key/binary>>},
                            {<<"content-type">>, <<"application/json">>},
                            {<<"accept">>, <<"application/json">>},
                            {<<"accept-encoding">>, <<"identity">>}
                        ], Body, #{flow => 1}),
                        headers(Connection, Stream, Monitor, OwnerMonitor, Deadline, MaxBody, MaxHeaders, 8);
                    Error -> Error
                end
            after gun:close(Connection), demonitor(Monitor, [flush]) end
    end.

await_up(Connection, Monitor, Owner, Deadline) ->
    receive
        {gun_up, Connection, http} ->
            case remaining(Deadline) > 0 of true -> ok; false -> {error, {before_send, <<"classifier connection deadline expired">>}} end;
        {'DOWN', Owner, process, _, _} -> {error, {before_send, <<"classifier caller exited before dispatch">>}};
        {'DOWN', Monitor, process, Connection, _} -> {error, {before_send, <<"classifier connection failed before dispatch">>}}
    after remaining(Deadline) -> {error, {before_send, <<"classifier connection deadline expired">>}}
    end.

headers(Connection, Stream, Monitor, Owner, Deadline, MaxBody, MaxHeaders, Notices) ->
    case remaining(Deadline) of
    0 -> {error, {after_send, <<"classifier response deadline exceeded">>}};
    _ -> receive
        {gun_response, Connection, Stream, Fin, Status, Headers} ->
            Size = lists:sum([byte_size(K) + byte_size(V) + 4 || {K,V} <- Headers]),
            case Size =< MaxHeaders andalso remaining(Deadline) > 0 of
                true -> case Fin of
                    fin -> {ok, {response, Status, Headers, <<>>}};
                    nofin -> body(Connection, Stream, Monitor, Owner, Deadline, MaxBody, Status, Headers, [], 0)
                end;
                false -> {error, {after_send, <<"classifier header bound or deadline exceeded">>}}
            end;
        {gun_inform, Connection, Stream, _, _} when Notices > 0 -> headers(Connection, Stream, Monitor, Owner, Deadline, MaxBody, MaxHeaders, Notices-1);
        {gun_inform, Connection, Stream, _, _} -> {error, {after_send, <<"classifier informational response limit exceeded">>}};
        {'DOWN', Owner, process, _, _} -> {error, {after_send, <<"classifier caller exited after dispatch">>}};
        {'DOWN', Monitor, process, Connection, _} -> {error, {after_send, <<"classifier connection ended after dispatch">>}};
        {gun_error, Connection, Stream, _} -> {error, {after_send, <<"classifier HTTP stream failed">>}};
        {gun_error, Connection, _} -> {error, {after_send, <<"classifier HTTP connection failed">>}}
    after remaining(Deadline) -> {error, {after_send, <<"classifier response deadline exceeded">>}}
    end end.

body(Connection, Stream, Monitor, Owner, Deadline, MaxBody, Status, Headers, Chunks, Size) ->
    receive
        {gun_data, Connection, Stream, Fin, Chunk} ->
            NextSize = Size + byte_size(Chunk),
            case NextSize =< MaxBody andalso remaining(Deadline) > 0 of
                false -> {error, {after_send, <<"classifier body bound or deadline exceeded">>}};
                true -> case Fin of
                    fin -> {ok, {response, Status, Headers, iolist_to_binary(lists:reverse([Chunk|Chunks]))}};
                    nofin ->
                        gun:update_flow(Connection, Stream, 1),
                        body(Connection, Stream, Monitor, Owner, Deadline, MaxBody, Status, Headers, [Chunk|Chunks], NextSize)
                end
            end;
        {gun_trailers, Connection, Stream, _} ->
            case remaining(Deadline) > 0 of
                true -> {ok, {response, Status, Headers, iolist_to_binary(lists:reverse(Chunks))}};
                false -> {error, {after_send, <<"classifier response deadline exceeded">>}}
            end;
        {'DOWN', Owner, process, _, _} -> {error, {after_send, <<"classifier caller exited after dispatch">>}};
        {'DOWN', Monitor, process, Connection, _} -> {error, {after_send, <<"classifier body ended prematurely">>}};
        {gun_error, Connection, Stream, _} -> {error, {after_send, <<"classifier body stream failed">>}};
        {gun_error, Connection, _} -> {error, {after_send, <<"classifier HTTP connection failed">>}}
    after remaining(Deadline) -> {error, {after_send, <<"classifier response deadline exceeded">>}}
    end.

remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).
