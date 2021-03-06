%%% @author Jordi Chacon <jordi.chacon@klarna.com>
%%% @copyright (C) 2010, Jordi Chacon

-module(polish_po).

-export([check_correctness/2
	 , get_entries/1
	 , get_stats/1
	 , write/1
        ]).

-include("polish.hrl").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  A P I
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
get_entries({undefined, _}) ->
    [];
get_entries({LC, Action}) when Action =:= po_file;
			       Action =:= save;
			       Action =:= always_translate ->
    KVs = get_entries_to_edit(LC),
    Entries0 = take(KVs, get_offset() + 20, 21, ?l2a(LC), no_search),
    {Entries, MoreEntries} =
	case length(Entries0) of
	    21 -> {tl(Entries0), true};
	    _  -> {Entries0, false}
	end,
    {Action, polish_server:lock_keys(Entries, ?l2a(LC)), MoreEntries};
get_entries({LC, {Action0, Str, {Trans, UnTrans, K, V, MatchType}}})
  when Action0 =:= search; Action0 =:= save_search ->
    KVs = get_entries_to_edit(LC, Trans, UnTrans),
    Entries0 = take(KVs, length(KVs), ?l2a(LC), {Str, K, V, MatchType}),
    {Entries, Action} =
	case length(Entries0) > 40 of
	    true  -> {element(1,lists:split(40, Entries0)), bad_search};
	    false -> {Entries0, Action0}
	end,
    {Action, polish_server:lock_keys(Entries, ?l2a(LC)), false}.

write(KV) ->
    LC = wf:session(lang),
    KVs0 = polish_server:read_po_file(LC),
    KVs = lists:keysort(1, merge_changes(KVs0, KV)),
    TransName = polish_utils:translator_name(),
    polish_wash:write_po_file(LC, KVs, TransName,
			      polish_utils:translator_email()),
    polish_server:update_po_file(LC, KV),
    Str = polish_utils:build_info_log(?l2a(LC), TransName, KV),
    error_logger:info_msg(Str).

get_stats(undefined) -> {0, 0};
get_stats(LC) ->
    KVs = polish_server:read_po_file(LC),
    Untrans = get_amount_untranslated_keys(KVs, ?l2a(LC)),
    {length(KVs), Untrans}.

check_correctness(Key, Val) ->
    Validators = [gettext_validate_bad_ftxt, gettext_validate_bad_stxt,
		  gettext_validate_bad_case, gettext_validate_bad_html,
		  gettext_validate_bad_punct, gettext_validate_bad_ws],
    run_validators(Key, Val, Validators).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  I N T E R N A L   F U N C T I O N S
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% get_entries
%------------------------------------------------------------------------------
get_entries_to_edit(LC, {translated, false}, {untranslated, true}) ->
    get_entries_to_edit(LC, fun(K, V) -> (K == V) orelse (V == "") end);
get_entries_to_edit(LC, {translated, true}, {untranslated, false}) ->
    get_entries_to_edit(LC, fun(K, V) -> K =/= V end);
get_entries_to_edit(LC, {translated, true}, {untranslated, true}) ->
    get_entries_to_edit(LC, fun(_K, _V) -> true end);
get_entries_to_edit(LC, {translated, false}, {untranslated, false}) ->
    get_entries_to_edit(LC, fun(_K, _V) -> false end).

get_entries_to_edit(LC) ->
    get_entries_to_edit(LC, fun(K, V) -> (K == V) orelse (V == "") end).

get_entries_to_edit(LC, F) ->
    [{Key,Val} || {Key,Val} <- polish_server:read_po_file(LC), F(Key, Val)].

take([], _, _, _, _)      -> [];
take(T, 1, N, LC, S)      -> take(T, N, LC, S);
take([_H|T], Offset, N, LC, S) -> take(T, Offset - 1, N, LC, S).

take([{K,V} = H|T], N, LC, Search) when N > 0 ->
    case (polish_server:is_key_locked(K, LC) orelse
          polish_server:is_always_translated(LC, K)) of
	true                            ->
            take(T, N, LC, Search);
	false when Search =:= no_search ->
            [H|take(T, N-1, LC, Search)];
	false ->
	    case match_entry({K, V}, Search) of
		nomatch -> take(T, N, LC, Search);
		match   -> [H|take(T, N-1, LC, Search)]
	    end
    end;
take(_, N, _LC, _S) when N =< 0   -> [];
take([], _, _LC, _S)              -> [].

get_offset() ->
    case wf:session(offset) of
	undefined -> wf:session(offset, 0), 0;
	V         -> V
    end.

match_entry(KV, {Str, Key, Val, {match_type, any}}) ->
    match_entry(KV, {Str, Key, Val});
match_entry({K, _V}, {Str, {key, true}, {value, false}, {match_type, exact}}) ->
    run_literal(K, Str);
match_entry({_K, V}, {Str, {key, false}, {value, true}, {match_type, exact}}) ->
    run_literal(V, Str);
match_entry({K, V}, {Str, {key, true}, {value, true}, {match_type, exact}}) ->
    case run_literal(K, Str) of
	nomatch -> run_literal(V, Str);
	_       -> match
    end;
match_entry({K, _V}, {Str, {key, true}, {value, false}}) ->
    run_re(K, Str);
match_entry({_K, V}, {Str, {key, false}, {value, true}}) ->
    run_re(V, Str);
match_entry({K, V}, {Str, {key, true}, {value, true}}) ->
    case run_re(K, Str) of
	nomatch -> run_re(V, Str);
	_       -> match
    end;
match_entry({_K,_V}, {_S, {key, false}, {value, false}, {match_type, exact}}) ->
    nomatch;
match_entry({_K, _V}, {_Str, {key, false}, {value, false}}) ->
    nomatch.

run_literal(S1, S2) ->
    Exp = polish_utils:trim_whitespace(string:to_lower(S1)),
    Res = polish_utils:trim_whitespace(string:to_lower(S2)),
    case Res == Exp of
	true  -> match;
	false -> nomatch
    end.

%% When the translation is empty (as in "") the V is header_info. Weird...
run_re(header_info, _RegExp) ->
    nomatch;
run_re(V, RegExp0) ->
    RegExp = escape_regexp(RegExp0),
    case re:run(V, RegExp) of
	nomatch -> nomatch;
	_       -> match
    end.

escape_regexp(RegExp) ->
    escape_regexp(RegExp, []).
escape_regexp([$$ | RegExp], Acc) -> escape_regexp(RegExp, [$$,$\\ | Acc]);
escape_regexp([$? | RegExp], Acc) -> escape_regexp(RegExp, [$?,$\\ | Acc]);
escape_regexp([$* | RegExp], Acc) -> escape_regexp(RegExp, [$*,$\\ | Acc]);
escape_regexp([$( | RegExp], Acc) -> escape_regexp(RegExp, [$(,$\\ | Acc]);
escape_regexp([$) | RegExp], Acc) -> escape_regexp(RegExp, [$),$\\ | Acc]);
escape_regexp([Char | RegExp], Acc) -> escape_regexp(RegExp, [Char | Acc]);
escape_regexp([], Acc) -> lists:reverse(Acc).



% check_correctness
%------------------------------------------------------------------------------
run_validators(_Key, _Val, []) ->
    ok;
run_validators(Key, Val, [Validator|T]) ->
    case run_validator(Validator, Key, Val) of
	ok                -> run_validators(Key, Val, T);
	{error, _Msg} = E -> E
    end.

run_validator(Module, K, V) ->
    try
	case Module:check({K, V}, polish_server, []) of
	    [] -> ok;
	    Err when element(1, hd(Err)) =:= 'ERROR' orelse
		     element(1, hd(Err)) =:= 'Warning' ->
		{error, element(2, hd(Err))}
	end
    catch throw:{formatter_crashed,K,V} -> {error,"Dollar $ signs do not match"}
    end.



% write
%------------------------------------------------------------------------------
merge_changes(KVs, Changes) ->
    lists:foldr(
      fun({K, _V} = KV, Acc) -> case proplists:get_value(K, Changes) of
				    undefined -> [KV | Acc];
				    NewV      -> [{K, NewV} | Acc]
				end
      end, [], KVs).



% get_stats
%------------------------------------------------------------------------------
get_amount_untranslated_keys(KVs, LCa) ->
    lists:foldl(
      fun({K, K}, Acc) ->
	      case polish_server:is_always_translated(LCa, K) of
		  true  -> Acc;
		  false -> Acc + 1
	      end;
	 ({_K, _V}, Acc) -> Acc
      end, 0, KVs).
