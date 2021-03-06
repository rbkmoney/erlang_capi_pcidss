-module(capi_auth).

-export([get_consumer/1]).
-export([get_operation_access/2]).
-export([get_access_config/0]).

-type consumer() :: client | merchant | provider.

%%

-type request_data() :: #{atom() | binary() => term()}.

-spec get_operation_access(swag_server:operation_id(), request_data()) -> [{uac_acl:scope(), uac_acl:permission()}].
get_operation_access('CreatePaymentResource', _) ->
    [{[payment_resources], write}].

-spec get_consumer(uac:claims()) -> consumer().
get_consumer(Claims) ->
    case maps:get(<<"cons">>, Claims, <<"merchant">>) of
        <<"merchant">> -> merchant;
        <<"client">> -> client;
        <<"provider">> -> provider
    end.

-spec get_access_config() -> map().
get_access_config() ->
    #{
        domain_name => <<"common-api">>,
        resource_hierarchy => get_resource_hierarchy()
    }.

get_resource_hierarchy() ->
    #{
        payment_resources => #{}
    }.
