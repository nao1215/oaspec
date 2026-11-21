-module(oaspec_json_ffi).

%% Fast-path JSON parser used by the OpenAPI spec loader. The default
%% loader feeds every input through yamerl regardless of extension,
%% which is fine for hand-written YAML specs (a few hundred KB) but is
%% catastrophically slow on large JSON specs — yamerl stalls or
%% crashes on the 12 MB GitHub REST OpenAPI bundle.
%%
%% This module bypasses yamerl entirely for `.json` input by calling
%% the OTP 27 `json` module's streaming decoder. Each value is wrapped
%% directly into a yay.Node-shaped tagged tuple so the rest of the
%% OpenAPI parser keeps walking the same `yay.Node` representation it
%% already understands. Object key order is preserved (OAS spec order
%% drives codegen output ordering for paths and schema property maps).
%%
%% On invalid JSON the decoder raises an error; we catch it and map it
%% to the same `{parsing_error, Msg, {yaml_error_loc, Line, Col}}`
%% shape that `yay.parse_string` returns so the upstream error path is
%% unchanged. We do not have byte-accurate position info from
%% `json:decode/3` so the location is reported as `{0, 0}` and the
%% caller can supplement with its own line/col index from the raw
%% content.

-export([parse_string/1]).

-spec parse_string(binary()) ->
    {ok, list({document, term()})}
    | {error, unexpected_parsing_error | {parsing_error, binary(), {yaml_error_loc, integer(), integer()}}}.
parse_string(Content) when is_binary(Content) ->
    try
        {Result, ok, Rest} = json:decode(Content, ok, decoders()),
        case strip_whitespace(Rest) of
            <<>> ->
                {ok, [{document, wrap(Result)}]};
            _Other ->
                %% OTP json:decode happily stops at the end of the
                %% first complete value and returns the rest as
                %% `Rest`. yamerl rejects trailing junk, so to keep
                %% the two parsers' contracts symmetric we reject
                %% any non-whitespace bytes after the document. A
                %% common cause is two concatenated JSON documents
                %% in one file, which is allowed by `application/x-ndjson`
                %% but not by `application/json`.
                {error, {parsing_error,
                    <<"Trailing data after JSON document">>,
                    {yaml_error_loc, 0, 0}}}
        end
    catch
        error:Reason ->
            {error, classify_error(Reason)}
    end.

%% Custom decoders that build yay.Node-shaped tagged tuples while
%% preserving object key order. yay represents:
%%   - NodeNil          → atom node_nil
%%   - NodeStr(b)       → {node_str, b}
%%   - NodeBool(b)      → {node_bool, b}
%%   - NodeInt(i)       → {node_int, i}
%%   - NodeFloat(f)     → {node_float, f}
%%   - NodeSeq([n])     → {node_seq, [n]}
%%   - NodeMap([{k,v}]) → {node_map, [{k, v}]}  (k/v are nodes, not raw)
%%
%% The default Erlang decoder pushes raw values (binaries, integers,
%% floats, atoms, tagged tuples for nested objects/arrays) into the
%% accumulator. We override `*_push` so primitives are wrapped as soon
%% as they enter the tree, and `*_finish` so the accumulator is
%% reversed and tagged in one pass.
decoders() ->
    #{
        array_push => fun(Value, Acc) -> [wrap(Value) | Acc] end,
        array_finish =>
            fun(Acc, OldAcc) -> {{node_seq, lists:reverse(Acc)}, OldAcc} end,
        object_push =>
            fun(Key, Value, Acc) ->
                [{wrap_key(Key), wrap(Value)} | Acc]
            end,
        object_finish =>
            fun(Acc, OldAcc) -> {{node_map, lists:reverse(Acc)}, OldAcc} end
    }.

%% Wrap a raw decoder output (or already-wrapped tagged tuple from a
%% nested object/array finish) into a yay.Node tagged tuple. The
%% guard order matters: tagged tuples (node_map, node_seq, ...) must
%% match before the generic fallback.
wrap(true) -> {node_bool, true};
wrap(false) -> {node_bool, false};
wrap(null) -> node_nil;
wrap(I) when is_integer(I) -> {node_int, I};
wrap(F) when is_float(F) -> {node_float, F};
wrap(B) when is_binary(B) -> {node_str, B};
wrap({node_map, _} = N) -> N;
wrap({node_seq, _} = N) -> N;
wrap({node_str, _} = N) -> N;
wrap({node_int, _} = N) -> N;
wrap({node_float, _} = N) -> N;
wrap({node_bool, _} = N) -> N;
wrap(node_nil) -> node_nil.

%% JSON object keys are always strings.
wrap_key(B) when is_binary(B) -> {node_str, B}.

%% Translate a json:decode/3 error into the same tagged-tuple shape
%% that yay.parse_string would emit, so the upstream error pathway
%% does not need a JSON-specific branch. The OTP `json` module raises
%% atoms or `{Tag, Extra}` tuples for parse errors; we render them as
%% a binary message and a placeholder `{0, 0}` location.
classify_error(unexpected_end) ->
    {parsing_error, <<"Unexpected end of JSON input">>, {yaml_error_loc, 0, 0}};
classify_error({invalid_byte, Byte}) ->
    {parsing_error, format_invalid_byte(Byte), {yaml_error_loc, 0, 0}};
classify_error({unexpected_sequence, Bytes}) when is_binary(Bytes) ->
    {parsing_error,
        <<"Unexpected character sequence: ", Bytes/binary>>,
        {yaml_error_loc, 0, 0}};
classify_error(_) ->
    unexpected_parsing_error.

format_invalid_byte(Byte) when is_integer(Byte) ->
    Hex = string:to_upper(integer_to_list(Byte, 16)),
    iolist_to_binary(["Invalid JSON byte: 0x", Hex]).

%% Strip JSON-defined whitespace (space, tab, CR, LF) from the head
%% of a binary. Used to tell `}\n` (valid trailing whitespace, which
%% must be accepted) from `}extra` (trailing junk, which must be
%% rejected). We don't pull in `string:trim/1` here because it
%% normalizes Unicode whitespace, and JSON's grammar specifies only
%% the four ASCII characters above.
strip_whitespace(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    strip_whitespace(Rest);
strip_whitespace(Other) ->
    Other.
