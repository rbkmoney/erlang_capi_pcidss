-module(capi_handler).

-include_lib("dmsl/include/dmsl_payment_processing_thrift.hrl").
-include_lib("dmsl/include/dmsl_domain_thrift.hrl").
-include_lib("dmsl/include/dmsl_merch_stat_thrift.hrl").

-behaviour(swag_server_logic_handler).

%% API callbacks
-export([authorize_api_key/2]).
-export([handle_request/3]).

%% Handler behaviour

-export_type([operation_id/0]).
-export_type([request_data/0]).
-export_type([request_context/0]).
-export_type([response/0]).
-export_type([processing_context/0]).

-callback process_request(
    OperationID :: operation_id(),
    Req         :: request_data(),
    Context     :: processing_context()
) ->
    {ok | error, response() | noimpl}.

-import(capi_handler_utils, [logic_error/2, server_error/1]).

%% @WARNING Must be refactored in case of different classes of users using this API
-define(REALM, <<"external">>).

-spec authorize_api_key(swag_server:operation_id(), swag_server:api_key()) ->
    Result :: false | {true, uac:context()}.

authorize_api_key(OperationID, ApiKey) ->
    scoper:scope(capi_handler, #{operation_id => OperationID}, fun() ->
        case uac:authorize_api_key(ApiKey, get_verification_options()) of
            {ok, Context} ->
                {true, Context};
            {error, _Error} ->
                false
        end
    end).

-type request_data()        :: #{atom() | binary() => term()}.

-type operation_id()        :: swag_server:operation_id().
-type request_context()     :: swag_server:request_context().
-type response()            :: swag_server_logic_handler:response().
-type processing_context()  :: #{
    swagger_context := swag_server:request_context(),
    woody_context   := woody_context:ctx()
}.

get_handlers() ->
    [
        capi_handler_tokens
    ].

get_verification_options() ->
    #{}.

-spec handle_request(
    OperationID :: operation_id(),
    Req         :: request_data(),
    SwagContext :: request_context()
) ->
    {ok | error,   response()}.

handle_request(OperationID, Req, SwagContext = #{auth_context := AuthContext}) ->
    _ = lager:info("Processing request ~p", [OperationID]),
    try
        ok = scoper:add_scope(capi_handler, #{operation_id => OperationID}),
        WoodyContext = attach_deadline(Req, create_woody_context(Req, AuthContext)),
        OperationACL = capi_auth:get_operation_access(OperationID, Req),
        case uac:authorize_operation(OperationACL, AuthContext) of
            ok ->
                Context = create_processing_context(SwagContext, WoodyContext),
                process_request(OperationID, Req, Context, get_handlers());
            {error, _} = Error ->
                _ = lager:info("Operation ~p authorization failed due to ~p", [OperationID, Error]),
                {ok, {401, [], undefined}}
        end
    catch
        error:{woody_error, {Source, Class, Details}} ->
            process_woody_error(Source, Class, Details);
        throw:{bad_deadline, _Deadline} ->
            {ok, logic_error(invalidDeadline, <<"Invalid data in X-Request-Deadline header">>)};
        throw:{handler_function_clause, _OperationID} ->
            {ok, {501, [], <<"Error processing requested operation">>}}
    after
        ok = scoper:remove_scope(capi_handler)
    end.

-spec process_request(
    OperationID :: operation_id(),
    Req         :: request_data(),
    Context     :: processing_context(),
    Handlers    :: list(module())
) ->
    {ok | error,   response()}.

process_request(OperationID, _Req, _Context, []) ->
    _ = lager:info("Operation ~p failed due to missing handler", [OperationID]),
    erlang:throw({handler_function_clause, OperationID});
process_request(OperationID, Req, Context, [Handler | Rest]) ->
    case Handler:process_request(OperationID, Req, Context) of
        {error, noimpl} ->
            process_request(OperationID, Req, Context, Rest);
        Response ->
            Response
    end.

%%

create_processing_context(SwaggerContext, WoodyContext) ->
    #{
        woody_context   => WoodyContext,
        swagger_context => SwaggerContext
    }.

create_woody_context(#{'X-Request-ID' := RequestID}, AuthContext) ->
    RpcID = #{trace_id := TraceID} = woody_context:new_rpc_id(genlib:to_binary(RequestID)),
    ok = scoper:add_meta(#{request_id => RequestID, trace_id => TraceID}),
    woody_user_identity:put(collect_user_identity(AuthContext), woody_context:new(RpcID)).

collect_user_identity(AuthContext) ->
    genlib_map:compact(#{
        id       => capi_auth:get_subject_id(AuthContext),
        realm    => ?REALM,
        email    => capi_auth:get_claim(<<"email">>, AuthContext, undefined),
        username => capi_auth:get_claim(<<"name">> , AuthContext, undefined)
    }).

attach_deadline(#{'X-Request-Deadline' := undefined}, Context) ->
    Context;
attach_deadline(#{'X-Request-Deadline' := Header}, Context) ->
    case capi_utils:parse_deadline(Header) of
        {ok, Deadline} when Deadline /= undefined ->
            woody_context:set_deadline(Deadline, Context);
        _ ->
            throw({bad_deadline, Header})
    end.

process_woody_error(_Source, result_unexpected   , _Details) ->
    {error, server_error(500)};
process_woody_error(_Source, resource_unavailable, _Details) ->
    {error, server_error(503)};
process_woody_error(_Source, result_unknown      , _Details) ->
    {error, server_error(504)}.
