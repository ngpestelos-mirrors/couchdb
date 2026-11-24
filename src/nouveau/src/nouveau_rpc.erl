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

%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(nouveau_rpc).

-export([
    search/3,
    info/2
]).

-include("nouveau.hrl").
-import(nouveau_util, [index_path/1]).

search(DbName, #index{} = Index0, #{} = QueryArgs0) ->
    %% Incorporate the shard name into the record.
    Index1 = Index0#index{dbname = DbName},

    Update = maps:get(update, QueryArgs0, true),

    %% Incorporate min seqs into the query args.
    QueryArgs1 =
        case Update of
            true ->
                %% get minimum seqs for search
                {MinUpdateSeq, MinPurgeSeq} = nouveau_index_updater:get_db_info(Index1),
                QueryArgs0#{
                    min_update_seq => MinUpdateSeq,
                    min_purge_seq => MinPurgeSeq
                };
            false ->
                QueryArgs0#{
                    min_update_seq => 0,
                    min_purge_seq => 0
                }
        end,

    search_int(DbName, Index1, QueryArgs1, Update, 0).

search_int(DbName, #index{} = Index, QueryArgs, Update, UpdateLatency) ->
    %% Run the search
    case nouveau_api:search(Index, QueryArgs) of
        {ok, Response} ->
            rexi:reply(
                {ok, Response#{
                    update_latency => erlang:convert_time_unit(UpdateLatency, native, millisecond)
                }}
            );
        {error, stale_index} when Update ->
            update_and_retry(DbName, Index, QueryArgs, Update, UpdateLatency);
        {error, {not_found, _}} when Update ->
            update_and_retry(DbName, Index, QueryArgs, Update, UpdateLatency);
        Else ->
            rexi:reply(Else)
    end.

update_and_retry(DbName, Index, QueryArgs, Update, UpdateLatency) ->
    T0 = erlang:monotonic_time(),
    case nouveau_index_manager:update_index(Index#index{dbname = DbName}) of
        ok ->
            T1 = erlang:monotonic_time(),
            search_int(
                DbName,
                Index,
                QueryArgs,
                Update,
                UpdateLatency + T1 - T0
            );
        Else ->
            rexi:reply(Else)
    end.

info(DbName, #index{} = Index) ->
    rexi:reply(nouveau_util:index_info(DbName, Index)).
