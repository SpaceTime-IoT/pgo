-module(pgo_type_server).

-export([start_link/2,
         reload/1,
         reload_cast/1]).

-export([init/1,
         callback_mode/0,
         ready/3,
         terminate/3]).

-include("pgo_internal.hrl").
-include_lib("pg_types/include/pg_types.hrl").

-record(data, {pool        :: atom(),
               pool_config  :: pgo:pool_config(),
               last_reload :: integer() | undefined}).

start_link(Pool, PoolConfig) ->
    gen_statem:start_link(?MODULE, [Pool, PoolConfig], []).

reload(Pid) ->
    gen_statem:call(Pid, {reload, erlang:monotonic_time()}).

reload_cast(Pid) ->
    gen_statem:cast(Pid, {reload, erlang:monotonic_time()}).

init([Pool, PoolConfig]) ->
    erlang:process_flag(trap_exit, true),
    ets:new(Pool, [named_table, protected, {keypos, 2}]),
    {ok, ready, #data{pool=Pool, pool_config=PoolConfig},
     {next_event, internal, load}}.

callback_mode() ->
    state_functions.

ready(internal, load, Data=#data{pool=Pool,
                                 pool_config=PoolConfig}) ->
    case load(Pool, -1, 0, PoolConfig) of
        failed ->
            %% not using a timer because this initial load, so want to block
            timer:sleep(500),
            {keep_state_and_data, [{next_event, internal, load}]};
        _ ->
            {keep_state, Data#data{last_reload=erlang:monotonic_time()}}
    end;
ready({call, From}, {reload, RequestTime}, Data=#data{pool=Pool,
                                                      pool_config=PoolConfig,
                                                      last_reload=LastReload}) ->
    load(Pool, LastReload, RequestTime, PoolConfig),
    {keep_state, Data#data{last_reload=erlang:monotonic_time()}, [{reply, From, ok}]};
ready(cast, {reload, RequestTime}, Data=#data{pool=Pool,
                                              pool_config=PoolConfig,
                                              last_reload=LastReload}) ->
    load(Pool, LastReload, RequestTime, PoolConfig),
    {keep_state, Data#data{last_reload=erlang:monotonic_time()}};
ready(_, _, _Data) ->
    keep_state_and_data.

terminate(_, _, #data{pool=Pool}) ->
    ets:delete(Pool).

load(Pool, LastReload, RequestTime, PoolConfig) when LastReload < RequestTime ->
    try pgo_handler:open(Pool, PoolConfig) of
        {ok, Conn=#conn{parameters=Parameters}} ->
            Oids = load_and_update_types(Conn, Pool),
            pg_types:update(Pool, Oids, Parameters);
        {error, _} ->
            failed
    catch
        _:_ ->
            failed
    end;
load(_, _, _, _) ->
    ok.

%% TODO: only return oids not already selected in previous runs
-define(BOOTSTRAP_QUERY, ["SELECT t.oid, t.typname, t.typsend, t.typreceive, t.typlen, "
                          "t.typoutput, t.typinput, t.typelem, coalesce(r.rngsubtype, 0) "
                          "FROM pg_type AS t LEFT JOIN pg_range AS r ON r.rngtypid = t.oid "
                          "OR (t.typbasetype <> 0 AND r.rngtypid = t.typbasetype) "
                          "ORDER BY t.oid"]).

load_and_update_types(Conn, Pool) ->
    try
        {ok, Oids} = pgo_handler:simple_query(Conn, ?BOOTSTRAP_QUERY),
        [#type_info{oid=binary_to_integer(Oid),
                    pool=Pool,
                    name=binary:copy(Name),
                    typsend=binary:copy(Send),
                    typreceive=binary:copy(Receive),
                    typlen=binary_to_integer(Len),
                    output=binary:copy(Output),
                    input=binary:copy(Input),
                    elem_oid=binary_to_integer(ArrayOid),
                    base_oid=binary_to_integer(BaseOid)}
         || [Oid, Name, Send, Receive, Len, Output, Input, ArrayOid, BaseOid] <- Oids]
    catch
        _:_:_ ->

            failed
    after
        pgo_handler:close(Conn)
    end.
