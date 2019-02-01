-module(capi_auth).

-export([authorize_api_key/2]).
-export([authorize_operation/3]).
-export([issue_invoice_access_token/2]).
-export([issue_invoice_access_token/3]).
-export([issue_invoice_template_access_token/2]).
-export([issue_invoice_template_access_token/3]).
-export([issue_customer_access_token/2]).
-export([issue_customer_access_token/3]).

-export([get_subject_id/1]).
-export([get_claims/1]).
-export([get_claim/2]).
-export([get_claim/3]).

-export([get_resource_hierarchy/0]).

-type context() :: capi_authorizer_jwt:t().
-type claims()  :: capi_authorizer_jwt:claims().

-export_type([context/0]).
-export_type([claims/0]).

-spec authorize_api_key(
    OperationID :: swag_server:operation_id(),
    ApiKey      :: swag_server:api_key()
) -> {true, Context :: context()} | false.

authorize_api_key(OperationID, ApiKey) ->
    case parse_api_key(ApiKey) of
        {ok, {Type, Credentials}} ->
            case authorize_api_key(OperationID, Type, Credentials) of
                {ok, Context} ->
                    {true, Context};
                {error, Error} ->
                    _ = log_auth_error(OperationID, Error),
                    false
            end;
        {error, Error} ->
            _ = log_auth_error(OperationID, Error),
            false
    end.

log_auth_error(OperationID, Error) ->
    lager:info("API Key authorization failed for ~p due to ~p", [OperationID, Error]).

-spec parse_api_key(ApiKey :: swag_server:api_key()) ->
    {ok, {bearer, Credentials :: binary()}} | {error, Reason :: atom()}.

parse_api_key(ApiKey) ->
    case ApiKey of
        <<"Bearer ", Credentials/binary>> ->
            {ok, {bearer, Credentials}};
        _ ->
            {error, unsupported_auth_scheme}
    end.

-spec authorize_api_key(
    OperationID :: swag_server:operation_id(),
    Type :: atom(),
    Credentials :: binary()
) ->
    {ok, Context :: context()} | {error, Reason :: atom()}.

authorize_api_key(_OperationID, bearer, Token) ->
    % NOTE
    % We are knowingly delegating actual request authorization to the logic handler
    % so we could gather more data to perform fine-grained access control.
    capi_authorizer_jwt:verify(Token).

%%

% TODO
% We need shared type here, exported somewhere in swagger app
-type request_data() :: #{atom() | binary() => term()}.

-spec authorize_operation(
    OperationID :: swag_server:operation_id(),
    Req :: request_data(),
    Auth :: capi_authorizer_jwt:t()
) ->
    ok | {error, unauthorized}.

authorize_operation(OperationID, Req, {{_SubjectID, ACL}, _}) ->
    Access = get_operation_access(OperationID, Req),
    case lists:all(
        fun ({Scope, Permission}) ->
            lists:member(Permission, capi_acl:match(Scope, ACL))
        end,
        Access
    ) of
        true ->
            ok;
        false ->
            {error, unauthorized}
    end.

%%

%% TODO
%% Hardcode for now, should pass it here probably as an argument
-define(DEFAULT_INVOICE_ACCESS_TOKEN_LIFETIME, 259200).
-define(DEFAULT_CUSTOMER_ACCESS_TOKEN_LIFETIME, 259200).

-spec issue_invoice_access_token(PartyID :: binary(), InvoiceID :: binary()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_invoice_access_token(PartyID, InvoiceID) ->
    issue_invoice_access_token(PartyID, InvoiceID, #{}).


-spec issue_invoice_access_token(PartyID :: binary(), InvoiceID :: binary(), claims()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_invoice_access_token(PartyID, InvoiceID, Claims) ->
    ACL = [
        {[{invoices, InvoiceID}]           , read},
        {[{invoices, InvoiceID}, payments] , read},
        {[{invoices, InvoiceID}, payments] , write},
        {[payment_resources]               , write}
    ],
    issue_access_token(PartyID, Claims, ACL, {lifetime, ?DEFAULT_INVOICE_ACCESS_TOKEN_LIFETIME}).

-spec issue_invoice_template_access_token(PartyID :: binary(), InvoiceTplID :: binary()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_invoice_template_access_token(PartyID, InvoiceID) ->
    issue_invoice_template_access_token(PartyID, InvoiceID, #{}).


-spec issue_invoice_template_access_token(PartyID :: binary(), InvoiceTplID :: binary(), claims()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_invoice_template_access_token(PartyID, InvoiceTplID, Claims) ->
    ACL = [
        {[party, {invoice_templates, InvoiceTplID}] , read},
        {[party, {invoice_templates, InvoiceTplID}, invoice_template_invoices] , write}
    ],
    issue_access_token(PartyID, Claims, ACL, unlimited).

-spec issue_customer_access_token(PartyID :: binary(), CustomerID :: binary()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_customer_access_token(PartyID, CustomerID) ->
    issue_customer_access_token(PartyID, CustomerID, #{}).

-spec issue_customer_access_token(PartyID :: binary(), CustomerID :: binary(), claims()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_customer_access_token(PartyID, CustomerID, Claims) ->
    ACL = [
        {[{customers, CustomerID}], read},
        {[{customers, CustomerID}, bindings], read},
        {[{customers, CustomerID}, bindings], write},
        {[payment_resources], write}
    ],
    issue_access_token(PartyID, Claims, ACL, {lifetime, ?DEFAULT_CUSTOMER_ACCESS_TOKEN_LIFETIME}).

-type acl() :: [{capi_acl:scope(), capi_acl:permission()}].

-spec issue_access_token(PartyID :: binary(), claims(), acl(), capi_authorizer_jwt:expiration()) ->
    {ok, capi_authorizer_jwt:token()} | {error, _}.

issue_access_token(PartyID, Claims, ACL, Expiration) ->
    capi_authorizer_jwt:issue({{PartyID, capi_acl:from_list(ACL)}, Claims}, Expiration).

-spec get_subject_id(context()) -> binary().

get_subject_id({{SubjectID, _ACL}, _}) ->
    SubjectID.

-spec get_claims(context()) -> claims().

get_claims({_Subject, Claims}) ->
    Claims.

-spec get_claim(binary(), context()) -> term().

get_claim(ClaimName, {_Subject, Claims}) ->
    maps:get(ClaimName, Claims).

-spec get_claim(binary(), context(), term()) -> term().

get_claim(ClaimName, {_Subject, Claims}, Default) ->
     maps:get(ClaimName, Claims, Default).

%%

-spec get_operation_access(swag_server:operation_id(), request_data()) ->
    [{capi_acl:scope(), capi_acl:permission()}].

get_operation_access('CreatePaymentResource'     , _) ->
    [{[payment_resources], write}].

-spec get_resource_hierarchy() -> #{atom() => map()}.

get_resource_hierarchy() ->
    #{
        party               => #{invoice_templates => #{invoice_template_invoices => #{}}},
        customers           => #{bindings => #{}},
        invoices            => #{payments => #{}},
        payment_resources => #{}
    }.
