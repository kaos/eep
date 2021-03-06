-module(eep).
-export([
         start_file_tracing/1,
         start_file_tracing/2,
         start_file_tracing/3,
         stop_tracing/0,
         convert_tracing/1,
         convert_tracing/2,
         dump_tracing/1,
         callgrind_convertor/2,
         convertor_child/1,
         save_kcachegrind_format/1,
         test_unwind/0
        ]).

start_file_tracing(FileName) ->
    start_file_tracing(FileName, [], '_').

start_file_tracing(FileName, Options) ->
    start_file_tracing(FileName, Options, '_').

% Options:
%     spawn — include link between parent and child processes (experimental and doesn't look well)
start_file_tracing(FileName, Options, Module) ->
    TraceFun = dbg:trace_port(file, tracefile(FileName)),
    {ok, _Tracer} = dbg:tracer(port, TraceFun),
    dbg:tpl(Module, []),
    dbg:p(all, [call, timestamp, return_to, arity, running] ++
        proplists:substitute_aliases([{spawn, procs}], Options)).

stop_tracing() ->
    dbg:stop_clear().

convert_tracing(FileName) ->
    convert_tracing(FileName, []).

% Options:
%     waits — include time spent waiting for event (by default don't include)
convert_tracing(FileName, Options) ->
    do_something_with_tracing({FileName, Options}, fun callgrind_convertor/2).

dump_tracing(FileName) ->
    do_something_with_tracing({FileName, []}, fun dbg_format_dumper/2).

do_something_with_tracing({FileName, Options}, F) ->
    case file:read_file_info(tracefile(FileName)) of
        {ok, _} ->
            dbg:trace_client(file, tracefile(FileName), {F, F(default_state, {FileName, Options})}),
            working;
        {error, Reason} ->
            io:format("Error: can't open ~p: ~p~n", [tracefile(FileName), Reason])
    end.

tracefile(FileName) ->
    FileName ++ ".trace".

kcgfile(FileName) ->
    "callgrind.out." ++ FileName.

dumpfile(FileName) ->
    FileName ++ ".dump".

-record(cvn_state, {processes = ets:new(unnamed, [public, {write_concurrency, true}, {read_concurrency, true}]),
        saver, options}).
-record(cvn_child_state, {pid, delta = 0, delta_ts = undefined, min_time = undefined, max_time = undefined, saver,
        stack = queue:new(), options}).
-record(cvn_item, {mfa, self = 0, ts, calls = 1, returns = 0, subcalls = orddict:new()}).

dbg_format_dumper(Msg, {IOD, Buffer, ReportedTime, S}) when element(1, Msg) == trace_ts ->
    Bytes = iolist_to_binary(io_lib:format("~100000p~n", [Msg])),
    NewBuffer = case size(Buffer) of
        N when N < 20*1024*1024 -> <<Buffer/binary, Bytes/binary>>;
        _ -> file:write(IOD, <<Buffer/binary, Bytes/binary>>), <<>>
    end,
    NewStamp = case td(ReportedTime, os:timestamp()) of
        N1 when N1 > 1000000 -> io:format("~b processed~n", [S]), os:timestamp();
        _ -> ReportedTime
    end,
    {IOD, NewBuffer, NewStamp, S + 1};
dbg_format_dumper({drop, _}, State) ->
    % ignore dropped
    State;
dbg_format_dumper(default_state, {FileName, _}) ->
    {ok, IOD} = file:open(dumpfile(FileName), [write, binary, delayed_write]),
    {IOD, <<>>, os:timestamp(), 0};
dbg_format_dumper(end_of_trace, {IOD, Buffer, _, S}) ->
    file:write(IOD, Buffer),
    file:close(IOD),
    io:format("~b processed~ndone~n", [S]).

callgrind_convertor(Msg, #cvn_state{processes = Processes, saver = Saver, options = Options} = State)
  when element(1, Msg) == trace_ts ->
    Pid = element(2, Msg),
    case ets:lookup(Processes, Pid) of
        [] ->
            Child = spawn_link(?MODULE, convertor_child, [#cvn_child_state{pid = Pid, saver = Saver, options = Options}]),
            Child ! Msg,
            ets:insert(Processes, {Pid, Child}),
            State;
        [{Pid, Child}] ->
            Child ! Msg,
            State
    end;
callgrind_convertor({drop, _}, State) ->
    % ignore dropped
    State;
callgrind_convertor(default_state, {FileName, Options}) ->
    Saver = case FileName of
        nofile -> self();
        _ -> spawn_link(?MODULE, save_kcachegrind_format, [FileName])
    end,
    #cvn_state{saver = Saver, options = Options};
callgrind_convertor(end_of_trace, #cvn_state{processes = Processes, saver = Saver}) ->
    Saver ! {wait, Processes},
    ets:foldl(fun({_, Child}, _) -> Child ! finalize end, nothing, Processes),
    end_of_cycle;
callgrind_convertor(UnknownMessage, #cvn_state{}) ->
    io:format("Unknown message: ~p~n", [UnknownMessage]).

convertor_child(#cvn_child_state{pid = Pid, delta = Delta, delta_ts = DeltaTS, min_time = MinTime, max_time = MaxTime,
                                 saver = Saver, stack = Stack, options = Options} = State) ->
    receive
        {trace_ts, Pid, call, MFA, TS} ->
            NewStack = case queue:out_r(Stack) of
                           {empty, Dropped} ->
                               queue:in(#cvn_item{mfa = MFA, ts = ts(TS) - Delta}, Dropped);
                           {{value, Last}, Dropped} ->
                               case Last of
                                   #cvn_item{mfa = MFA, calls = Calls} ->
                                       queue:in(Last#cvn_item{calls = Calls + 1}, Dropped);
                                   #cvn_item{self = Self, ts = PTS} ->
                                       queue:in(#cvn_item{mfa = MFA, ts = ts(TS) - Delta},
                                                queue:in(Last#cvn_item{self = Self + td(PTS, ts(TS) - Delta), ts = ts(TS) - Delta},
                                                    Dropped))
                               end
                       end,
            convertor_child(State#cvn_child_state{
                              stack = NewStack,
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        {trace_ts, Pid, return_to, MFA, TS} ->
            NewStack = convertor_unwind(MFA, ts(TS) - Delta, nosub, queue:out_r(Stack), {Pid, Saver}),
            convertor_child(State#cvn_child_state{
                              stack = NewStack,
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        {trace_ts, Pid, out, _, TS} ->
            convertor_child(State#cvn_child_state{
                              delta_ts = ts(TS),
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        {trace_ts, Pid, in, _, TS} ->
            NewDelta = Delta + case {proplists:get_value(waits, Options), DeltaTS} of
                {_, undefined} -> 0;
                {true, _} -> 0;
                _ -> td(DeltaTS, TS)
            end,
            convertor_child(State#cvn_child_state{
                              delta = NewDelta,
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        {trace_ts, Pid, spawn, _Pid2, {M, F, Args}, TS} ->
            Arity = length(Args),
            NewStack = case queue:out_r(Stack) of
                {empty, Dropped} ->
                    queue:in(#cvn_item{mfa = {nonexistent, nonexistent, 999}, ts = ts(TS) - Delta,
                            subcalls = subcall_update({{M, F, Arity}, 1}, orddict:new(), 0)}, Dropped);
                {{value, #cvn_item{subcalls = SubCalls} = Last}, Dropped} ->
                    queue:in(Last#cvn_item{subcalls = subcall_update({{M, F, Arity}, 1}, SubCalls, 0)}, Dropped)
            end,
            convertor_child(State#cvn_child_state{
                              stack = NewStack,
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        {trace_ts, Pid, Activity, _, TS} when Activity =:= exit orelse Activity =:= register orelse Activity =:= unregister
                        orelse Activity =:= link orelse Activity =:= unlink
                        orelse Activity =:= getting_linked orelse Activity =:= getting_unlinked ->
            convertor_child(State#cvn_child_state{
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        finalize ->
            convertor_unwind({nonexistent, nonexistent, 999}, MaxTime - Delta, nosub, queue:out_r(Stack), {Pid, Saver}),
            Saver ! {finalize, Pid, MinTime, MaxTime - Delta},
            get_out
    end.
            
convertor_unwind(MFA, _TS, nosub, {{value, #cvn_item{mfa = MFA, calls = Calls, returns = Returns} = Last},
                                         Dropped}, _) when Calls > Returns + 1 ->
    queue:in(Last#cvn_item{returns = Returns + 1}, Dropped);
convertor_unwind(MFA, TS, nosub, {{value, #cvn_item{mfa = MFA, ts = TS}} = Last, Dropped}, _) ->
    % unexpected frame
    queue:in(Last#cvn_item{ts = ts(TS)}, Dropped);
convertor_unwind(MFA, TS, nosub, {{value, #cvn_item{mfa = CMFA, self = Self, calls = CCalls, ts = CTS} = Last},
                                         Dropped}, {Pid, Saver}) ->
    TD = Self + td(CTS, TS),
    Saver ! {bytes, pid_item_to_bytes({Pid, Last#cvn_item{self = TD div CCalls}}), TS},
    convertor_unwind(MFA, TS, {CMFA, CCalls}, queue:out_r(Dropped), {Pid, Saver});
convertor_unwind(MFA, TS, Sub, {{value, #cvn_item{mfa = MFA, ts = CTS, subcalls = SubCalls} = Last}, Dropped}, _) ->
    queue:in(Last#cvn_item{ts = ts(TS), subcalls = subcall_update(Sub, SubCalls, td(CTS, TS))}, Dropped);
convertor_unwind(MFA, TS, Sub, {{value, #cvn_item{mfa = CMFA, calls = CCalls, ts = CTS,
                                                            subcalls = CSubCalls} = Last}, Dropped}, {Pid, Saver}) ->
          Saver ! {bytes, pid_item_to_bytes({Pid, Last#cvn_item{subcalls = subcall_update(Sub, CSubCalls, td(CTS, TS))}}), TS},
    convertor_unwind(MFA, TS, {CMFA, CCalls}, queue:out_r(Dropped), {Pid, Saver});
convertor_unwind(MFA, TS, nosub, {empty, EmptyQueue}, _) ->
    % recreating top level
    queue:in(#cvn_item{mfa = MFA, ts = ts(TS)}, EmptyQueue);
convertor_unwind(MFA, TS, Sub, {empty, EmptyQueue}, _) ->
    % recreating top level
    queue:in(#cvn_item{mfa = MFA, ts = ts(TS), subcalls = subcall_update(Sub, orddict:new(), 1)}, EmptyQueue);
convertor_unwind(A1, A2, A3, A4, A5) ->
    io:format("Shouldn't happen ~p ~p ~p ~p ~p~n", [A1, A2, A3, A4, A5]).

subcall_update({SMFA, SCalls}, SubCalls, SpentInSub) ->
    orddict:update(SMFA, fun({SCalls2, STD2}) -> {SCalls2 + SCalls, STD2 + SpentInSub} end, {SCalls, SpentInSub}, SubCalls).

save_kcachegrind_format(FileName) ->
    erlang:process_flag(priority, high),
    RealFileName = kcgfile(FileName),
    case file:open(RealFileName, [read, write, binary, delayed_write, read_ahead]) of
        {ok, IOD} ->
            file:delete(RealFileName),
            {ok, Timer} = timer:send_interval(1000, status),
            {GTD} = save_receive_cycle(IOD, 1, ts(os:timestamp()), 0, ts(os:timestamp()), undefined, <<>>),
            timer:cancel(Timer),
            {ok, IOD2} = file:open(RealFileName, [write, binary, delayed_write]),
            save_header(IOD2, GTD),
            file:position(IOD, {bof, 0}),
            save_copy(IOD, IOD2),
            file:close(IOD),
            file:close(IOD2),
            io:format("done~n", []);
        {error, Reason} ->
            io:format("Error: can't create file ~p: ~p~n", [RealFileName, Reason]),
            error(problem)
    end.

save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Waiting, Buffer) ->
    receive
        status ->
            working_stat(P, MinTime, max(MinTime, MaxTime), StartTime),
            save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Waiting, Buffer);
        {bytes, Bytes, TS} ->
            NewBuffer = case size(Buffer) of
                N when N < 20*1024*1024 -> <<Buffer/binary, Bytes/binary>>;
                _ -> file:write(IOD, <<Buffer/binary, Bytes/binary>>), <<>>
            end,
            save_receive_cycle(IOD, P + 1, min_ts(MinTime, TS), max_ts(MaxTime, TS), StartTime, Waiting, NewBuffer);
        {wait, Processes} ->
            save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Processes, Buffer);
        {finalize, Pid, MinTime1, MaxTime1} ->
            ets:delete(Waiting, Pid),
            Minimum = min(MinTime, MinTime1),
            Maximum = max(MaxTime, MaxTime1),
            case ets:info(Waiting, size) of
                0 ->
                    file:write(IOD, Buffer),
                    working_stat(P, Minimum, Maximum, StartTime),
                    ets:delete(Waiting),
                    {td(Minimum, Maximum)};
                _ ->
                    save_receive_cycle(IOD, P, Minimum, Maximum, StartTime, Waiting, Buffer)
            end;
        _ ->
            save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Waiting, Buffer)
    end.

pid_item_to_bytes({Pid, #cvn_item{mfa = undefined} = Item}) ->
    pid_item_to_bytes({Pid, Item#cvn_item{mfa = {undefined, undefined, 0}}});
pid_item_to_bytes({Pid, #cvn_item{mfa = {M, F, A}, self = Self, subcalls = SubCalls}}) ->
    Block1 = io_lib:format("ob=~s~n"
        "fl=~w.erl~n"
        "fn=~w:~w/~b~n"
        "1 ~b~n",
        [pid_to_list(Pid), M, M, F, A, Self]),
    Block3 = orddict:fold(fun(CMFA, {CCalls, Cumulative}, Acc) ->
                {CM, CF, CA} = case CMFA of
                                   undefined -> {undefined, undefined, 0};
                                   Defined -> Defined
                               end,
                Block2 = io_lib:format("cfl=~w.erl~n"
                    "cfn=~w:~w/~b~n"
                    "calls=~b 1~n"
                    "1 ~b~n",
                    [CM, CM, CF, CA, CCalls, Cumulative]),
                [Block2 | Acc]
        end, [], SubCalls),
    iolist_to_binary([Block1, lists:reverse(Block3), $\n]).

working_stat(Msgs, MinTime, MaxTime, StartTime) ->
    io:format("~b msgs (~b msgs/sec), ~f secs (~bx slowdown)~n",
              [Msgs, round(Msgs / (td(StartTime, os:timestamp()) / 1000000)),
               td(MinTime, MaxTime) / 1000000, round(td(StartTime, os:timestamp()) / max(td(MinTime, MaxTime), 1))]).

save_header(IOD, GTD) ->
    Block4 = io_lib:format("events: Time~n"
                           "creator: Erlang Easy Profiling https://github.com/virtan/eep~n"
                           "summary: ~b~n~n",
                           [GTD]),
    file:write(IOD, iolist_to_binary(Block4)).

save_copy(From, To) ->
    case file:read(From, 64*1024) of
        {ok, Data} ->
            case file:write(To, Data) of
                ok -> save_copy(From, To);
                {error, Reason} ->
                    io:format("Error: can't save results: ~p~n", [Reason]),
                    error(problem)
            end;
        eof -> done;
        {error, Reason} ->
            io:format("Error: can't save results: ~p~n", [Reason]),
            error(problem)
    end.

ts({Mega, Secs, Micro}) -> (Mega * 1000000000000) + (Secs * 1000000) + Micro;
ts(Number) -> Number.

td(From, To) -> ts(To) - ts(From).

min_ts(undefined, undefined) -> undefined;
min_ts(undefined, Two) -> ts(Two);
min_ts(One, undefined) -> ts(One);
min_ts(One, Two) ->
    case {ts(One), ts(Two)} of
        {X, Y} when X < Y -> X;
        {_, Y} -> Y
    end.

max_ts(undefined, undefined) -> undefined;
max_ts(undefined, Two) -> ts(Two);
max_ts(One, undefined) -> ts(One);
max_ts(One, Two) ->
    case {ts(One), ts(Two)} of
        {X, Y} when X > Y -> X;
        {_, Y} -> Y
    end.

receive_all(Prev) ->
    receive
        M -> receive_all([M | Prev])
    after 500 -> lists:reverse(Prev)
    end.

test_unwind() ->
    test_unwind_1(),
    test_unwind_2(),
    test_unwind_3(),
    ok.

test_unwind_1() ->
    Pid = list_to_pid("<0.1.0>"),
    TestSet = [
        {trace_ts, Pid, call, {a,b,1}, 1},
        {trace_ts, Pid, call, {a,b,1}, 3},
        {trace_ts, Pid, call, {a,b,1}, 7},
        {trace_ts, Pid, return_to, {x,b,1}, 10}
    ],
    lists:foldl(fun(El, St) -> callgrind_convertor(El, St) end, callgrind_convertor(default_state, nofile), TestSet),
    [{bytes,<<"ob=<0.1.0>\nfl=a\nfn=a:b/1\n1 3\n\n">>,1}] = receive_all([]).

test_unwind_2() ->
    Pid = list_to_pid("<0.1.0>"),
    TestSet = [
        {trace_ts, Pid, call, {a,b,1}, 1},
        {trace_ts, Pid, call, {a,b,2}, 3},
        {trace_ts, Pid, call, {a,b,3}, 7},
        {trace_ts, Pid, return_to, {x,b,1}, 10}
    ],
    lists:foldl(fun(El, St) -> callgrind_convertor(El, St) end, callgrind_convertor(default_state, nofile), TestSet),
    [{bytes,<<"ob=<0.1.0>\nfl=a\nfn=a:b/3\n1 3\n\n">>,7},
     {bytes,<<"ob=<0.1.0>\nfl=a\nfn=a:b/2\n1 4\ncfl=a\ncfn=a:b/3\ncalls=1 1\n1 3\n\n">>, 7},
     {bytes,<<"ob=<0.1.0>\nfl=a\nfn=a:b/1\n1 2\ncfl=a\ncfn=a:b/2\ncalls=1 1\n1 7\n\n">>, 3}] = receive_all([]).

test_unwind_3() ->
    Pid = list_to_pid("<0.1.0>"),
    TestSet = [
        {trace_ts,Pid,call,{prim_file,write,2},{1384,248547,512336}},
        {trace_ts,Pid,call,{prim_file,drv_command_nt,3},{1384,248547,512342}},
        {trace_ts,Pid,call,{erlang,port_command,2},{1384,248547,512344}},
        {trace_ts,Pid,return_to,{prim_file,drv_command_nt,3},{1384,248547,512347}},
        {trace_ts,Pid,call,{prim_file,drv_get_response,2},{1384,248547,512354}},
        {trace_ts,Pid,call,{prim_file,drv_get_response,1},{1384,248547,512356}},
        {trace_ts,Pid,call,{erlang,bump_reductions,1},{1384,248547,512357}},
        {trace_ts,Pid,return_to,{prim_file,drv_get_response,1},{1384,248547,512366}},
        {trace_ts,Pid,call,{prim_file,translate_response,2},{1384,248547,512368}},
        {trace_ts,Pid,call,{prim_file,get_uint64,1},{1384,248547,512375}},
        {trace_ts,Pid,call,{prim_file,get_uint32,1},{1384,248547,512380}},
        {trace_ts,Pid,return_to,{prim_file,get_uint64,1},{1384,248547,512382}},
        {trace_ts,Pid,call,{prim_file,get_uint32,1},{1384,248547,512383}},
        {trace_ts,Pid,return_to,{prim_file,get_uint64,1},{1384,248547,512385}},
        {trace_ts,Pid,return_to,{prim_file,translate_response,2},{1384,248547,512386}},
        {trace_ts,Pid,return_to,{prim_file,drv_get_response,1},{1384,248547,512392}},
        {trace_ts,Pid,return_to,{prim_file,drv_command_nt,3},{1384,248547,512397}},
        {trace_ts,Pid,return_to,{prim_file,write,2},{1384,248547,512404}}
    ],
    lists:foldl(fun(El, St) -> callgrind_convertor(El, St) end, callgrind_convertor(default_state, nofile), TestSet),
    [{bytes,<<"ob=<0.1.0>\nfl=erlang\nfn=erlang:port_command/2\n1 3\n\n">>,1384248547512344},
     {bytes,<<"ob=<0.1.0>\nfl=erlang\nfn=erlang:bump_reductions/1\n1 9\n\n">>,1384248547512357},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:get_uint32/1\n1 2\n\n">>,1384248547512380},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:get_uint32/1\n1 2\n\n">>,1384248547512383},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:get_uint64/1\n1 7\ncfl=prim_file\ncfn=prim_file:get_uint32/1\ncalls=2 1\n1 4\n\n">>,1384248547512385},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:translate_response/2\n1 13\ncfl=prim_file\ncfn=prim_file:get_uint64/1\ncalls=1 1\n1 11\n\n">>,1384248547512386},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:drv_get_response/1\n1 8\ncfl=erlang\ncfn=erlang:bump_reductions/1\ncalls=1 1\n1 9\ncfl=prim_file\ncfn=prim_file:translate_response/2\ncalls=1 1\n1 24\n\n">>,1384248547512392},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:drv_get_response/2\n1 2\ncfl=prim_file\ncfn=prim_file:drv_get_response/1\ncalls=1 1\n1 41\n\n">>,1384248547512356},
     {bytes,<<"ob=<0.1.0>\nfl=prim_file\nfn=prim_file:drv_command_nt/3\n1 16\ncfl=erlang\ncfn=erlang:port_command/2\ncalls=1 1\n1 3\ncfl=prim_file\ncfn=prim_file:drv_get_response/2\ncalls=1 1\n1 43\n\n">>,1384248547512397}] = receive_all([]).
