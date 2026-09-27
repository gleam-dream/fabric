%% A deterministic local HTTP/SSE stub for adapter tests. It serves one
%% scripted response per accepted connection, in order, on 127.0.0.1, and
%% records every request body it read. Nothing leaves the machine.
-module(fabric_stub_ffi).
-export([start/1, requests/1]).

start(Responses) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Responses) end),
    receive
        {stub_port, Pid, Port} -> {Port, Pid}
    after 5000 -> erlang:error(stub_start_timeout)
    end.

%% Waits until every scripted response was served, then returns the bodies.
requests(Pid) ->
    Pid ! {requests, self()},
    receive
        {stub_requests, Pid, Bodies} -> Bodies
    after 10000 -> erlang:error(stub_requests_timeout)
    end.

init(Parent, Responses) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}}, {packet, raw}]),
    {ok, Port} = inet:port(Listen),
    Parent ! {stub_port, self(), Port},
    serve(Listen, Responses, []).

serve(Listen, [], Bodies) ->
    gen_tcp:close(Listen),
    hold(lists:reverse(Bodies));
serve(Listen, [Response | Rest], Bodies) ->
    {ok, Socket} = gen_tcp:accept(Listen, 10000),
    Body = read_request(Socket, <<>>),
    Head = <<"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
             "Cache-Control: no-cache\r\nConnection: close\r\n\r\n">>,
    ok = gen_tcp:send(Socket, <<Head/binary, Response/binary>>),
    ok = gen_tcp:close(Socket),
    serve(Listen, Rest, [Body | Bodies]).

hold(Bodies) ->
    receive
        {requests, From} ->
            From ! {stub_requests, self(), Bodies},
            hold(Bodies)
    end.

read_request(Socket, Buffer) ->
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Headers, Rest] -> read_body(Socket, headers(Headers), Rest);
        [_] ->
            {ok, More} = gen_tcp:recv(Socket, 0, 10000),
            read_request(Socket, <<Buffer/binary, More/binary>>)
    end.

headers(Raw) ->
    [_RequestLine | Lines] = binary:split(Raw, <<"\r\n">>, [global]),
    [{string:lowercase(string:trim(K)), string:trim(V)}
     || Line <- Lines, [K, V] <- [binary:split(Line, <<":">>)]].

read_body(Socket, Headers, Body) ->
    case proplists:get_value(<<"content-length">>, Headers) of
        undefined -> read_chunked(Socket, Body);
        Length -> read_exact(Socket, binary_to_integer(Length), Body)
    end.

read_exact(_Socket, Length, Body) when byte_size(Body) >= Length -> Body;
read_exact(Socket, Length, Body) ->
    {ok, More} = gen_tcp:recv(Socket, 0, 10000),
    read_exact(Socket, Length, <<Body/binary, More/binary>>).

read_chunked(Socket, Raw) ->
    case binary:match(Raw, <<"0\r\n\r\n">>) of
        nomatch ->
            {ok, More} = gen_tcp:recv(Socket, 0, 10000),
            read_chunked(Socket, <<Raw/binary, More/binary>>);
        _ -> dechunk(Raw, <<>>)
    end.

dechunk(Raw, Acc) ->
    [SizeLine, Rest] = binary:split(Raw, <<"\r\n">>),
    case binary_to_integer(string:trim(SizeLine), 16) of
        0 -> Acc;
        Size ->
            <<Chunk:Size/binary, "\r\n", Tail/binary>> = Rest,
            dechunk(Tail, <<Acc/binary, Chunk/binary>>)
    end.
