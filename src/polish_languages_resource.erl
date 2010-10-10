%%% @author Jordi Chacon <jordi.chacon@klarna.com>
%%% @copyright (C) 2010, Jordi Chacon

-module(polish_languages_resource).

-export([get_list/0, get/1]).

-include("polish.hrl").

get_list() ->
     [LC || LC <- polish:all_custom_lcs(), LC =/= "a"].

get(LC) ->
    polish_po:get_stats(LC).
