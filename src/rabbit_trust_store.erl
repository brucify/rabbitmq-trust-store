%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_trust_store).
-behaviour(gen_server).

-export([mode/0, refresh/0, list/0]). %% Console Interface.
-export([whitelisted/3, is_whitelisted/1]). %% Client-side Interface.
-export([start_link/0]).
-export([init/1, terminate/2,
         handle_call/3, handle_cast/2,
         handle_info/2,
         code_change/3]).

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

-type certificate() :: #'OTPCertificate'{}.
-type event()       :: valid_peer
                     | valid
                     | {bad_cert, Other :: atom()
                                | unknown_ca
                                | selfsigned_peer}
                     | {extension, #'Extension'{}}.
-type state()       :: confirmed | continue.
-type outcome()     :: {valid, state()}
                     | {fail, Reason :: term()}
                     | {unknown, state()}.

-record(state, {
    providers_state :: [{module(), term()}],
    refresh_interval :: integer()
}).
-record(entry, {
    name :: string(),
    cert_id :: term(),
    provider :: module(),
    issuer_id :: tuple(),
    certificate :: public_key:der_encoded()
}).


%% OTP Supervision

start_link() ->
    gen_server:start_link({local, trust_store}, ?MODULE, [], []).


%% Console Interface

-spec mode() -> 'automatic' | 'manual'.
mode() ->
    gen_server:call(trust_store, mode).

-spec refresh() -> integer().
refresh() ->
    gen_server:call(trust_store, refresh).

-spec list() -> string().
list() ->
    Formatted = lists:map(
        fun(#entry{
                name = N,
                cert_id = CertId,
                certificate = Cert,
                issuer_id = {_, Serial}}) ->
            %% Use the certificate unique identifier as a default for the name.
            Name = case N of
                undefined -> io_lib:format("~p", [CertId]);
                _         -> N
            end,
            Validity = rabbit_ssl:peer_cert_validity(Cert),
            Subject = rabbit_ssl:peer_cert_subject(Cert),
            Issuer = rabbit_ssl:peer_cert_issuer(Cert),
            Text = io_lib:format("Name: ~s~nSerial: ~p | 0x~.16.0B~n"
                                 "Subject: ~s~nIssuer: ~s~nValidity: ~p~n",
                                 [Name, Serial, Serial,
                                  Subject, Issuer, Validity]),
            lists:flatten(Text)
        end,
        ets:tab2list(table_name())),
    string:join(Formatted, "~n~n").

%% Client (SSL Socket) Interface

-spec whitelisted(certificate(), event(), state()) -> outcome().
whitelisted(_, {bad_cert, unknown_ca}, confirmed) ->
    {valid, confirmed};
whitelisted(#'OTPCertificate'{}=C, {bad_cert, unknown_ca}, continue) ->
    case is_whitelisted(C) of
        true ->
            {valid, confirmed};
        false ->
            {fail, "CA not known AND certificate not whitelisted"}
    end;
whitelisted(#'OTPCertificate'{}=C, {bad_cert, selfsigned_peer}, continue) ->
    case is_whitelisted(C) of
        true ->
            {valid, confirmed};
        false ->
            {fail, "certificate not whitelisted"}
    end;
whitelisted(_, {bad_cert, _} = Reason, _) ->
    {fail, Reason};
whitelisted(_, valid, St) ->
    {valid, St};
whitelisted(#'OTPCertificate'{}=_, valid_peer, St) ->
    {valid, St};
whitelisted(_, {extension, _}, St) ->
    {unknown, St}.

-spec is_whitelisted(certificate()) -> boolean().
is_whitelisted(#'OTPCertificate'{}=C) ->
    Id = extract_issuer_id(C),
    ets:member(table_name(), Id).

%% Generic Server Callbacks

init([]) ->
    erlang:process_flag(trap_exit, true),
    ets:new(table_name(), table_options()),
    Config = application:get_all_env(rabbitmq_trust_store),
    ProvidersState = refresh_certs(Config, []),
    Interval = refresh_interval(Config),
    if
        Interval =:= 0 ->
            ok;
        Interval  >  0 ->
            erlang:send_after(Interval, erlang:self(), refresh)
    end,
    {ok,
     #state{
      providers_state = ProvidersState,
      refresh_interval = Interval}}.

handle_call(mode, _, St) ->
    {reply, mode(St), St};
handle_call(refresh, _, #state{providers_state = ProvidersState} = St) ->
    Config = application:get_all_env(rabbitmq_trust_store),
    NewProvidersState = refresh_certs(Config, ProvidersState),
    {reply, ok, St#state{providers_state = NewProvidersState}};
handle_call(_, _, St) ->
    {noreply, St}.

handle_cast(_, St) ->
    {noreply, St}.

handle_info(refresh, #state{refresh_interval = Interval,
                            providers_state = ProvidersState} = St) ->
    Config = application:get_all_env(rabbitmq_trust_store),
    NewProvidersState = refresh_certs(Config, ProvidersState),
    erlang:send_after(Interval, erlang:self(), refresh),
    {noreply, St#state{providers_state = NewProvidersState}};
handle_info(_, St) ->
    {noreply, St}.

terminate(shutdown, _St) ->
    true = ets:delete(table_name()).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Ancillary & Constants

mode(#state{refresh_interval = I}) ->
    if
        I =:= 0 -> 'manual';
        I  >  0 -> 'automatic'
    end.

refresh_interval(Config) ->
    Seconds = case proplists:get_value(refresh_interval, Config) of
        undefined ->
            default_refresh_interval();
        S when is_integer(S), S >= 0 ->
            S;
        {seconds, S} when is_integer(S), S >= 0 ->
            S
    end,
    timer:seconds(Seconds).

default_refresh_interval() ->
    {ok, I} = application:get_env(rabbitmq_trust_store, default_refresh_interval),
    I.


%% =================================

-spec refresh_certs(Config, State) -> State
      when State :: [{module(), term()}],
           Config :: list().
refresh_certs(Config, State) ->
    Providers = providers(Config),
    lists:foldl(
        fun(Provider, NewStates) ->
            ProviderState = proplists:get_value(Provider, State, nostate),
            RefreshedState = refresh_provider_certs(Provider, Config, ProviderState),
            [{Provider, RefreshedState} | NewStates]
        end,
        [],
        Providers).

-spec refresh_provider_certs(Provider, Config, ProviderState) -> ProviderState
      when Provider :: module(),
           Config :: list(),
           ProviderState :: term().
refresh_provider_certs(Provider, Config, ProviderState) ->
    case list_certs(Provider, Config, ProviderState) of
        no_change ->
            ProviderState;
        {ok, CertsList, NewProviderState} ->
            update_certs(CertsList, Provider, Config),
            NewProviderState;
        {error, Reason} ->
            rabbit_log:error("Unable to load certificate list for provider ~p"
                             " reason: ~p~n",
                             [Provider, Reason])
    end.

list_certs(Provider, Config, nostate) ->
    Provider:list_certs(Config);
list_certs(Provider, Config, ProviderState) ->
    Provider:list_certs(Config, ProviderState).

update_certs(CertsList, Provider, Config) ->
    OldCertIds = get_old_cert_ids(Provider),
    {NewCertIds, _} = lists:unzip(CertsList),

    lists:foreach(
        fun(CertId) ->
            Attributes = proplists:get_value(CertId, CertsList),
            Name = maps:get(name, Attributes, undefined),
            case get_cert_data(Provider, CertId, Attributes, Config) of
                {ok, Cert, IssuerId} ->
                    save_cert(CertId, Provider, IssuerId, Cert, Name);
                {error, Reason} ->
                    rabbit_log:error("Unable to load CA sertificate ~p"
                                     " with provider ~p"
                                     " reason: ~p",
                                     [CertId, Provider, Reason])
            end
        end,
        NewCertIds -- OldCertIds),
    lists:foreach(
        fun(CertId) ->
            delete_cert(CertId, Provider)
        end,
        OldCertIds -- NewCertIds),
    ok.

get_cert_data(Provider, CertId, Attributes, Config) ->
    try
        case Provider:get_cert_data(CertId, Attributes, Config) of
            {ok, Cert} ->
                DecodedCert = public_key:pkix_decode_cert(Cert, otp),
                Id = extract_issuer_id(DecodedCert),
                {ok, Cert, Id};
            {error, Reason} -> {error, Reason}
        end
    catch _:Error ->
        {error, {Error, erlang:get_stacktrace()}}
    end.

delete_cert(CertId, Provider) ->
    MS = ets:fun2ms(fun(#entry{cert_id = CId, provider = P})
                    when P == Provider, CId == CertId ->
                        true
                    end),
    ets:select_delete(table_name(), MS).

save_cert(CertId, Provider, Id, Cert, Name) ->
    ets:insert(table_name(), #entry{cert_id = CertId,
                                    provider = Provider,
                                    issuer_id = Id,
                                    certificate = Cert,
                                    name = Name}).

get_old_cert_ids(Provider) ->
    MS = ets:fun2ms(fun(#entry{provider = P, cert_id = CId})
                    when P == Provider ->
                        CId
                    end),
    lists:append(ets:select(table_name(), MS)).

providers(Config) ->
    proplists:get_value(providers, Config, []).

table_name() ->
    trust_store_whitelist.

table_options() ->
    [protected,
     named_table,
     set,
     {keypos, #entry.issuer_id},
     {heir, none}].

extract_issuer_id(#'OTPCertificate'{} = C) ->
    {Serial, Issuer} = case public_key:pkix_issuer_id(C, other) of
        {error, _Reason} ->
            {ok, Identifier} = public_key:pkix_issuer_id(C, self),
            Identifier;
        {ok, Identifier} ->
            Identifier
    end,
    {Issuer, Serial}.
