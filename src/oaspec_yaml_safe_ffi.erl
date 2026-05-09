-module(oaspec_yaml_safe_ffi).

%% Adapter around `yay:parse_string/1` (yay v2.0.x) that normalises
%% the FFI's raw `{yaml_error, ...}` tuple shape into the Gleam
%% encoding the upstream `yay.YamlError` Gleam type expects.
%%
%% Issue #576: yay's `yaml_ffi.erl` returns
%% `{error, {yaml_error, Msg, {Line, Col}}}` for yamerl errors that
%% surface a structured message + line/col (the alias-without-anchor
%% case being the obvious example). Gleam's runtime pattern match on
%% `yay.ParsingError(msg:, loc:)` expects
%% `{parsing_error, Msg, {yaml_error_loc, Line, Col}}` instead, so
%% `case e { ParsingError(...) -> _ }` falls through to a BEAM
%% case_clause crash for any input that exercises this code path.
%%
%% A representative crash payload from a self-referential alias:
%%   YamlError("No anchor corresponds to alias \"a\"", #(7, 10))
%%
%% This is server-side DoS in any context where a user controls the
%% YAML input (CI plugins, public spec linters, multi-tenant
%% gateways) — a 9-line malformed YAML payload is enough to crash
%% the parsing process. Rather than vendor yay or wait for an
%% upstream fix, we adapt the tuple shape at the FFI boundary so
%% the rest of the parser keeps using the documented `yay.YamlError`
%% surface unchanged.

-export([parse_string/1]).

-spec parse_string(binary()) ->
    {ok, list(term())}
    | {error, unexpected_parsing_error
            | {parsing_error, binary(), {yaml_error_loc, integer(), integer()}}}.
parse_string(Content) when is_binary(Content) ->
    try yay:parse_string(Content) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} ->
            {error, normalise_error(Reason)}
    catch
        error:Reason:_ ->
            %% Defence in depth: even if a future yay version
            %% raises rather than returns, we surface a sensible
            %% Gleam-shaped error instead of propagating the BEAM
            %% exception out of the parsing process.
            {error, normalise_error(Reason)}
    end.

%% Map every observed yay-FFI error tuple shape onto the canonical
%% Gleam encoding for `yay.YamlError`:
%%   - `UnexpectedParsingError`         → atom `unexpected_parsing_error`
%%   - `ParsingError(msg, loc)`         → `{parsing_error, Msg, {yaml_error_loc, Line, Col}}`
%%
%% Anything we cannot classify falls through to
%% `unexpected_parsing_error` so the upstream error path keeps
%% working without a new variant.

normalise_error(unexpected_parsing_error) ->
    unexpected_parsing_error;
normalise_error({yaml_error, unexpected_parsing_error}) ->
    %% Inner-tagged variant from yay's `error:_` catch-all.
    unexpected_parsing_error;
normalise_error({yaml_error, Msg, {Line, Col}})
        when is_binary(Msg), is_integer(Line), is_integer(Col) ->
    %% The shape that triggers #576.
    {parsing_error, Msg, {yaml_error_loc, Line, Col}};
normalise_error({parsing_error, _, _} = Already) ->
    %% Already in the documented Gleam shape — pass through.
    Already;
normalise_error(_Other) ->
    unexpected_parsing_error.
