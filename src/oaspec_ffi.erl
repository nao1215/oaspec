-module(oaspec_ffi).
-export([
    find_executable/1,
    run_executable/2,
    is_stdout_tty/0,
    no_color_set/0,
    monotonic_ms/0,
    capture_panic/1
]).

%% Find an executable on PATH. Returns {ok, Path} or {error, nil}.
-spec find_executable(binary()) -> {ok, binary()} | {error, nil}.
find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

%% Run an executable with arguments. Returns the exit code as an integer.
%% Uses spawn_executable to avoid shell injection.
-spec run_executable(binary(), list(binary())) -> integer().
run_executable(Executable, Args) ->
    Port = open_port(
        {spawn_executable, binary_to_list(Executable)},
        [exit_status, stderr_to_stdout, binary, {args, [binary_to_list(A) || A <- Args]}]
    ),
    collect_exit(Port).

collect_exit(Port) ->
    receive
        {Port, {data, _}} ->
            collect_exit(Port);
        {Port, {exit_status, Code}} ->
            Code
    after 60000 ->
        try port_close(Port) catch _:_ -> ok end,
        1
    end.

%% Detect whether standard_io is connected to a terminal. io:getopts/1
%% reports a `terminal' flag for interactive sessions; non-TTY (pipe,
%% redirection, escript captured stdout) returns false or omits the key.
-spec is_stdout_tty() -> boolean().
is_stdout_tty() ->
    case io:getopts(standard_io) of
        {ok, Opts} ->
            case lists:keyfind(terminal, 1, Opts) of
                {terminal, true} -> true;
                _ -> false
            end;
        _ -> false
    end.

%% Honor the NO_COLOR convention (https://no-color.org/): an unset or
%% empty value means "do not opt out"; any non-empty value means "no
%% color".
-spec no_color_set() -> boolean().
no_color_set() ->
    case os:getenv("NO_COLOR") of
        false -> false;
        "" -> false;
        _ -> true
    end.

%% Monotonic millisecond timestamp from the BEAM monotonic clock.
%% Suitable for measuring elapsed time within a single VM run. The
%% value is unaffected by system clock adjustments and only meaningful
%% as a difference relative to another reading on the same node.
-spec monotonic_ms() -> integer().
monotonic_ms() ->
    erlang:monotonic_time(millisecond).

%% Run a thunk and report `{Panicked, Message}` to the caller. Used by
%% tests that exercise functions which intentionally panic on invalid
%% input (e.g. transport header validation) without aborting the
%% test process.
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
