%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2007 Mochi Media, Inc.

%% @doc HTTP server.

-module(mochiweb_http).
-author('bob@mochimedia.com').
-export([start/0, start/1, stop/0, stop/1]).
-export([loop/2, default_body/1]).
-export([after_response/2, reentry/1]).
-export([parse_range_request/1, range_skip_length/2]).

-define(REQUEST_RECV_TIMEOUT, 300000).   % timeout waiting for request line
-define(HEADERS_RECV_TIMEOUT, 30000). % timeout waiting for headers

-define(MAX_HEADERS, 1000).
-define(DEFAULTS, [{name, ?MODULE},
                   {port, 8888}]).

parse_options(Options) ->
    WwwLoop = proplists:get_value(loop, Options),
    WSLoop  = proplists:get_value(wsloop, Options),
    Loop = fun (S) ->
                   ?MODULE:loop(S, {WwwLoop,WSLoop})
           end,
    Options1 = [{loop, Loop}, {wsloop, Loop} | proplists:delete(loop, proplists:delete(wsloop, Options))],
    mochilists:set_defaults(?DEFAULTS, Options1).

stop() ->
    mochiweb_socket_server:stop(?MODULE).

stop(Name) ->
    mochiweb_socket_server:stop(Name).

start() ->
    start([{ip, "127.0.0.1"},
           {loop, {?MODULE, default_body}}]).

start(Options) ->
    mochiweb_socket_server:start(parse_options(Options)).

frm(Body) ->
    ["<html><head></head><body>"
     "<form method=\"POST\">"
     "<input type=\"hidden\" value=\"message\" name=\"hidden\"/>"
     "<input type=\"submit\" value=\"regular POST\">"
     "</form>"
     "<br />"
     "<form method=\"POST\" enctype=\"multipart/form-data\""
     " action=\"/multipart\">"
     "<input type=\"hidden\" value=\"multipart message\" name=\"hidden\"/>"
     "<input type=\"file\" name=\"file\"/>"
     "<input type=\"submit\" value=\"multipart POST\" />"
     "</form>"
     "<pre>", Body, "</pre>"
     "</body></html>"].

default_body(Req, M, "/chunked") when M =:= 'GET'; M =:= 'HEAD' ->
    Res = Req:ok({"text/plain", [], chunked}),
    Res:write_chunk("First chunk\r\n"),
    timer:sleep(5000),
    Res:write_chunk("Last chunk\r\n"),
    Res:write_chunk("");
default_body(Req, M, _Path) when M =:= 'GET'; M =:= 'HEAD' ->
    Body = io_lib:format("~p~n", [[{parse_qs, Req:parse_qs()},
                                   {parse_cookie, Req:parse_cookie()},
                                   Req:dump()]]),
    Req:ok({"text/html",
            [mochiweb_cookies:cookie("mochiweb_http", "test_cookie")],
            frm(Body)});
default_body(Req, 'POST', "/multipart") ->
    Body = io_lib:format("~p~n", [[{parse_qs, Req:parse_qs()},
                                   {parse_cookie, Req:parse_cookie()},
                                   {body, Req:recv_body()},
                                   Req:dump()]]),
    Req:ok({"text/html", [], frm(Body)});
default_body(Req, 'POST', _Path) ->
    Body = io_lib:format("~p~n", [[{parse_qs, Req:parse_qs()},
                                   {parse_cookie, Req:parse_cookie()},
                                   {parse_post, Req:parse_post()},
                                   Req:dump()]]),
    Req:ok({"text/html", [], frm(Body)});
default_body(Req, _Method, _Path) ->
    Req:respond({501, [], []}).

default_body(Req) ->
    default_body(Req, Req:get(method), Req:get(path)).

loop(Socket, Body) ->
    mochiweb_socket:setopts(Socket, [{packet, http}]),
    request(Socket, Body).

request(Socket, Body) ->
    case mochiweb_socket:recv(Socket, 0, ?REQUEST_RECV_TIMEOUT) of
        {ok, {http_request, Method, Path, Version}} ->
            mochiweb_socket:setopts(Socket, [{packet, httph}]),
            headers(Socket, {Method, Path, Version}, [], Body, 0);
        {error, {http_error, "\r\n"}} ->
            request(Socket, Body);
        {error, {http_error, "\n"}} ->
            request(Socket, Body);
        {error, closed} ->
            mochiweb_socket:close(Socket),
            exit(normal);
        {error, timeout} ->
            mochiweb_socket:close(Socket),
            exit(normal);
        _Other ->
            handle_invalid_request(Socket)
    end.

reentry(Body) ->
    fun (Req) ->
            ?MODULE:after_response(Body, Req)
    end.

headers(Socket, Request, Headers, _Body, ?MAX_HEADERS) ->
    %% Too many headers sent, bad request.
    mochiweb_socket:setopts(Socket, [{packet, raw}]),
    handle_invalid_request(Socket, Request, Headers);
    
headers(Socket, Request, Headers, Body={WwwLoop, WSLoop}, HeaderCount) ->
    case mochiweb_socket:recv(Socket, 0, ?HEADERS_RECV_TIMEOUT) of
        {ok, http_eoh} ->
            {_, {abs_path,Path}, _} = Request,
	        case websocket_check(Socket, Path, Headers) of
                true ->  % a websocket request
            		inet:setopts(Socket, [{packet, raw}]),
                    WSRequest = websocket_request:new(Socket,Path),
                    WSLoop(WSRequest);
	            false -> % normal http request
		            mochiweb_socket:setopts(Socket, [{packet, raw}]),
		            Req = mochiweb:new_request({Socket, Request,
					                           lists:reverse(Headers)}),
            		call_body(WwwLoop, Req),
            		?MODULE:after_response(Body, Req)
    	    end;
        {ok, {http_header, _, Name, _, Value}} ->
            headers(Socket, Request, [{Name, Value} | Headers], Body,
                    1 + HeaderCount);
        {error, closed} ->
            mochiweb_socket:close(Socket),
            exit(normal);
        _Other ->
            handle_invalid_request(Socket, Request, Headers)
    end.

call_body({M, F}, Req) ->
    M:F(Req);
call_body(Body, Req) ->
    Body(Req).

handle_invalid_request(Socket) ->
    handle_invalid_request(Socket, {'GET', {abs_path, "/"}, {0,9}}, []).

handle_invalid_request(Socket, Request, RevHeaders) ->
    mochiweb_socket:setopts(Socket, [{packet, raw}]),
    Req = mochiweb:new_request({Socket, Request,
                                lists:reverse(RevHeaders)}),
    Req:respond({400, [], []}),
    mochiweb_socket:close(Socket),
    exit(normal).

after_response(Body, Req) ->
    Socket = Req:get(socket),
    case Req:should_close() of
        true ->
            mochiweb_socket:close(Socket),
            exit(normal);
        false ->
            Req:cleanup(),
            ?MODULE:loop(Socket, Body)
    end.

websocket_check(Socket,Path,Headers) ->
    case proplists:get_value('Upgrade',Headers) of
        "WebSocket" ->
            websocket_send_handshake(Socket,Path,Headers), 
            true;
        _Other ->
            false
    end.

websocket_send_handshake(Socket,Path,Headers) ->
    Origin   = proplists:get_value("Origin",Headers),
    Location = proplists:get_value('Host',  Headers),
    Proto = "HTTP/1.1 101 Web Socket Protocol Handshake\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n",
    Resp = Proto ++
    "WebSocket-Origin: " ++ Origin ++ "\r\n" ++
    "WebSocket-Location: ws://" ++ Location ++ Path ++ "\r\n\r\n",
    gen_tcp:send(Socket, Resp).


parse_range_request("bytes=0-") ->
    undefined;
parse_range_request(RawRange) when is_list(RawRange) ->
    try
        "bytes=" ++ RangeString = RawRange,
        Ranges = string:tokens(RangeString, ","),
        lists:map(fun ("-" ++ V)  ->
                          {none, list_to_integer(V)};
                      (R) ->
                          case string:tokens(R, "-") of
                              [S1, S2] ->
                                  {list_to_integer(S1), list_to_integer(S2)};
                              [S] ->
                                  {list_to_integer(S), none}
                          end
                  end,
                  Ranges)
    catch
        _:_ ->
            fail
    end.

range_skip_length(Spec, Size) ->
    case Spec of
        {none, R} when R =< Size, R >= 0 ->
            {Size - R, R};
        {none, _OutOfRange} ->
            {0, Size};
        {R, none} when R >= 0, R < Size ->
            {R, Size - R};
        {_OutOfRange, none} ->
            invalid_range;
        {Start, End} when 0 =< Start, Start =< End, End < Size ->
            {Start, End - Start + 1};
        {_OutOfRange, _End} ->
            invalid_range
    end.

%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

range_test() ->
    %% valid, single ranges
    ?assertEqual([{20, 30}], parse_range_request("bytes=20-30")),
    ?assertEqual([{20, none}], parse_range_request("bytes=20-")),
    ?assertEqual([{none, 20}], parse_range_request("bytes=-20")),

    %% trivial single range
    ?assertEqual(undefined, parse_range_request("bytes=0-")),

    %% invalid, single ranges
    ?assertEqual(fail, parse_range_request("")),
    ?assertEqual(fail, parse_range_request("garbage")),
    ?assertEqual(fail, parse_range_request("bytes=-20-30")),

    %% valid, multiple range
    ?assertEqual(
       [{20, 30}, {50, 100}, {110, 200}],
       parse_range_request("bytes=20-30,50-100,110-200")),
    ?assertEqual(
       [{20, none}, {50, 100}, {none, 200}],
       parse_range_request("bytes=20-,50-100,-200")),

    %% no ranges
    ?assertEqual([], parse_range_request("bytes=")),
    ok.

range_skip_length_test() ->
    Body = <<"012345678901234567890123456789012345678901234567890123456789">>,
    BodySize = byte_size(Body), %% 60
    BodySize = 60,

    %% these values assume BodySize =:= 60
    ?assertEqual({1,9}, range_skip_length({1,9}, BodySize)), %% 1-9
    ?assertEqual({10,10}, range_skip_length({10,19}, BodySize)), %% 10-19
    ?assertEqual({40, 20}, range_skip_length({none, 20}, BodySize)), %% -20
    ?assertEqual({30, 30}, range_skip_length({30, none}, BodySize)), %% 30-

    %% valid edge cases for range_skip_length
    ?assertEqual({BodySize, 0}, range_skip_length({none, 0}, BodySize)),
    ?assertEqual({0, BodySize}, range_skip_length({none, BodySize}, BodySize)),
    ?assertEqual({0, BodySize}, range_skip_length({0, none}, BodySize)),
    BodySizeLess1 = BodySize - 1,
    ?assertEqual({BodySizeLess1, 1},
                 range_skip_length({BodySize - 1, none}, BodySize)),

    %% out of range, return whole thing
    ?assertEqual({0, BodySize},
                 range_skip_length({none, BodySize + 1}, BodySize)),
    ?assertEqual({0, BodySize},
                 range_skip_length({none, -1}, BodySize)),

    %% invalid ranges
    ?assertEqual(invalid_range,
                 range_skip_length({-1, 30}, BodySize)),
    ?assertEqual(invalid_range,
                 range_skip_length({0, BodySize + 1}, BodySize)),
    ?assertEqual(invalid_range,
                 range_skip_length({-1, BodySize + 1}, BodySize)),
    ?assertEqual(invalid_range,
                 range_skip_length({BodySize, 40}, BodySize)),
    ?assertEqual(invalid_range,
                 range_skip_length({-1, none}, BodySize)),
    ?assertEqual(invalid_range,
                 range_skip_length({BodySize, none}, BodySize)),
    ok.

-endif.
