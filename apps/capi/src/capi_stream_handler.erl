-module(capi_stream_handler).
-behaviour(cowboy_stream).

-dialyzer(no_undefined_callbacks).

-define(APP, capi).

%% callback exports

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-type state() :: #{
    next := any()
}.

%% callbacks

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #{next => Next}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
    -> {cowboy_stream:commands(), State} when State::state().
data(StreamID, IsFin, Data, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {Commands0, State#{next => Next}}.

-spec info(cowboy_stream:streamid(), any(), State)
    -> {cowboy_stream:commands(), State} when State::state().
info(StreamID, {response, _, _, _} = Info, #{next := Next0} = State) ->
    Resp1 = handle_response(Info),
    {Commands0, Next} = cowboy_stream:info(StreamID, Resp1, Next0),
    {Commands0, State#{next => Next}};
info(StreamID, Info, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(StreamID, Reason, #{next := Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    Resp1 = handle_response(Resp),
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp1, Opts).

%% private functions

handle_response({response, Code, Headers, Req}) when Code >= 500 ->
    send_oops_resp(Code, Headers, get_oops_body_safe(Code), Req);
handle_response({response, _, _, _} = Resp) ->
    Resp.

%% cowboy_req:reply/4 has a faulty spec in case of response body fun.
-dialyzer({[no_contracts, no_fail_call], send_oops_resp/4}).

send_oops_resp(Code, Headers, undefined, Req) ->
    {response, Code, Headers, Req};
send_oops_resp(Code, Headers, File, Req) ->
    FileSize = filelib:file_size(File),
    F = fun(Socket, Transport) ->
        case Transport:sendfile(Socket, File) of
            {ok, _} ->
                ok;
            {error, Error} ->
                _ = logger:warning("Failed to send oops body: ~p", [Error]),
                ok
        end
    end,
    Headers1 = lists:foldl(
        fun({K, V}, Acc) -> lists:keystore(K, 1, Acc, {K, V}) end,
        Headers,
        [
            {<<"content-type">>, <<"text/plain; charset=utf-8">>},
            {<<"content-length">>, integer_to_list(FileSize)}
        ]
    ),
    Req1 = cowboy_req:reply(Code, Headers1, {FileSize, F}, Req),
    {response, Code, Headers1, Req1}.

get_oops_body_safe(Code) ->
    try get_oops_body(Code)
    catch
        Error:Reason ->
            _ = logger:warning("Invalid oops body config for code: ~p. Error: ~p:~p", [Code, Error, Reason]),
            undefined
    end.

get_oops_body(Code) ->
    genlib_map:get(Code, genlib_app:env(?APP, oops_bodies, #{}), undefined).
