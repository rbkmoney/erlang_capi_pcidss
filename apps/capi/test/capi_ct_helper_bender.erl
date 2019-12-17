-module(capi_ct_helper_bender).

-include_lib("bender_proto/include/bender_thrift.hrl").

-export([get_result/1]).
-export([get_result/2]).
-export([get_internal_id/1]).

-spec get_result(binary()) -> bender_thrift:bender_GenerationResult().
-spec get_result(binary(), msgpack_thrift:'Value'() | undefined) -> bender_thrift:bender_GenerationResult().
-spec get_internal_id(bender_thrift:bender_ConstantSchema()) -> binary().

get_result(ID) ->
    get_result(ID, undefined).

get_result(ID, Context) ->
    #bender_GenerationResult{
        internal_id = ID,
        context     = Context
}.

get_internal_id(#bender_ConstantSchema{internal_id = ID}) ->
    ID.
