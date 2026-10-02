-module(fabric_fake_provider_ffi).
-export([start/1, url/1, requests/1, remaining/1, stop/1]).

%% A loopback HTTP/1.1 provider for tests. Each connection carries one
%% request; replies are served in order as chunked bodies. A reply whose
%% `Complete` is false closes before the final chunk (a transport failure).
%% An exhausted script records the request and closes without a response.

start(Replies) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
                                      {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Server = spawn(fun() -> serve(Replies, []) end),
    Acceptor = spawn(fun() -> receive go -> accept(Listen, Server) end end),
    ok = gen_tcp:controlling_process(Listen, Acceptor),
    Acceptor ! go,
    {fake_provider, Server, Acceptor, Port}.

url({fake_provider, _, _, Port}) ->
    <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>.

requests({fake_provider, Server, _, _}) -> ask(Server, requests).

remaining({fake_provider, Server, _, _}) -> ask(Server, remaining).

stop({fake_provider, Server, Acceptor, _}) ->
    exit(Acceptor, kill),
    Server ! stop,
    nil.

ask(Server, Tag) ->
    Ref = make_ref(),
    Server ! {Tag, self(), Ref},
    receive {Ref, Value} -> Value
    after 5000 -> error(fake_provider_timeout)
    end.

serve(Replies, Seen) ->
    receive
        {next, From, Ref, Request} ->
            {Reply, Rest} = case Replies of
                [Next | Tail] -> {Next, Tail};
                [] -> {exhausted, []}
            end,
            From ! {Ref, Reply},
            serve(Rest, [Request | Seen]);
        {requests, From, Ref} ->
            From ! {Ref, lists:reverse(Seen)},
            serve(Replies, Seen);
        {remaining, From, Ref} ->
            From ! {Ref, length(Replies)},
            serve(Replies, Seen);
        stop ->
            ok
    end.

accept(Listen, Server) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> receive go -> handle(Socket, Server) end end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! go,
            accept(Listen, Server);
        {error, _} ->
            ok
    end.

handle(Socket, Server) ->
    case read_request(Socket) of
        {ok, Request} ->
            Ref = make_ref(),
            Server ! {next, self(), Ref, Request},
            receive {Ref, Reply} -> respond(Socket, Reply)
            after 5000 -> ok
            end;
        error ->
            ok
    end,
    gen_tcp:close(Socket).

read_request(Socket) ->
    ok = inet:setopts(Socket, [{packet, http_bin}]),
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_request, _Method, {abs_path, Path}, _Version}} ->
            Headers = headers(Socket, []),
            ok = inet:setopts(Socket, [{packet, raw}]),
            {ok, {Path, body(Socket, Headers)}};
        _ ->
            error
    end.

headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_header, _, Name, _, Value}} ->
            headers(Socket, [{header_name(Name), Value} | Acc]);
        _ ->
            Acc
    end.

header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) -> string:lowercase(Name).

body(Socket, Headers) ->
    case proplists:get_value(<<"transfer-encoding">>, Headers) of
        undefined ->
            case proplists:get_value(<<"content-length">>, Headers) of
                undefined -> <<>>;
                <<"0">> -> <<>>;
                Length ->
                    {ok, Body} = gen_tcp:recv(Socket, binary_to_integer(Length), 10000),
                    Body
            end;
        _ ->
            chunked(Socket, <<>>)
    end.

chunked(Socket, Acc) ->
    ok = inet:setopts(Socket, [{packet, line}]),
    {ok, Line} = gen_tcp:recv(Socket, 0, 10000),
    [Hex | _] = binary:split(string:trim(Line), <<";">>),
    ok = inet:setopts(Socket, [{packet, raw}]),
    case binary_to_integer(Hex, 16) of
        0 ->
            {ok, _} = gen_tcp:recv(Socket, 2, 10000),
            Acc;
        Size ->
            {ok, Data} = gen_tcp:recv(Socket, Size, 10000),
            {ok, _} = gen_tcp:recv(Socket, 2, 10000),
            chunked(Socket, <<Acc/binary, Data/binary>>)
    end.

respond(_Socket, exhausted) ->
    ok;
respond(Socket, {Status, Chunks, Complete}) ->
    ok = gen_tcp:send(Socket, [
        <<"HTTP/1.1 ">>, integer_to_binary(Status),
        <<" Fake\r\ncontent-type: text/event-stream\r\n">>,
        <<"transfer-encoding: chunked\r\nconnection: close\r\n\r\n">>
    ]),
    lists:foreach(fun(Chunk) ->
        gen_tcp:send(Socket, [integer_to_binary(byte_size(Chunk), 16),
                              <<"\r\n">>, Chunk, <<"\r\n">>])
    end, [Chunk || Chunk <- Chunks, Chunk =/= <<>>]),
    case Complete of
        true -> gen_tcp:send(Socket, <<"0\r\n\r\n">>);
        false -> ok
    end.
