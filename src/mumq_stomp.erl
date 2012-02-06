-module(mumq_stomp).

-export([create_conn/1,
         peername/1,
         write_frame/2,
         read_frame/1,
         log_frame/2]).

-include("mumq.hrl").

-record(conn, {sock,
               peer,
               recv_len,
               max_frame_size,
               frame_size = 0,
               buf = []}).

create_conn(Socket) ->
    {ok, Peer0} = gen_tcpd:peername(Socket),
    Peer = format_peer(Peer0),
    {ok, [{recbuf, RecvLen}]} = gen_tcpd:getopts(Socket, [recbuf]),
    Max = max_frame_size(),
    #conn{sock = Socket, peer = Peer, recv_len = RecvLen, max_frame_size = Max}.

format_peer({{O1, O2, O3, O4}, P}) ->
    io_lib:format("~B.~B.~B.~B:~B", [O1, O2, O3, O4, P]).

max_frame_size() ->
    case application:get_env(max_frame_size) of
        undefined ->
            ?MAX_FRAME_SIZE;
        {ok, Max} ->
            Max
    end.

peername(Conn) -> Conn#conn.peer.

write_frame(Socket, Frame) ->
    {frame, Cmd, Headers, Body} = Frame,
    Data = [Cmd, $\n, prepare_headers(Headers), $\n, Body, $\0],
    gen_tcpd:send(Socket, Data).

prepare_headers(Headers) ->
    [prepare_header(H) || H <- Headers].

prepare_header({"content-length", Len}) when is_list(Len) ->
    prepare_header({"content-length", list_to_integer(Len)});
prepare_header({Key, Val}) ->
    [Key, $:, Val, $\n].

read_frame(Conn) ->
    try
        read_frame2(Conn)
    catch
        throw:bad_frame ->
            {error, bad_frame};
        throw:bad_frame_size ->
            {error, bad_frame_size}
    end.

read_frame2(Conn) ->
    Conn2 = eat_empty_lines(Conn),
    {Cmd, Conn3} = read_line(Conn2),
    {Headers, Conn4} = read_headers(Conn3),
    BodySize = proplists:get_value("content-length", Headers, undefined),
    {Body, Conn5} = read_body(Conn4, BodySize),
    {ok, {frame, Cmd, Headers, Body}, Conn5}.

read_headers(Conn) ->
    try
        {Headers, Conn2} = read_headers(Conn, []),
        {parse_headers(Conn2, Headers), Conn2}
    catch
        error:_ ->
            throw(bad_frame)
    end.

read_headers(Conn, Headers) ->
    case read_line(Conn) of
        {<<>>, Conn2} ->
            {lists:reverse(Headers), Conn2};
        {Line, Conn2} ->
            [Key0, Val0] = lists:map(fun strip_spaces/1, binary:split(Line, <<":">>)),
            Key = string:to_lower(binary_to_list(Key0)),
            Val = binary_to_list(Val0),
            read_headers(Conn2, [{Key, Val} | Headers])
    end.

strip_spaces(Bin) ->
    binary:replace(Bin, <<$ >>, <<>>, [global]).

parse_headers(Conn, Headers) ->
    [parse_header(Conn, H) || H <- Headers].

parse_header(Conn, {"content-length", StrLen}) ->
    case list_to_integer(StrLen) of
        Len when Len + Conn#conn.frame_size > Conn#conn.max_frame_size ->
            throw(bad_frame_size);
        Len ->
            true
    end,
    {"content-length", Len};
parse_header(_, Header) ->
    Header.

read_line(Conn) ->
    Concat = fun(B1, B2) -> <<B2/binary, B1/binary>> end,
    {Chunk, Conn2} = read_chunk(Conn, <<$\n>>),
    {lists:foldl(Concat, <<>>, Chunk), Conn2}.

read_body(Conn, undefined) ->
    read_chunk(Conn, <<$\0>>);
read_body(Conn, Size) ->
    read_size_chunk(Conn, Size, <<$\0>>).

eat_empty_lines(Conn) ->
    case peek_byte(Conn) of
        {<<$\n>>, Conn2} ->
            eat_empty_lines(eat_byte(Conn2));
        {_, Conn2} ->
            Conn2
    end.

read_chunk(Conn, Sep) ->
    {Parts, Conn2} = read_chunk(Conn, Sep, []),
    {lists:reverse(Parts), Conn2}.

read_chunk(Conn, Sep, Parts) ->
    [Data | Rest] = read_buffer(Conn),
    Size = Conn#conn.frame_size,
    case binary:split(Data, Sep) of
        L when size(hd(L)) + Size > Conn#conn.max_frame_size ->
            throw(bad_frame_size);
        [Part] ->
            read_chunk(Conn#conn{buf = Rest, frame_size = Size + size(Part)},
                       Sep, [Part | Parts]);
        [<<>>, <<>>] ->
            {[<<>> | Parts], Conn#conn{buf = Rest}};
        [<<>>, MoreData] ->
            {[<<>> | Parts], Conn#conn{buf = [MoreData | Rest]}};
        [Part, <<>>] ->
            {[Part | Parts], Conn#conn{buf = Rest, frame_size = Size + size(Part)}};
        [Part, MoreData] ->
            {[Part | Parts], Conn#conn{buf = [MoreData | Rest],
                                       frame_size = Size + size(Part)}}
    end.

read_size_chunk(Conn, Size, Sep) ->
    {Parts, Conn2} = read_size_chunk(Conn, Size, Sep, []),
    case peek_byte(Conn2) of
        {Sep, Conn3} ->
            {lists:reverse(Parts), eat_byte(Conn3)};
        _ ->
            throw(bad_frame)
    end.

read_size_chunk(Conn, 0, _, Parts) ->
    {Parts, Conn};
read_size_chunk(Conn, Size, Sep, Parts) ->
    [Data | Rest] = read_buffer(Conn, min(Size, Conn#conn.recv_len)),
    FSize = Conn#conn.frame_size,
    case size(Data) of
        N when N =< Size ->
            Conn2 = Conn#conn{buf = Rest, frame_size = N + FSize},
            read_size_chunk(Conn2, Size - N, Sep, [Data | Parts]);
        N ->
            {Part, MoreData} = split_binary(Data, Size),
            {[Part | Parts], Conn#conn{buf = [MoreData | Rest],
                                       frame_size = N + FSize}}
    end.

peek_byte(Conn) ->
    Conn2 = Conn#conn{buf = read_buffer(Conn)},
    Byte = binary:first(hd(Conn2#conn.buf)),
    {<<Byte>>, Conn2}.

eat_byte(Conn = #conn{buf = []}) ->
    eat_byte(Conn#conn{buf = read_buffer(Conn)});
eat_byte(Conn = #conn{buf = [Data | Rest]}) when size(Data) == 1 ->
    Conn#conn{buf = Rest};
eat_byte(Conn = #conn{buf = [Data | Rest]}) ->
    Conn#conn{buf = [binary:part(Data, 1, size(Data) - 1) | Rest]}.

read_buffer(Conn) ->
    read_buffer(Conn, 0).

read_buffer(Conn = #conn{buf = []}, RecvLen) ->
    case gen_tcpd:recv(Conn#conn.sock, RecvLen) of
        {ok, Packet} ->
            Data = [Packet];
        {error, closed} ->
            Data = none,
            throw(tcp_closed);
        {error, _} ->
            Data = none,
            throw(tcp_error)
    end,
    lager:debug("~B bytes received from ~s", [size(hd(Data)), Conn#conn.peer]),
    Data;
read_buffer(Conn, _) ->
    Conn#conn.buf.

log_frame({frame, Cmd, Headers, Body}, Peer) ->
    lager:debug("Frame received from ~s~n\tCmd = ~s~n\tHeaders = ~p~n\tBody = ~p",
                [Peer, Cmd, Headers, Body]).
