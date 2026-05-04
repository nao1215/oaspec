%% Issue #405: persistent_term-backed memoization for the three
%% pre-compiled regexes used by `oaspec/internal/util/naming`. Without
%% this, every `to_pascal_case/1` and `to_snake_case/1` call compiles
%% the same three regexes from scratch — on a 10k-schema spec that's
%% 30k+ wasted compiles per generate run.
%%
%% `persistent_term` is the right primitive here because the cached
%% values are written exactly once per BEAM process lifetime (the first
%% caller wins) and read O(1) by every subsequent caller, with no
%% GC pressure on a hot path. The compute fun is a Gleam closure
%% returning the same `gleam/regexp` Regexp record the rest of the
%% naming module already deals with — `persistent_term` stores it
%% verbatim, no encoding tricks.

-module(oaspec_naming_ffi).
-export([memoize/2]).

memoize(Key, Compute) ->
    case persistent_term:get(Key, undefined) of
        undefined ->
            Result = Compute(),
            persistent_term:put(Key, Result),
            Result;
        Cached ->
            Cached
    end.
