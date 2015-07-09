%% -------------------------------------------------------------------
%%
%% riak_core_coverage_plan: Create a plan to cover a minimal set of VNodes.
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc A module to calculate a plan to cover a minimal set of VNodes.
%%      There is also an option to specify a number of primary VNodes
%%      from each preference list to use in the plan.


%% Example "traditional" coverage plan for a two node, 8 vnode cluster
%% at nval=3
%% {
%%   %% First component is a list of {vnode hash, node name} tuples
%%   [
%%    {0, 'dev1@127.0.0.1'},
%%    {548063113999088594326381812268606132370974703616, 'dev2@127.0.0.1'},
%%    {913438523331814323877303020447676887284957839360, 'dev2@127.0.0.1'}
%%   ],

%%   %% Second component is a list of {vnode hash, [partition list]}
%%   %% tuples representing filters when not all partitions managed by a
%%   %% vnode are required to complete the coverage plan
%%  [
%%   {913438523331814323877303020447676887284957839360,
%%    [730750818665451459101842416358141509827966271488,
%%     913438523331814323877303020447676887284957839360]
%%   }
%%  ]
%% }

%% Snippet from a new-style coverage plan for a two node, 8 vnode
%% cluster at nval=3, with each partition represented twice for up to
%% 16 parallel queries

%% XXX: think about including this in the comments here
%% {1, node, 0.0}
%% {1, node, 0.5}

%% [
%%  %% Second vnode, first half of first partition
%%  {182687704666362864775460604089535377456991567872,
%%   'dev2@127.0.0.1', {0, 156}
%%  },
%%  %% Second vnode, second half of first partition
%%  {182687704666362864775460604089535377456991567872,
%%   'dev2@127.0.0.1', {1, 156}},
%%  %% Third vnode, first half of second partition
%%  {365375409332725729550921208179070754913983135744,
%%   'dev1@127.0.0.1', {2, 156}},
%%  %% Third vnode, second half of second partition
%%  {365375409332725729550921208179070754913983135744,
%%   'dev1@127.0.0.1', {3, 156}},
%%  ...
%% ]

-module(riak_core_coverage_plan).

-include("riak_core_vnode.hrl").

-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([create_plan/5]).

%% Indexes are values in the full 2^160 hash space
-type index() :: chash:index_as_int().
%% IDs (vnode or partition) are integers in the [0, RingSize) space
%% (and trivially map to indexes). Private functions deal with IDs
%% instead of indexes as much as possible
-type vnode_id() :: non_neg_integer().
-type partition_id() :: riak_core_ring:partition_id().
-type subpartition_id() :: non_neg_integer().

-type req_id() :: non_neg_integer().
-type coverage_vnodes() :: [{index(), node()}].
-type vnode_filters() :: [{index(), [index()]}].
-type coverage_plan() :: {coverage_vnodes(), vnode_filters()}.

%% Each: Node, Vnode hash, { Subpartition id, BSL }
-type subp_plan() :: [{index(), node(), { subpartition_id(), pos_integer() }}].

-export_type([coverage_plan/0, coverage_vnodes/0, vnode_filters/0]).

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Create a coverage plan to distribute work to a set
%%      of covering VNodes around the ring. If the first argument
%%      is a vnode_coverage record, that means we've previously
%%      generated a coverage plan and we're being fed back one
%%      element of it. Return that element in the proper format.
-spec create_plan(vnode_selector(),
                  pos_integer()|
                  {pos_integer(), pos_integer(), pos_integer()},
                  pos_integer(),
                  req_id(), atom()) ->
                         {error, term()} | coverage_plan() | subp_plan().
create_plan(#vnode_coverage{vnode_identifier=TargetHash,
                            subpartition={Mask, BSL}},
            _NVal, _PVC, _ReqId, _Service) ->
    {[{TargetHash, node()}], [{TargetHash, {Mask, BSL}}]};
create_plan(#vnode_coverage{vnode_identifier=TargetHash,
                            partition_filters=[]},
            _NVal, _PVC, _ReqId, _Service) ->
    {[{TargetHash, node()}], []};
create_plan(#vnode_coverage{vnode_identifier=TargetHash,
                            partition_filters=HashFilters},
            _NVal, _PVC, _ReqId, _Service) ->
    {[{TargetHash, node()}], [{TargetHash, HashFilters}]};
create_plan(_VNodeTarget, {_NVal, _RingSize, TotalSubp}, _PVC, _ReqId, _Service) ->
    %% XXX TODO - this completely ignores everything relevant to failed nodes
    MaskBSL = data_bits(TotalSubp),
    {ok, ChashBin} = riak_core_ring_manager:get_chash_bin(),
    Partitions = chashbin:to_list(ChashBin),
    lists:map(fun(X) ->
                      PartID = chashbin:responsible_position(X bsl MaskBSL,
                                                             ChashBin),
                      {Idx, Node} = lists:nth(PartID + 1, Partitions),
                      { Idx, Node, { X, MaskBSL } }
              end,
              lists:seq(0, TotalSubp - 1));
create_plan(VNodeTarget, NVal, PVC, ReqId, Service) ->
    {ok, CHBin} = riak_core_ring_manager:get_chash_bin(),
    create_traditional_plan(VNodeTarget, NVal, PVC, ReqId, Service, CHBin).

%% @private
%% Make it easier to unit test create_plan/5.
create_traditional_plan(VNodeTarget, NVal, PVC, ReqId, Service, CHBin) ->
    PartitionCount = chashbin:num_partitions(CHBin),

    %% Calculate an offset based on the request id to offer the
    %% possibility of different sets of VNodes being used even when
    %% all nodes are available. Used in compare_vnode_keyspaces as a
    %% tiebreaker.
    Offset = ReqId rem NVal,

    RingIndexInc = chash:ring_increment(PartitionCount),
    AllKeySpaces = lists:seq(0, PartitionCount - 1),
    UnavailableVnodes = identify_unavailable_vnodes(CHBin, RingIndexInc, Service),

    %% Create function to map coverage keyspaces to
    %% actual VNode indexes and determine which VNode
    %% indexes should be filtered.
    CoverageVNodeFun =
        fun({Position, KeySpaces}, Acc) ->
                %% Calculate the VNode index using the
                %% ring position and the increment of
                %% ring index values.
                VNodeIndex = (Position rem PartitionCount) * RingIndexInc,
                Node = chashbin:index_owner(VNodeIndex, CHBin),
                CoverageVNode = {VNodeIndex, Node},
                case length(KeySpaces) < NVal of
                    true ->
                        %% Get the VNode index of each keyspace to
                        %% use to filter results from this VNode.
                        KeySpaceIndexes = [(((KeySpaceIndex+1) rem
                                             PartitionCount) * RingIndexInc) ||
                                              KeySpaceIndex <- KeySpaces],
                        {CoverageVNode, [{VNodeIndex, KeySpaceIndexes} | Acc]};
                    false ->
                        {CoverageVNode, Acc}
                end
        end,
    %% The offset value serves as a tiebreaker in the
    %% compare_vnode_keyspaces function and is used to distribute work
    %% to different sets of VNodes.
    CoverageResult = find_minimal_coverage(AllKeySpaces,
                                           Offset,
                                           NVal,
                                           PartitionCount,
                                           UnavailableVnodes,
                                           lists:min([PVC, NVal]),
                                           []),
    case CoverageResult of
        {ok, CoveragePlan} ->
            %% Assemble the data structures required for
            %% executing the coverage operation.
            lists:mapfoldl(CoverageVNodeFun, [], CoveragePlan);
        {insufficient_vnodes_available, _KeySpace, PartialCoverage}  ->
            case VNodeTarget of
                allup ->
                    %% The allup indicator means generate a coverage plan
                    %% for any available VNodes.
                    lists:mapfoldl(CoverageVNodeFun, [], PartialCoverage);
                all ->
                    {error, insufficient_vnodes_available}
            end
    end.

%% ====================================================================
%% Internal functions
%% ====================================================================

%% @private
-spec identify_unavailable_vnodes(chashbin:chashbin(), pos_integer(), atom()) -> list(vnode_id()).
identify_unavailable_vnodes(CHBin, PartitionSize, Service) ->
    %% Get a list of the VNodes owned by any unavailable nodes
    DownVNodes = [Index ||
                     {Index, _Node}
                         <- riak_core_apl:offline_owners(Service, CHBin)],
    [(DownVNode div PartitionSize) || DownVNode <- DownVNodes].

%% @private
merge_coverage_results({VnodeId, PartitionIds}, Acc) ->
    case proplists:get_value(VnodeId, Acc) of
        undefined ->
            [{VnodeId, PartitionIds} | Acc];
        MorePartitionIds ->
            UniqueValues =
                lists:usort(PartitionIds ++ MorePartitionIds),
            [{VnodeId, UniqueValues} |
             proplists:delete(VnodeId, Acc)]
    end.


%% @private
%% @doc Generates a minimal set of vnodes and partitions to find the requested data
-spec find_minimal_coverage(list(partition_id()), non_neg_integer(), non_neg_integer(), non_neg_integer(), list(partition_id()), non_neg_integer(), list({vnode_id(), list(partition_id())})) -> {ok, list({vnode_id(), list(partition_id())})} | {error, term()}.
find_minimal_coverage(_AllKeySpaces, _Offset, _NVal, _PartitionCount,
              _UnavailableKeySpaces, 0, Results) ->
    {ok, Results};
find_minimal_coverage(AllKeySpaces,
                      Offset,
                      NVal,
                      PartitionCount,
                      UnavailableKeySpaces,
                      PVC,
                      ResultsAcc) ->
    %% Calculate the available keyspaces. The list of
    %% keyspaces for each vnode that have already been
    %% covered by the plan are subtracted from the complete
    %% list of keyspaces so that coverage plans that
    %% want to cover more one preflist vnode work out
    %% correctly.
    AvailableKeySpaces = [{((VNode+Offset) rem PartitionCount),
                           VNode,
                           n_keyspaces(VNode, NVal, PartitionCount) --
                               proplists:get_value(VNode, ResultsAcc, [])}
                          || VNode <- (AllKeySpaces -- UnavailableKeySpaces)],
    case find_coverage_vnodes(ordsets:from_list(AllKeySpaces),
                              AvailableKeySpaces,
                              ResultsAcc) of
        {ok, CoverageResults} ->
            UpdatedResults =
                lists:foldl(fun merge_coverage_results/2, ResultsAcc, CoverageResults),
            find_minimal_coverage(AllKeySpaces,
                                  Offset,
                                  NVal,
                                  PartitionCount,
                                  UnavailableKeySpaces,
                                  PVC-1,
                                  UpdatedResults);
        Error ->
            Error
    end.

%% @private
%% @doc Find the N key spaces for a VNode
-spec n_keyspaces(vnode_id(), pos_integer(), pos_integer()) -> list(partition_id()).
n_keyspaces(VNode, N, PartitionCount) ->
    ordsets:from_list([X rem PartitionCount ||
                          X <- lists:seq(PartitionCount + VNode - N,
                                         PartitionCount + VNode - 1)]).

%% @private
%% @doc Find a minimal set of covering VNodes.
%% All parameters and return values are expressed as IDs in the [0,
%% RingSize) range.
%% Takes:
%%   A list of all partition IDs still needed for coverage
%%   A list of available partition IDs
%%   An accumulator for results
%% Returns a list of {vnode_id, [partition_id,...]} tuples.
-spec find_coverage_vnodes(list(partition_id()), list(partition_id()), list({vnode_id(), list(partition_id())})) -> list({vnode_id(), list(partition_id())}).
find_coverage_vnodes([], _, Coverage) ->
    {ok, lists:sort(Coverage)};
find_coverage_vnodes(KeySpaces, [], Coverage) ->
    {insufficient_vnodes_available, KeySpaces, lists:sort(Coverage)};
find_coverage_vnodes(KeySpaces, Available, Coverage) ->
    case find_best_vnode_for_keyspace(KeySpaces, Available) of
        {error, no_coverage} ->
            %% Bail
            find_coverage_vnodes(KeySpaces, [], Coverage);
        VNode ->
            {value, {_, VNode, Covers}, UpdAvailable} = lists:keytake(VNode, 2, Available),
            UpdCoverage = [{VNode, ordsets:intersection(KeySpaces, Covers)} | Coverage],
            UpdKeySpaces = ordsets:subtract(KeySpaces, Covers),
            find_coverage_vnodes(UpdKeySpaces, UpdAvailable, UpdCoverage)
    end.

%% @private
%% @doc Find the vnode that covers the most of the remaining
%% keyspace. Use VNode ID + offset (determined by request ID) as the
%% tiebreaker
find_best_vnode_for_keyspace(KeySpace, Available) ->
    CoverCount = [{covers(KeySpace, CoversKeys), VNode, TieBreaker} ||
                     {TieBreaker, VNode, CoversKeys} <- Available],
    interpret_best_vnode(hd(lists:sort(fun compare_vnode_keyspaces/2,
                                       CoverCount))).

%% @private
interpret_best_vnode({0, _, _}) ->
    {error, no_coverage};
interpret_best_vnode({_, VNode, _}) ->
    VNode.

%% @private
%% There is a potential optimization here once
%% the partition claim logic has been changed
%% so that physical nodes claim partitions at
%% regular intervals around the ring.
%% The optimization is for the case
%% when the partition count is not evenly divisible
%% by the n_val and when the coverage counts of the
%% two arguments are equal and a tiebreaker is
%% required to determine the sort order. In this
%% case, choosing the lower node for the final
%% vnode to complete coverage will result
%% in an extra physical node being involved
%% in the coverage plan so the optimization is
%% to choose the upper node to minimize the number
%% of physical nodes.
compare_vnode_keyspaces({CA, _VA, TBA}, {CB, _VB, TBB}) ->
    if
        CA > CB -> %% Descending sort on coverage
            true;
        CA < CB ->
            false;
        true ->
            TBA < TBB %% If equal coverage choose the lower node.
    end.

%% @private
%% @doc Count how many of CoversKeys appear in KeySpace
covers(KeySpace, CoversKeys) ->
    ordsets:size(ordsets:intersection(KeySpace, CoversKeys)).

%% @private
%% Determines the number of non-mask bits in the 2^160 keyspace.
%% Note that PartitionCount does not have to be ring size; we could be
%% creating a coverage plan for subpartitions
data_bits(PartitionCount) ->
    160 - round(math:log(PartitionCount) / math:log(2)).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

-define(SET(X), ordsets:from_list(X)).

bits_test() ->
    %% 160 - log2(8)
    ?assertEqual(157, data_bits(8)),
    %% 160 - log2(65536)
    ?assertEqual(144, data_bits(65536)).

n_keyspaces_test() ->
    %% First vnode in a cluster with ring size 64 should (with nval 3)
    %% cover keyspaces 61-63
    ?assertEqual([61, 62, 63], n_keyspaces(0, 3, 64)),
    %% 4th vnode in a cluster with ring size 8 should (with nval 5)
    %% cover the first 3 and last 2 keyspaces
    ?assertEqual([0, 1, 2, 6, 7], n_keyspaces(3, 5, 8)),
    %% First vnode in a cluster with a single partition should (with
    %% any nval) cover the only keyspace
    ?assertEqual([0], n_keyspaces(0, 1, 1)).

covers_test() ->
    %% Count the overlap between the sets
    ?assertEqual(2, covers(?SET([1, 2]),
                           ?SET([0, 1, 2, 3]))),
    ?assertEqual(1, covers(?SET([1, 2]),
                           ?SET([0, 1]))),
    ?assertEqual(0, covers(?SET([1, 2, 3]),
                           ?SET([4, 5, 6, 7]))).

best_vnode_test() ->
    %% Given two vnodes 0 and 7, pick 0 because it has more of the
    %% desired keyspaces
    ?assertEqual(0, find_best_vnode_for_keyspace(
                      ?SET([0, 1, 2, 3, 4]),
                      [{2, 0, ?SET([6, 7, 0, 1, 2])},
                       {1, 7, ?SET([5, 6, 7, 0, 1])}])),
    %% Given two vnodes 0 and 7, pick 7 because they cover the same
    %% keyspaces and 7 has the lower tiebreaker
    ?assertEqual(7, find_best_vnode_for_keyspace(
                      ?SET([0, 1, 2, 3, 4]),
                      [{2, 0, ?SET([6, 7, 0, 1, 2])},
                       {1, 7, ?SET([6, 7, 0, 1, 2])}])),
    %% Given two vnodes 0 and 7, pick 0 because they cover the same
    %% keyspaces and 0 has the lower tiebreaker
    ?assertEqual(0, find_best_vnode_for_keyspace(
                      ?SET([0, 1, 2, 3, 4]),
                      [{2, 0, ?SET([6, 7, 0, 1, 2])},
                       {3, 7, ?SET([6, 7, 0, 1, 2])}])).

create_plan_test_() ->
    {setup,
     fun cpsetup/0,
     fun cpteardown/1,
     fun test_create_plan/1}.

cpsetup() ->
    meck:new(riak_core_node_watcher, []),
    meck:expect(riak_core_node_watcher, nodes, 1, [mynode]),
    CHash = chash:fresh(8, mynode),
    chashbin:create(CHash).

cpteardown(_) ->
    meck:unload().

test_create_plan(CHBin) ->
    Plan =
        {[{1278813932664540053428224228626747642198940975104,
           mynode},
          {730750818665451459101842416358141509827966271488,
           mynode},
          {365375409332725729550921208179070754913983135744,
           mynode}],
         [{730750818665451459101842416358141509827966271488,
           [548063113999088594326381812268606132370974703616,
            730750818665451459101842416358141509827966271488]}]},
    [?_assertEqual(Plan,
                   create_traditional_plan(all, 3, 1, 1234, riak_kv, CHBin))].

-endif.
