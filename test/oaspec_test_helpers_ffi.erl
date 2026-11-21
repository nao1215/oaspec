-module(oaspec_test_helpers_ffi).

%% Test-only helpers for capturing side effects from Gleam closures.
%% pdict_get / pdict_reset use the process dictionary so each test process
%% gets isolated state without plumbing a `Subject` through the function
%% under test.

-export([pdict_get/1, pdict_reset/1, capture_panic/1]).

%% Wrap erlang:get/1 so the Gleam side sees `Result(value, Nil)`.
%% Returning a Result keeps the call site free of dynamic-typing
%% boilerplate at the cost of one extra call, which is negligible
%% in tests.
-spec pdict_get(term()) -> {ok, term()} | {error, nil}.
pdict_get(Key) ->
    case erlang:get(Key) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.

%% Reset a key by erasing it. Returns nil so the Gleam-facing type
%% is uniform with `pdict_get` callers that throw away the result.
-spec pdict_reset(term()) -> nil.
pdict_reset(Key) ->
    erlang:erase(Key),
    nil.

%% Run a thunk and report `{Panicked, Message}` to the caller, so a test
%% can exercise a function that panics on invalid input (e.g. transport
%% header validation) without aborting the test process.
-spec capture_panic(fun(() -> any())) -> {boolean(), binary()}.
capture_panic(Thunk) ->
    try Thunk() of
        _ -> {false, <<"">>}
    catch
        error:#{gleam_error := panic, message := Message} ->
            Bin = case is_binary(Message) of
                true -> Message;
                false -> unicode:characters_to_binary(io_lib:format("~p", [Message]))
            end,
            {true, Bin};
        error:Reason ->
            Bin = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
            {true, Bin};
        throw:Thrown ->
            Bin = unicode:characters_to_binary(io_lib:format("~p", [Thrown])),
            {true, Bin};
        exit:Exit ->
            Bin = unicode:characters_to_binary(io_lib:format("~p", [Exit])),
            {true, Bin}
    end.
