%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_rewrite).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

-ifdef(TEST).
-export([ compile/1
        , match_and_rewrite/2
        ]).
-endif.

%% APIs
-export([ rewrite_subscribe/4
        , rewrite_unsubscribe/4
        , rewrite_publish/2
        ]).

-export([ enable/0
        , disable/0
        ]).

-export([ list/0
        , update/1]).

%%--------------------------------------------------------------------
%% Load/Unload
%%--------------------------------------------------------------------

enable() ->
    Rules = emqx_conf:get([rewrite], []),
    register_hook(Rules).

disable() ->
    emqx_hooks:del('client.subscribe',   {?MODULE, rewrite_subscribe}),
    emqx_hooks:del('client.unsubscribe', {?MODULE, rewrite_unsubscribe}),
    emqx_hooks:del('message.publish',    {?MODULE, rewrite_publish}),
    ok.

list() ->
    emqx_conf:get_raw([<<"rewrite">>], []).

update(Rules0) ->
    {ok, #{config := Rules}} = emqx_conf:update([rewrite], Rules0, #{override_to => cluster}),
    register_hook(Rules).

register_hook([]) -> disable();
register_hook(Rules) ->
    {PubRules, SubRules, ErrRules} = compile(Rules),
    emqx_hooks:put('client.subscribe',   {?MODULE, rewrite_subscribe, [SubRules]}),
    emqx_hooks:put('client.unsubscribe', {?MODULE, rewrite_unsubscribe, [SubRules]}),
    emqx_hooks:put('message.publish',    {?MODULE, rewrite_publish, [PubRules]}),
    case ErrRules of
        [] -> ok;
        _ ->
            ?SLOG(error, #{rewrite_rule_re_complie_failed => ErrRules}),
            {error, ErrRules}
    end.

rewrite_subscribe(_ClientInfo, _Properties, TopicFilters, Rules) ->
    {ok, [{match_and_rewrite(Topic, Rules), Opts} || {Topic, Opts} <- TopicFilters]}.

rewrite_unsubscribe(_ClientInfo, _Properties, TopicFilters, Rules) ->
    {ok, [{match_and_rewrite(Topic, Rules), Opts} || {Topic, Opts} <- TopicFilters]}.

rewrite_publish(Message = #message{topic = Topic}, Rules) ->
    {ok, Message#message{topic = match_and_rewrite(Topic, Rules)}}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
compile(Rules) ->
    lists:foldl(fun(Rule, {Publish, Subscribe, Error}) ->
        #{source_topic := Topic, re := Re, dest_topic := Dest, action := Action} = Rule,
        case re:compile(Re) of
            {ok, MP} ->
                case Action of
                    publish ->
                        {[{Topic, MP, Dest} | Publish], Subscribe, Error};
                    subscribe ->
                        {Publish, [{Topic, MP, Dest} | Subscribe], Error};
                    all ->
                        {[{Topic, MP, Dest} | Publish], [{Topic, MP, Dest} | Subscribe], Error}
                end;
            {error, ErrSpec} ->
                {Publish, Subscribe, [{Topic, Re, Dest, ErrSpec}]}
        end end, {[], [], []}, Rules).

match_and_rewrite(Topic, []) ->
    Topic;

match_and_rewrite(Topic, [{Filter, MP, Dest} | Rules]) ->
    case emqx_topic:match(Topic, Filter) of
        true  -> rewrite(Topic, MP, Dest);
        false -> match_and_rewrite(Topic, Rules)
    end.

rewrite(Topic, MP, Dest) ->
    case re:run(Topic, MP, [{capture, all_but_first, list}]) of
        {match, Captured} ->
            Vars = lists:zip(["\\$" ++ integer_to_list(I)
                                || I <- lists:seq(1, length(Captured))], Captured),
            iolist_to_binary(lists:foldl(
                    fun({Var, Val}, Acc) ->
                        re:replace(Acc, Var, Val, [global])
                    end, Dest, Vars));
        nomatch -> Topic
    end.
