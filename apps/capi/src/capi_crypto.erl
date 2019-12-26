-module(capi_crypto).

-include_lib("damsel/include/dmsl_payment_tool_token_thrift.hrl").

-type encrypted_token()     :: binary().
-type payment_tool()        :: dmsl_domain_thrift:'PaymentTool'().
-type payment_tool_token()  :: dmsl_payment_tool_token_thrift:'PaymentToolToken'().


-export_type([encrypted_token/0]).

-export([create_encrypted_payment_tool_token/2]).

-spec create_encrypted_payment_tool_token(binary(), payment_tool()) ->
    encrypted_token().

create_encrypted_payment_tool_token(IdempotentKey, PaymentTool) ->
    PaymentToolToken = encode_payment_tool_token(PaymentTool),
    EncryptionParams = create_encryption_params(IdempotentKey),
    ThriftType = {struct, union, {dmsl_payment_tool_token_thrift, 'PaymentToolToken'}},
    {ok, EncodedToken} = lechiffre:encode(ThriftType, PaymentToolToken, EncryptionParams),
    TokenVersion = payment_tool_token_version(),
    <<TokenVersion/binary, EncodedToken/binary>>.

%% Internal

payment_tool_token_version() ->
    <<"v1">>.

create_encryption_params(IdempotentKey) ->
    #{iv => lechiffre:compute_iv(IdempotentKey)}.

-spec encode_payment_tool_token(payment_tool()) ->
    payment_tool_token().

encode_payment_tool_token({bank_card, BankCard}) ->
    {bank_card_payload, #ptt_BankCardPayload{
        bank_card = BankCard
    }};
encode_payment_tool_token({payment_terminal, PaymentTerminal}) ->
    {payment_terminal_payload, #ptt_PaymentTerminalPayload{
        payment_terminal = PaymentTerminal
    }};
encode_payment_tool_token({digital_wallet, DigitalWallet}) ->
    {digital_wallet_payload, #ptt_DigitalWalletPayload{
        digital_wallet = DigitalWallet
    }};
encode_payment_tool_token({crypto_currency, CryptoCurrency}) ->
    {crypto_currency_payload, #ptt_CryptoCurrencyPayload{
        crypto_currency = CryptoCurrency
    }};
encode_payment_tool_token({mobile_commerce, MobileCommerce}) ->
    {mobile_commerce_payload, #ptt_MobileCommercePayload {
        mobile_commerce = MobileCommerce
    }}.
