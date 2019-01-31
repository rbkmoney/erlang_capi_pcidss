-module(capi_utils).

-export([logtag_process/2]).
-export([base64url_to_map/1]).
-export([map_to_base64url/1]).

-export([parse_deadline/1]).

-export([to_universal_time/1]).

-define(MAX_DEADLINE_TIME, 1*60*1000). % 1 min

-spec logtag_process(atom(), any()) -> ok.

logtag_process(Key, Value) when is_atom(Key) ->
    % TODO preformat into binary?
    lager:md(orddict:store(Key, Value, lager:md())).

-spec base64url_to_map(binary()) -> map() | no_return().
base64url_to_map(Base64) when is_binary(Base64) ->
    try jsx:decode(base64url:decode(Base64), [return_maps])
    catch
        Class:Reason ->
            _ = lager:debug("decoding base64 ~p to map failed with ~p:~p", [Base64, Class, Reason]),
            erlang:error(badarg)
    end.

-spec map_to_base64url(map()) -> binary() | no_return().
map_to_base64url(Map) when is_map(Map) ->
    try base64url:encode(jsx:encode(Map))
    catch
        Class:Reason ->
            _ = lager:debug("encoding map ~p to base64 failed with ~p:~p", [Map, Class, Reason]),
            erlang:error(badarg)
    end.

-spec to_universal_time(Timestamp :: binary()) -> TimestampUTC :: binary().
to_universal_time(Timestamp) ->
    {ok, {Date, Time, Usec, TZOffset}} = rfc3339:parse(Timestamp),
    Seconds = calendar:datetime_to_gregorian_seconds({Date, Time}),
    %% The following crappy code is a dialyzer workaround
    %% for the wrong rfc3339:parse/1 spec.
    {DateUTC, TimeUTC} = calendar:gregorian_seconds_to_datetime(
        case TZOffset of
            _ when is_integer(TZOffset) ->
                Seconds - (60 * TZOffset);
            _ ->
                Seconds
        end
    ),
    {ok, TimestampUTC} = rfc3339:format({DateUTC, TimeUTC, Usec, 0}),
    TimestampUTC.

-spec parse_deadline
    (binary()) -> {ok, woody:deadline()} | {error, bad_deadline};
    (undefined) -> {ok, undefined}.
parse_deadline(undefined) ->
    {ok, undefined};
parse_deadline(DeadlineStr) ->
    Parsers = [
        fun try_parse_woody_default/1,
        fun try_parse_relative/1
    ],
    try_parse_deadline(DeadlineStr, Parsers).
%%
%% Internals
%%
try_parse_deadline(_DeadlineStr, []) ->
    {error, bad_deadline};
try_parse_deadline(DeadlineStr, [P | Parsers]) ->
    case P(DeadlineStr) of
        {ok, _Deadline} = Result ->
            Result;
        {error, bad_deadline} ->
            try_parse_deadline(DeadlineStr, Parsers)
    end.
try_parse_woody_default(DeadlineStr) ->
    try
        Deadline = woody_deadline:from_binary(to_universal_time(DeadlineStr)),
        NewDeadline = clamp_max_deadline(woody_deadline:to_timeout(Deadline)),
        {ok, woody_deadline:from_timeout(NewDeadline)}
    catch
        error:{bad_deadline, _Reason} ->
            {error, bad_deadline};
        error:{badmatch, {error, baddate}} ->
            {error, bad_deadline};
        error:deadline_reached ->
            {error, bad_deadline}
    end.
try_parse_relative(DeadlineStr) ->
    %% deadline string like '1ms', '30m', '2.6h' etc
    case re:split(DeadlineStr, <<"^(\\d+\\.\\d+|\\d+)([a-z]+)$">>) of
        [<<>>, NumberStr, Unit, <<>>] ->
            Number = genlib:to_float(NumberStr),
            try_parse_relative(Number, Unit);
        _Other ->
            {error, bad_deadline}
    end.
try_parse_relative(Number, Unit) ->
    case unit_factor(Unit) of
        {ok, Factor} ->
            Timeout = erlang:round(Number * Factor),
            {ok, woody_deadline:from_timeout(clamp_max_deadline(Timeout))};
        {error, _Reason} ->
            {error, bad_deadline}
    end.
unit_factor(<<"ms">>) ->
    {ok, 1};
unit_factor(<<"s">>) ->
    {ok, 1000};
unit_factor(<<"m">>) ->
    {ok, 1000 * 60};
unit_factor(_Other) ->
    {error, unknown_unit}.

clamp_max_deadline(Value) when is_integer(Value)->
    MaxDeadline = genlib_app:env(capi_pcidss, max_deadline, ?MAX_DEADLINE_TIME),
    case Value > MaxDeadline of
        true ->
            MaxDeadline;
        false ->
            Value
    end.

%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

-spec to_universal_time_test() -> _.
to_universal_time_test() ->
    ?assertEqual(<<"2017-04-19T13:56:07Z">>,        to_universal_time(<<"2017-04-19T13:56:07Z">>)),
    ?assertEqual(<<"2017-04-19T13:56:07.530000Z">>, to_universal_time(<<"2017-04-19T13:56:07.53Z">>)),
    ?assertEqual(<<"2017-04-19T10:36:07.530000Z">>, to_universal_time(<<"2017-04-19T13:56:07.53+03:20">>)),
    ?assertEqual(<<"2017-04-19T17:16:07.530000Z">>, to_universal_time(<<"2017-04-19T13:56:07.53-03:20">>)).

-spec parse_deadline_test() -> _.
parse_deadline_test() ->
    Deadline = woody_deadline:from_timeout(3000),
    BinDeadline = woody_deadline:to_binary(Deadline),
    {ok, {_, _}} = parse_deadline(BinDeadline),
    ?assertEqual({error, bad_deadline}, parse_deadline(<<"2017-04-19T13:56:07.53Z">>)),
    {ok, {_, _}} = parse_deadline(<<"15s">>),
    {ok, {_, _}} = parse_deadline(<<"15m">>),
    {error, bad_deadline} = parse_deadline(<<"15h">>).

-endif.
