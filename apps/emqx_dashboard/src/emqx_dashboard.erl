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

-module(emqx_dashboard).

-define(APP, ?MODULE).


-export([ start_listeners/0
        , stop_listeners/0]).

%% Authorization
-export([authorize/1]).

-include_lib("emqx/include/logger.hrl").

-define(BASE_PATH, "/api/v5").

-define(EMQX_MIDDLE, emqx_dashboard_middleware).

%%--------------------------------------------------------------------
%% Start/Stop Listeners
%%--------------------------------------------------------------------

start_listeners() ->
    {ok, _} = application:ensure_all_started(minirest),
    Authorization = {?MODULE, authorize},
    GlobalSpec = #{
        openapi => "3.0.0",
        info => #{title => "EMQ X API", version => "5.0.0"},
        servers => [#{url => ?BASE_PATH}],
        components => #{
            schemas => #{},
            'securitySchemes' => #{
                'basicAuth' => #{type => http, scheme => basic},
                'bearerAuth' => #{type => http, scheme => bearer}
            }}},
    Dispatch = [ {"/", cowboy_static, {priv_file, emqx_dashboard, "www/index.html"}}
               , {"/static/[...]", cowboy_static, {priv_dir, emqx_dashboard, "www/static"}}
               , {'_', cowboy_static, {priv_file, emqx_dashboard, "www/index.html"}}
               ],
    BaseMinirest = #{
        base_path => ?BASE_PATH,
        modules => minirest_api:find_api_modules(apps()),
        authorization => Authorization,
        security => [#{'basicAuth' => []}, #{'bearerAuth' => []}],
        swagger_global_spec => GlobalSpec,
        dispatch => Dispatch,
        middlewares => [cowboy_router, ?EMQX_MIDDLE, cowboy_handler]
    },
    [begin
        Minirest = maps:put(protocol, Protocol, BaseMinirest),
        {ok, _} = minirest:start(Name, RanchOptions, Minirest),
        ?ULOG("Start listener ~ts on ~p successfully.~n", [Name, Port])
    end || {Name, Protocol, Port, RanchOptions} <- listeners()].

stop_listeners() ->
    [begin
        ok = minirest:stop(Name),
        ?ULOG("Stop listener ~ts on ~p successfully.~n", [Name, Port])
    end || {Name, _, Port, _} <- listeners()].

%%--------------------------------------------------------------------
%% internal

apps() ->
    [App || {App, _, _} <- application:loaded_applications(),
        case re:run(atom_to_list(App), "^emqx") of
            {match,[{0,4}]} -> true;
            _ -> false
        end].

listeners() ->
    [begin
        Protocol = maps:get(protocol, ListenerOptions, http),
        Port = maps:get(port, ListenerOptions, 18083),
        Name = listener_name(Protocol, Port),
        RanchOptions = ranch_opts(maps:without([protocol], ListenerOptions)),
        {Name, Protocol, Port, RanchOptions}
    end || ListenerOptions <- emqx_conf:get([emqx_dashboard, listeners], [])].

ranch_opts(RanchOptions) ->
    Keys = [ {ack_timeout, handshake_timeout}
            , connection_type
            , max_connections
            , num_acceptors
            , shutdown
            , socket],
    {S, R} = lists:foldl(fun key_take/2, {RanchOptions, #{}}, Keys),
    R#{socket_opts => maps:fold(fun key_only/3, [], S)}.


key_take(Key, {All, R})  ->
    {K, KX} = case Key of
                  {K1, K2} -> {K1, K2};
                  _ -> {Key, Key}
              end,
    case maps:get(K, All, undefined) of
        undefined ->
            {All, R};
        V ->
            {maps:remove(K, All), R#{KX => V}}
    end.

key_only(K , true , S)  -> [K | S];
key_only(_K, false, S)  -> S;
key_only(K , V    , S)  -> [{K, V} | S].

listener_name(Protocol, Port) ->
    Name = "dashboard:" ++ atom_to_list(Protocol) ++ ":" ++ integer_to_list(Port),
    list_to_atom(Name).

authorize(Req) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, Username, Password} ->
            case emqx_dashboard_admin:check(Username, Password) of
                ok ->
                    ok;
                {error, <<"username_not_found">>} ->
                    Path = cowboy_req:path(Req),
                    case emqx_mgmt_auth:authorize(Path, Username, Password) of
                        ok ->
                            ok;
                        {error, <<"not_allowed">>} ->
                            return_unauthorized(
                                <<"WORNG_USERNAME_OR_PWD">>,
                                <<"Check username/password">>);
                        {error, _} ->
                            return_unauthorized(
                                <<"WORNG_USERNAME_OR_PWD_OR_API_KEY_OR_API_SECRET">>,
                                <<"Check username/password or api_key/api_secret">>)
                    end;
                {error, _} ->
                    return_unauthorized(<<"WORNG_USERNAME_OR_PWD">>, <<"Check username/password">>)
            end;
        {bearer, Token} ->
            case emqx_dashboard_admin:verify_token(Token) of
                ok ->
                    ok;
                {error, token_timeout} ->
                    return_unauthorized(<<"TOKEN_TIME_OUT">>, <<"POST '/login', get new token">>);
                {error, not_found} ->
                    return_unauthorized(<<"BAD_TOKEN">>, <<"POST '/login'">>)
            end;
        _ ->
            return_unauthorized(<<"AUTHORIZATION_HEADER_ERROR">>,
                <<"Support authorization: basic/bearer ">>)
    end.

return_unauthorized(Code, Message) ->
    {401, #{<<"WWW-Authenticate">> =>
    <<"Basic Realm=\"minirest-server\"">>},
        #{code => Code, message => Message}
    }.
