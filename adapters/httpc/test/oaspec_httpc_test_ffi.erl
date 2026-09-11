-module(oaspec_httpc_test_ffi).
-export([silent_server/0, closed_port/0]).

%% Start a TCP server on 127.0.0.1 that accepts connections and never
%% writes a byte, and return its port. The listener lives in its own
%% process and keeps accepted sockets open until 60 seconds pass without
%% a new connection, longer than gleam_httpc's default 30-second timeout.
silent_server() ->
    Parent = self(),
    spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Listen),
        Parent ! {silent_server_port, Port},
        hold(Listen)
    end),
    receive
        {silent_server_port, Port} -> Port
    after 5000 -> erlang:error(silent_server_did_not_start)
    end.

hold(Listen) ->
    case gen_tcp:accept(Listen, 60000) of
        {ok, _Socket} -> hold(Listen);
        {error, _} -> ok
    end.

%% A port on 127.0.0.1 with nothing listening: bind one, read its number,
%% and close it again.
closed_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.
