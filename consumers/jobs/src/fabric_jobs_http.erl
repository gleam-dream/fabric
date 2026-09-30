-module(fabric_jobs_http).
-export([request/3]).

request(Method, Url, Body) ->
    {ok, _} = application:ensure_all_started(inets),
    Request = case Method of
        <<"GET">> -> {get, {binary_to_list(Url), []}};
        <<"POST">> -> {post, {binary_to_list(Url), [], "application/json", Body}}
    end,
    {Verb, Arguments} = Request,
    case httpc:request(Verb, Arguments,
            [{timeout, 3000}, {connect_timeout, 1000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Response}} -> {ok, {Status, Response}};
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.
