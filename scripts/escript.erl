#!/usr/bin/env escript
%% -*- erlang -*-
%%
%% Packs the oaspec escript from the production Erlang shipment, and lists
%% what an escript contains.
%%
%%   escript scripts/escript.erl pack SHIPMENT_DIR APP OUT
%%   escript scripts/escript.erl list ESCRIPT
%%
%% `gleam run -m gleescript` packs every BEAM file under build/dev/erlang,
%% so the escript it writes also carries the test modules and the
%% dev-dependencies (gleeunit, glinter, metamon, gleescript and their own
%% dependencies). `gleam export erlang-shipment` compiles the production
%% build, which holds only the package and its runtime dependencies;
%% packing that keeps the released escript to what the CLI runs.
%%
%% The entry module is compiled here rather than taken from gleescript, so
%% building the escript needs no dev-dependency. It starts the application
%% and calls its Gleam `main/0`, the same steps gleescript's shim takes.

main(["pack", Shipment, App, Out]) ->
    pack(Shipment, App, Out);
main(["list", File]) ->
    list(File);
main(_) ->
    io:format(standard_error,
              "usage: escript scripts/escript.erl pack SHIPMENT_DIR APP OUT~n"
              "       escript scripts/escript.erl list ESCRIPT~n", []),
    halt(2).

pack(Shipment, App, Out) ->
    Paths = [P || P <- filelib:wildcard(filename:join([Shipment, "*", "ebin", "*"])),
                  lists:member(filename:extension(P), [".beam", ".app"]),
                  %% The @@ modules belong to the Gleam build tool.
                  string:find(filename:basename(P), "@@") =:= nomatch],
    case Paths of
        [] -> fail("no .beam or .app files under ~s/*/ebin; run gleam export erlang-shipment first", [Shipment]);
        _ -> ok
    end,
    Entries = [{filename:basename(P), read(P)} || P <- Paths] ++ [entry_module(App)],
    Names = [N || {N, _} <- Entries],
    case Names -- lists:usort(Names) of
        [] -> ok;
        Dups -> fail("two applications ship a file with the same name: ~p", [lists:usort(Dups)])
    end,
    ok = filelib:ensure_dir(Out),
    case escript:create(Out, [shebang, {comment, ""},
                              {emu_args, "-escript main oaspec_escript_main"},
                              {archive, Entries, []}]) of
        ok -> ok;
        {error, Reason} -> fail("cannot write ~s: ~p", [Out, Reason])
    end,
    ok = file:change_mode(Out, 8#755),
    io:format("Packed ~b files from ~s into ~s~n", [length(Entries), Shipment, Out]).

entry_module(App) ->
    Source = [
        "-module(oaspec_escript_main).",
        "-export([main/1]).",
        "main(_) ->"
        "    io:setopts(standard_io, [binary, {encoding, utf8}]),"
        "    io:setopts(standard_error, [{encoding, utf8}]),"
        "    {ok, _} = application:ensure_all_started('" ++ App ++ "'),"
        "    '" ++ App ++ "':main()."
    ],
    Forms = [parse(S) || S <- Source],
    {ok, oaspec_escript_main, Beam} = compile:forms(Forms, [report]),
    {"oaspec_escript_main.beam", Beam}.

parse(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    {ok, Form} = erl_parse:parse_form(Tokens),
    Form.

list(File) ->
    case escript:extract(File, []) of
        {ok, Sections} ->
            case lists:keyfind(archive, 1, Sections) of
                {archive, Archive} when is_binary(Archive) ->
                    {ok, Names} = zip:list_dir(Archive, [names_only]),
                    [io:format("~s~n", [N]) || N <- lists:sort(Names)],
                    ok;
                _ -> fail("~s has no archive section", [File])
            end;
        {error, Reason} -> fail("cannot read ~s: ~p", [File, Reason])
    end.

read(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

fail(Format, Args) ->
    io:format(standard_error, "error: " ++ Format ++ "~n", Args),
    halt(1).
