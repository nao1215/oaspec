-module(oaspec_yaml_loc_ffi).

-export([build_location_index/1]).

%% Build a location index from a YAML string.
%% Returns a list of {BinaryPath, {Line, Column}} tuples that Gleam can
%% convert into a Dict(String, SourceLoc).
-spec build_location_index(binary()) -> {ok, list({binary(), {integer(), integer()}})} | {error, nil}.
build_location_index(Content) ->
    try
        application:ensure_all_started(yamerl),
        [Doc | _] = yamerl_constr:string(
            binary_to_list(Content),
            [{detailed_constr, true}, {keep_duplicate_keys, true}]
        ),
        {yamerl_doc, Root} = Doc,
        Acc = walk_node(Root, <<>>, []),
        {ok, Acc}
    catch
        _:_ -> {ok, []}
    end.

%% Walk a yamerl node tree and collect {Path, {Line, Col}} entries.
-spec walk_node(tuple(), binary(), list()) -> list().
walk_node(Node, Path, Acc) ->
    Loc = extract_loc(Node),
    Acc1 = [{Path, Loc} | Acc],
    case Node of
        {yamerl_map, _, _, _, Pairs} when is_list(Pairs) ->
            walk_map_pairs(Pairs, Path, Acc1);
        {yamerl_seq, _, _, _, Items, _Count} when is_list(Items) ->
            walk_seq_items(Items, Path, 0, Acc1);
        _ ->
            Acc1
    end.

-spec walk_map_pairs(list(), binary(), list()) -> list().
walk_map_pairs([], _ParentPath, Acc) ->
    Acc;
walk_map_pairs([{KeyNode, ValueNode} | Rest], ParentPath, Acc) ->
    KeyStr = node_to_key(KeyNode),
    ChildPath = case ParentPath of
        <<>> -> KeyStr;
        _ -> <<ParentPath/binary, ".", KeyStr/binary>>
    end,
    Acc1 = walk_node(ValueNode, ChildPath, Acc),
    walk_map_pairs(Rest, ParentPath, Acc1).

-spec walk_seq_items(list(), binary(), integer(), list()) -> list().
walk_seq_items([], _ParentPath, _Idx, Acc) ->
    Acc;
walk_seq_items([Item | Rest], ParentPath, Idx, Acc) ->
    IdxBin = integer_to_binary(Idx),
    ChildPath = <<ParentPath/binary, "[", IdxBin/binary, "]">>,
    Acc1 = walk_node(Item, ChildPath, Acc),
    walk_seq_items(Rest, ParentPath, Idx + 1, Acc1).

-spec extract_loc(tuple()) -> {integer(), integer()}.
extract_loc(Node) ->
    Pres = element(4, Node),
    Line = proplists:get_value(line, Pres, 0),
    Col = proplists:get_value(column, Pres, 0),
    {Line, Col}.

-spec node_to_key(tuple()) -> binary().
node_to_key({yamerl_str, _, _, _, Text}) ->
    unicode:characters_to_binary(Text);
node_to_key({yamerl_int, _, _, _, Int}) ->
    integer_to_binary(Int);
node_to_key({yamerl_bool, _, _, _, true}) ->
    <<"true">>;
node_to_key({yamerl_bool, _, _, _, false}) ->
    <<"false">>;
node_to_key(_) ->
    <<"_unknown_">>.
