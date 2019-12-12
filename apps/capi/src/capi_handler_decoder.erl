-module(capi_handler_decoder).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_payment_tool_token_thrift.hrl").

-export([decode_disposable_payment_resource/1]).

-export([decode_last_digits/1]).
-export([decode_masked_pan/2]).

-export([convert_crypto_currency_to_swag/1]).
-export([convert_crypto_currency_from_swag/1]).

-export_type([decode_data/0]).

-type decode_data() :: #{binary() => term()}.

decode_payment_tool_token({CardType, BankCard})
when CardType =:= bank_card orelse CardType =:= tokenized_bank_card ->
    PaymentToolToken = {bank_card_payload, #ptt_BankCardPayload{
        bank_card = BankCard
    }},
    encode_payment_tool_token(PaymentToolToken);
decode_payment_tool_token({payment_terminal, PaymentTerminal}) ->
    PaymentToolToken = {payment_terminal_payload, #ptt_PaymentTerminalPayload{
        payment_terminal = PaymentTerminal
    }},
    encode_payment_tool_token(PaymentToolToken);
decode_payment_tool_token({digital_wallet, DigitalWallet}) ->
    PaymentToolToken = {digital_wallet_payload, #ptt_DigitalWalletPayload{
        digital_wallet = DigitalWallet
    }},
    encode_payment_tool_token(PaymentToolToken);
decode_payment_tool_token({crypto_currency, CryptoCurrency}) ->
    PaymentToolToken = {crypto_currency_payload, #ptt_CryptoCurrencyPayload{
        crypto_currency = CryptoCurrency
    }},
    encode_payment_tool_token(PaymentToolToken);
decode_payment_tool_token({mobile_commerce, MobileCommerce}) ->
    PaymentToolToken = {mobile_commerce_payload, #ptt_MobileCommercePayload {
        mobile_commerce = MobileCommerce
    }},
    encode_payment_tool_token(PaymentToolToken).

encode_payment_tool_token(PaymentToolToken) ->
    ThriftType = {struct, union, {dmsl_payment_tool_token_thrift, 'PaymentToolToken'}},
    {ok, EncodedToken} = lechiffre:encode(ThriftType, PaymentToolToken),
    TokenVersion = payment_tool_token_version(),
    base64url:encode(<<TokenVersion/binary, EncodedToken/binary>>).

payment_tool_token_version() ->
    <<"v1">>.

decode_payment_tool_details({CardType, V})
when CardType =:= bank_card orelse CardType =:= tokenized_bank_card ->
    decode_bank_card_details({CardType, V}, #{<<"detailsType">> => <<"PaymentToolDetailsBankCard">>});
decode_payment_tool_details({payment_terminal, V}) ->
    decode_payment_terminal_details(V, #{<<"detailsType">> => <<"PaymentToolDetailsPaymentTerminal">>});
decode_payment_tool_details({digital_wallet, V}) ->
    decode_digital_wallet_details(V, #{<<"detailsType">> => <<"PaymentToolDetailsDigitalWallet">>});
decode_payment_tool_details({crypto_currency, CryptoCurrency}) ->
    #{
        <<"detailsType">> => <<"PaymentToolDetailsCryptoWallet">>,
        <<"cryptoCurrency">> => convert_crypto_currency_to_swag(CryptoCurrency)
    };
decode_payment_tool_details({mobile_commerce, MobileCommerce}) ->
    #domain_MobileCommerce{
        phone = Phone
    } = MobileCommerce,
    PhoneNumber = gen_phone_number(decode_mobile_phone(Phone)),
    #{
        <<"detailsType">> => <<"PaymentToolDetailsMobileCommerce">>,
        <<"phoneNumber">> => mask_phone_number(PhoneNumber)
    }.

decode_bank_card_details({_, BankCard} = Card, V) ->
    LastDigits = decode_last_digits(BankCard#domain_BankCard.masked_pan),
    Bin = get_bank_card_bin(Card),
    capi_handler_utils:merge_and_compact(V, #{
        <<"last4">>          => LastDigits,
        <<"first6">>         => Bin,
        <<"cardNumberMask">> => decode_masked_pan(Bin, LastDigits),
        <<"paymentSystem" >> => genlib:to_binary(BankCard#domain_BankCard.payment_system),
        <<"tokenProvider" >> => decode_token_provider(BankCard#domain_BankCard.token_provider)
    }).

get_bank_card_bin({bank_card, BankCard}) ->
    BankCard#domain_BankCard.bin;
get_bank_card_bin({tokenized_bank_card, _}) ->
    undefined.

decode_token_provider(Provider) when Provider /= undefined ->
    genlib:to_binary(Provider);
decode_token_provider(undefined) ->
    undefined.

decode_payment_terminal_details(#domain_PaymentTerminal{terminal_type = Type}, V) ->
    V#{
        <<"provider">> => genlib:to_binary(Type)
    }.

decode_digital_wallet_details(#domain_DigitalWallet{provider = qiwi, id = ID}, V) ->
    V#{
        <<"digitalWalletDetailsType">> => <<"DigitalWalletDetailsQIWI">>,
        <<"phoneNumberMask"         >> => mask_phone_number(ID)
    }.

mask_phone_number(PhoneNumber) ->
    genlib_string:redact(PhoneNumber, <<"^\\+\\d(\\d{1,10}?)\\d{2,4}$">>).

-spec decode_disposable_payment_resource(capi_handler_encoder:encode_data()) ->
    decode_data().

decode_disposable_payment_resource(Resource) ->
    #domain_DisposablePaymentResource{payment_tool = PaymentTool, payment_session_id = SessionID} = Resource,
    ClientInfo = decode_client_info(Resource#domain_DisposablePaymentResource.client_info),
    #{
        <<"paymentToolToken"  >> => decode_payment_tool_token(PaymentTool),
        <<"paymentSession"    >> => capi_handler_utils:wrap_payment_session(ClientInfo, SessionID),
        <<"paymentToolDetails">> => decode_payment_tool_details(PaymentTool),
        <<"clientInfo"        >> => ClientInfo
    }.

decode_client_info(undefined) ->
    undefined;
decode_client_info(ClientInfo) ->
    #{
        <<"fingerprint">> => ClientInfo#domain_ClientInfo.fingerprint,
        <<"ip"         >> => ClientInfo#domain_ClientInfo.ip_address
    }.

%%

-define(PAN_LENGTH, 16).

-spec decode_masked_pan(binary() | undefined, binary()) ->
    binary().

decode_masked_pan(undefined, LastDigits) ->
    decode_masked_pan(<<>>, LastDigits);
decode_masked_pan(Bin, LastDigits) ->
    Mask = binary:copy(<<"*">>, ?PAN_LENGTH - byte_size(Bin) - byte_size(LastDigits)),
    <<Bin/binary, Mask/binary, LastDigits/binary>>.

-define(MASKED_PAN_MAX_LENGTH, 4).

-spec decode_last_digits(binary()) ->
    binary().

decode_last_digits(MaskedPan) when byte_size(MaskedPan) > ?MASKED_PAN_MAX_LENGTH ->
    binary:part(MaskedPan, {byte_size(MaskedPan), -?MASKED_PAN_MAX_LENGTH});
decode_last_digits(MaskedPan) ->
    MaskedPan.

-spec convert_crypto_currency_from_swag(binary()) -> atom().

convert_crypto_currency_from_swag(<<"bitcoinCash">>) ->
    bitcoin_cash;
convert_crypto_currency_from_swag(CryptoCurrency) when is_binary(CryptoCurrency) ->
    binary_to_existing_atom(CryptoCurrency, utf8).

-spec convert_crypto_currency_to_swag(atom()) -> binary().

convert_crypto_currency_to_swag(bitcoin_cash) ->
    <<"bitcoinCash">>;
convert_crypto_currency_to_swag(CryptoCurrency) when is_atom(CryptoCurrency) ->
    atom_to_binary(CryptoCurrency, utf8).

decode_mobile_phone(#domain_MobilePhone{cc = Cc, ctn = Ctn}) ->
    #{<<"cc">> => Cc, <<"ctn">> => Ctn}.

gen_phone_number(#{<<"cc">> := Cc, <<"ctn">> := Ctn}) ->
    <<"+", Cc/binary, Ctn/binary>>.
