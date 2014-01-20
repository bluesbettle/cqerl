%% @author Mathieu D'Amours <matt@forest.io>
%% @doc Main interface to CQErl cassandra client.

-module(cqerl).
-behaviour(gen_server).

-export([
    prepare_client/1,
    prepare_client/2,
    
    new_client/0, 
    new_client/1, 
    new_client/2, 
    
    close_client/1,
    
    run_query/2, 
    send_query/2,
    
    has_more_pages/1,
    fetch_more/1, 
    fetch_more_async/1,
    
    size/1,
    head/1,
    tail/1,
    next/1,
    all_rows/1,
    
    start_link/0
]).

-export([
    init/1, 
    terminate/2, 
    code_change/3,
    
    handle_call/3, 
    handle_cast/2, 
    handle_info/2
]).


-include("cqerl.hrl").

-opaque client() :: {pid(), reference()}.

-type inet() :: { inet:ip_address() | string(), Port :: integer() }.

-export_type([client/0, inet/0]).

-record(cql_client_stats, {
    min_count :: integer(),
    max_count :: integer(),
    count = 0 :: integer()
}).

-record(cqerl_state, {
    checked_env = false :: boolean(),
    clients             :: ets:tab(),
    client_stats        :: list({atom(), #cql_client_stats{}}),
    globalopts          :: list(any()),
    retrying = false    :: boolean()
}).

-record(cql_client, {
    node  :: tuple(),
    pid   :: pid(),
    busy  :: boolean()
}).

-define(RETRY_INITIAL_DELAY, 10).
-define(RETRY_MAX_DELAY, 1000).
-define(RETRY_EXP_FACT, 1.15).

-define(DEFAULT_PORT, 9042).

-spec prepare_client(Inet :: inet(), Opts :: list(tuple() | atom())) -> ok.
prepare_client(Inet, Opts) ->
    gen_server:cast(?MODULE, {prepare_client, prepare_node_info(Inet), Opts}).

-spec prepare_client(Inet :: inet()) -> ok.
prepare_client(Inet) -> prepare_client(Inet, []).




-spec new_client() -> client().
new_client() ->
    gen_server:call(?MODULE, get_any_client).

-spec new_client(Inet :: inet()) ->    client().
new_client({}) ->
    new_client({{127, 0, 0, 1}, ?DEFAULT_PORT}, []);
new_client(Inet) -> 
    new_client(Inet, []).

-spec new_client(Inet :: inet(), Opts :: list(tuple() | atom())) -> client() | {error, no_client_available}.
new_client({}, Opts) ->
    new_client({{127, 0, 0, 1}, ?DEFAULT_PORT}, Opts);
new_client(Inet, Opts) ->
    gen_server:call(?MODULE, {get_client, prepare_node_info(Inet), Opts}).




%% @doc Close a client that was previously allocated with {@link new_client/0} or {@link new_client/1}.
%%
%% This function will return immediately no matter if the client has already been closed or not.

-spec close_client(ClientRef :: client()) -> no_return().
close_client(ClientRef) ->
    cqerl_client:remove_user(ClientRef).
    
    
    

%% @doc Fetch the next page of result from Cassandra for a given continuation. The function will
%%            return with the result from Cassandra (synchronously).
%% The <code>Query</code> parameter can be a string, a binary UTF8 string or a <code>#cql_query{}</code> record
%%
%% <pre>#cql_query{
%%     query :: binary(),
%%     reusable :: boolean(),
%%     consistency :: consistency_level(),
%%     named :: boolean(),
%%     bindings :: list(number() | boolean() | binary() | list() | inet() | ) | list(tuple())
%% }</pre>
%%
%% <em>Reusable</em> is a boolean indicating whether the query should be reused. <em>Reusing a query</em> means sending it to Cassandra to be prepared, which allows
%% later executions of the <strong>same query</strong> to be performed faster. This parameter is <code>true</code> by default when you provide bindings in the query (positional <code>?</code>
%% parameters or named <code>:var</code> parameters), and <code>false</code> by default when you don't. You can override the defaults.
%%
%% <em>Consistency</em> one of constants defined in <code>cqerl.hrl</code>, namely <code>?CQERL_CONSISTENCY_[Const]</code> where <code>Const</code> can be <code>ANY</code>, <code>ONE</code>,
%% <code>TWO</code>, <code>THREE</code>, <code>QUORUM</code>, <code>ALL</code>, <code>LOCAL_QUORUM</code>, <code>EACH_QUORUM</code>, <code>SERIAL</code>,
%% <code>LOCAL_SERIAL</code> or <code>LOCAL_ONE</code>.
%%
%% How <em>bindings</em> is used depends on the <em>named</em> value. <em>Named</em> is a boolean value indicating whether the parameters in the query are named parameters (<code>:var1</code>). Otherwise,
%% they are assumed to be positional (<code>?</code>). In the first case, <em>bindings</em> is a property list (see <a href="http://www.erlang.org/doc/man/proplists.html">proplists</a>) where keys match the
%% parameter names. In the latter case, <em>bindings</em> should be a simple list of values.

-spec run_query(ClientRef :: client(), Query :: binary() | string() | #cql_query{}) -> #cql_result{}.
run_query(ClientRef, Query) ->
    cqerl_client:query(ClientRef, Query).




%% @doc Check to see if there are more result available

-spec has_more_pages(Continuation :: #cql_result{}) -> true | false.
has_more_pages(#cql_result{query=#cql_query{page_state=undefined}}) -> false;
has_more_pages(#cql_result{}) -> true.



%% @doc Fetch the next page of result from Cassandra for a given continuation. The function will
%%            return with the result from Cassandra (synchronously).

-spec fetch_more(Continuation :: #cql_result{}) -> no_more_result | #cql_result{}.
fetch_more(#cql_result{query=#cql_query{page_state=undefined}}) -> 
    no_more_result;
fetch_more(Continuation) ->
    cqerl_client:fetch_more(Continuation).




%% @doc Send a query to be executed asynchronously. This method returns immediately with a unique tag. 
%%
%% When a successful response is received from cassandra, a <code>{result, Tag, Result :: #cql_result{}}</code> 
%% message is sent to the calling process. 
%%
%% If there is an error with the query, a <code>{error, Tag, Error :: #cql_error{}}</code> will be sent to the calling process.
%%
%% Neither of these messages will be sent if the connection is dropped before receiving a response (see {@link new_client/0} for
%% how to handle this case).

-spec send_query(ClientRef :: client(), Query :: binary() | string() | #cql_query{}) -> reference().
send_query(ClientRef, Query) ->
    cqerl_client:query_async(ClientRef, Query).




%% @doc Asynchronously fetch the next page of result from cassandra for a given continuation.
%%
%% A success or error message will be sent in response some time later (see {@link send_query/2} for details) unless the
%% connection is dropped.

-spec fetch_more_async(Continuation :: #cql_result{}) -> reference() | no_more_result.
fetch_more_async(#cql_result{query=#cql_query{page_state=undefined}}) -> 
    no_more_result;
fetch_more_async(Continuation) ->
    cqerl_client:fetch_more_async(Continuation).
    
    

%% @doc The number of rows in a result set

size(#cql_result{dataset=[]}) -> 0;
size(#cql_result{dataset=Dataset}) -> length(Dataset).

%% @doc Returns the first row of result, as a property list

head(#cql_result{dataset=[]}) -> empty_dataset;
head(#cql_result{dataset=[Row|_Rest], columns=ColumnSpecs}) ->
    cqerl_protocol:decode_row(Row, ColumnSpecs).

%% @doc Returns all rows of result, except the first one

tail(#cql_result{dataset=[]}) -> empty_dataset;
tail(Result=#cql_result{dataset=[_Row|Rest]}) ->
    Result#cql_result{dataset=Rest}.
    
%% @doc Returns a tuple of <code>{HeadRow, ResultTail}</code>.
%%
%% This can be used to iterate over a result set efficiently. Successively
%% call this function over the result set to go through all rows, until it
%% returns the <code>empty_dataset</code> atom.

next(#cql_result{dataset=[]}) -> empty_dataset;
next(Result) -> {head(Result), tail(Result)}.

%% @doc Returns a list of rows as property lists

all_rows(#cql_result{dataset=[]}) -> [];
all_rows(#cql_result{dataset=Rows, columns=ColumnSpecs}) ->
    [ cqerl_protocol:decode_row(Row, ColumnSpecs) || Row <- Rows ].


%% ====================
%% Gen_Server Callbacks
%% ====================

start_link() ->
    random:seed(now()),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    io:format("== Starting CQErl frontend. ==~n", []),
    {ok, #cqerl_state{clients = ets:new(clients, [set, private, {keypos, #cql_client.pid}]),
                      client_stats=[]}, 0}.




handle_call(get_any_client, _From, State=#cqerl_state{client_stats=[]}) ->
    {reply, {error, no_configured_node}, State};

handle_call(get_any_client, From, State=#cqerl_state{client_stats=Stats, clients=Clients, retrying=Retrying}) ->
    case select_client(Clients, #cql_client{busy=false, _='_'}, From) of
        no_available_client when Retrying ->
            retry;
        
        no_available_client ->
            erlang:send_after(?RETRY_INITIAL_DELAY, self(), {retry, get_any_client, From, ?RETRY_INITIAL_DELAY}),
            {noreply, State};
        
        {_Pid, NodeKey} ->
            {ok, CStats=#cql_client_stats{count=Count}} = orddict:find(NodeKey, Stats),
            {noreply, State#cqerl_state{client_stats=orddict:store(NodeKey, CStats#cql_client_stats{count=Count+1}, Stats)}}
    end;

handle_call({get_client, Node, Opts}, From, State=#cqerl_state{clients=Clients, client_stats=Stats, retrying=Retrying, globalopts=GlobalOpts}) ->
    NodeKey = node_key(Node, {Opts, GlobalOpts}),
    case orddict:find(NodeKey, Stats) of
        error ->
            new_pool(NodeKey, Opts, GlobalOpts),
            OptGetter = make_option_getter(Opts, GlobalOpts),
            case pooler:take_member(pool_from_node(NodeKey)) of
                error_no_members -> 
                    Stats1 = orddict:store(NodeKey, #cql_client_stats{count=0, min_count=OptGetter(pool_min_size), max_count=OptGetter(pool_max_size)}, Stats),
                    {reply, {error, no_available_clients}, State#cqerl_state{client_stats=Stats1}};
                Pid ->
                    link(Pid),
                    Stats1 = orddict:store(NodeKey, #cql_client_stats{count=1, min_count=OptGetter(pool_min_size), max_count=OptGetter(pool_max_size)}, Stats),
                    ets:insert(Clients, #cql_client{node=NodeKey, busy=false, pid=Pid}),
                    cqerl_client:new_user(Pid, From),
                    {noreply, State#cqerl_state{client_stats=Stats1}}
            end;
        
        _ ->
            case select_client(Clients, #cql_client{node=NodeKey, busy=false, pid='_'}, From) of
                no_available_client when Retrying ->
                    retry;
                
                no_available_client ->
                    erlang:send_after(?RETRY_INITIAL_DELAY, self(), {retry, {get_client, NodeKey, Opts}, From, ?RETRY_INITIAL_DELAY}),
                    {noreply, State};
                
                {existing, _, _} ->
                    {noreply, State};
                
                {new, _Pid, NodeKey} ->
                    {ok, CStats=#cql_client_stats{count=Count}} = orddict:find(NodeKey, Stats),
                    {noreply, State#cqerl_state{client_stats=orddict:store(NodeKey, CStats#cql_client_stats{count=Count+1}, Stats)}}
            end
    end;

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.







handle_cast({prepare_client, Node, Opts}, State=#cqerl_state{client_stats=Stats, globalopts=GlobalOpts}) ->
    NodeKey = node_key(Node, {Opts, GlobalOpts}),
    case orddict:find(NodeKey, Stats) of
        error -> 
            new_pool(NodeKey, Opts, GlobalOpts),
            OptGetter = make_option_getter(Opts, GlobalOpts),
            Stats1 = orddict:store(NodeKey, #cql_client_stats{count=0, min_count=OptGetter(pool_min_size), max_count=OptGetter(pool_max_size)}, Stats),
            {noreply, State#cqerl_state{client_stats=Stats1}};
        _ -> 
            {noreply, State}
    end;
    
handle_cast({client_alive, Pid, Inet, Keyspace}, State=#cqerl_state{clients=Clients, client_stats=Stats}) ->
    case ets:lookup(Clients, Pid) of
        [_Client] -> 
            {noreply, State};
        _ ->
            NodeKey = node_key(Inet, Keyspace),
            PoolKey = pool_from_node(NodeKey),
            case orddict:find(NodeKey, Stats) of
                {ok, CStats=#cql_client_stats{count=Count, min_count=Min}} when Count < Min ->
                    FindMember = fun (F, Acc) ->
                        case pooler:take_member(PoolKey) of
                            error_no_members -> 
                                {State, Acc};
                            Pid ->
                                link(Pid),
                                ets:insert(Clients, #cql_client{node=NodeKey, busy=false, pid=Pid}),
                                Stats1 = orddict:store(NodeKey, CStats#cql_client_stats{count=Count+1}, Stats),
                                {State#cqerl_state{client_stats=Stats1}, Acc};
                            OtherPid ->
                                F(F, [OtherPid | Acc])
                        end
                    end,
                    {State1, ToBeReturned} = FindMember(FindMember, []),
                    lists:foreach(fun(PPid) -> pooler:return_member(PoolKey, PPid, ok) end, ToBeReturned),
                    {noreply, State1};
                _ ->
                    {noreply, State}
            end
    end;

handle_cast({client_busy, Pid}, State=#cqerl_state{clients=Clients}) ->
    case ets:lookup(Clients, Pid) of
        [Client] -> ets:insert(Clients, Client#cql_client{busy=true});
        _ -> ok
    end,
    {noreply, State};

handle_cast({client_avail, Pid}, State=#cqerl_state{clients=Clients}) ->
    case ets:lookup(Clients, Pid) of
        [Client] ->
            ets:insert(Clients, Client#cql_client{busy=false});
        _ -> ok
    end,
    {noreply, State};

handle_cast({client_asleep, Pid}, State=#cqerl_state{clients=Clients, client_stats=Stats}) ->
    case ets:lookup(Clients, Pid) of
        [#cql_client{node=NodeKey}] ->
            case orddict:find(NodeKey, Stats) of
                {ok, #cql_client_stats{min_count=Min, count=Count}} when Count =< Min ->
                    {noreply, State};
                {ok, CStats=#cql_client_stats{count=Count}} ->
                    Pool = pool_from_node(NodeKey),
                    pooler:return_member(Pool, Pid, ok),
                    unlink(Pid),
                    ets:delete(Clients, Pid),
                    Stats1 = orddict:store(NodeKey, CStats#cql_client_stats{count=Count-1}, Stats),
                    {noreply, State#cqerl_state{client_stats=Stats1}};
                error ->
                    {noreply, State}
            end;
        _ ->
            {noreply, State}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.




handle_info({'EXIT', From, Reason}, State=#cqerl_state{clients=Clients, client_stats=Stats}) ->
    case ets:lookup(Clients, From) of
        [#cql_client{node=NodeKey}] ->
            {ok, CStats=#cql_client_stats{count=Count}} = orddict:find(NodeKey, Stats),
            {noreply, State = #cqerl_state{client_stats = orddict:store(NodeKey, CStats#cql_client_stats{count = Count-1}, Stats)}};
        [] ->
            {stop, Reason, State}
    end;

handle_info(timeout, State=#cqerl_state{checked_env=false}) ->
    GlobalOpts = lists:map(
        fun (Key) -> application:get_env(cqerl, Key, undefined) end, 
        [ssl, auth, pool_min_size, pool_max_size, pool_cull_interval, client_max_age, keyspace]
    ),
    Nodes = application:get_env(cqerl, cassandra_nodes, []),
    Stats = lists:foldl(fun
        (Arg, Stats) -> 
            case Arg of
                {Inet, Opts} when is_list(Opts) -> ok;
                Inet -> Opts = []
            end,
            Key = node_key(prepare_node_info(Inet), {Opts, GlobalOpts}),
            new_pool(Key, Opts, GlobalOpts),
            OptGetter = make_option_getter(Opts, GlobalOpts),
            orddict:store(Key, #cql_client_stats{count=0, min_count=OptGetter(pool_min_size), max_count=OptGetter(pool_max_size)}, Stats)
    end, [], Nodes),
    {noreply, State#cqerl_state{ checked_env=true, globalopts=GlobalOpts, client_stats=Stats }};

handle_info({retry, Msg, From, Delay}, State) ->
    case handle_call(Msg, From, State#cqerl_state{retrying=true}) of
        retry -> 
            case erlang:round(math:pow(Delay, ?RETRY_EXP_FACT)) of
                NewDelay when NewDelay < ?RETRY_MAX_DELAY ->
                    erlang:send_after(NewDelay, self(), {retry, Msg, From, NewDelay});
                _ ->
                    gen_server:reply(From, {error, no_available_clients})
            end;
        {reply, Client, State} ->
            gen_server:reply(From, Client)
    end;

handle_info(_Msg, State) ->
    {noreply, State}.




terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% =================
%% Private functions
%% =================

node_key({Ip, Port}, Keyspace0) ->
    Keyspace = case Keyspace0 of
        {LocalOpts, GlobalOpts} ->
            OptGetter = make_option_getter(GlobalOpts, LocalOpts),
            OptGetter(keyspace);
        _ -> Keyspace0
    end,
    Keyspace1 = case Keyspace of
        Val when is_atom(Val) -> Val;
        Val when is_list(Val) -> list_to_atom(Val);
        Val when is_binary(Val) -> binary_to_atom(Val, latin1)
    end,
    {Ip, Port, Keyspace1}.

new_pool(NodeKey={Ip, Port, Keyspace}, LocalOpts, GlobalOpts) ->
    OptGetter = make_option_getter(GlobalOpts, LocalOpts),
    {Amount, Unit} = OptGetter(client_max_age),
    pooler:new_pool([{name,            pool_from_node(NodeKey)},
                     {group,           cqerl},
                     {init_count,      OptGetter(pool_min_size)},
                     {max_count,       OptGetter(pool_max_size)},
                     {cull_interval,   OptGetter(pool_cull_interval)},
                     {max_age,         {Amount/2, Unit}},
                     {start_mfa,       {cqerl_client, start_link, [{Ip, Port}, 
                                           [  {auth, OptGetter(auth)},
                                              {ssl, OptGetter(ssl)},
                                              {sleep_duration, {Amount/2, Unit}},
                                              {keyspace, Keyspace} ]
                                        ]} 
                     }
                   ]).

make_option_getter(Local, Global) ->
    fun (Key) ->
        case proplists:get_value(Key, Local) of
            undefined ->
                case proplists:get_value(Key, Global) of
                    undefined ->
                        case Key of
                            pool_max_size -> 5;
                            pool_min_size -> 2;
                            pool_cull_interval -> {1, min};
                            client_max_age -> {30, sec};
                            auth -> {cqerl_auth_plain_handler, []};
                            ssl -> false;
                            keyspace -> undefined
                        end;
                    GlobalVal -> GlobalVal
                end;
            LocalVal -> LocalVal
        end
    end.


select_client(Clients, MatchClient = #cql_client{node=Node}, User) ->
    case ets:match_object(Clients, MatchClient) of
        AvailableClients when length(AvailableClients) > 0 ->
            RandIdx = random:uniform(length(AvailableClients)),
            #cql_client{pid=Pid, node=NodeKey} = lists:nth(RandIdx, AvailableClients),
            case is_process_alive(Pid) of
                true ->
                    cqerl_client:new_user(Pid, User),
                    {existing, Pid, NodeKey};
                false ->
                    no_available_clients
            end;
        
        [] ->
            NewMember = case Node of
                '_' -> pooler:take_group_member(cqerl);
                 _  -> pooler:take_member(pool_from_node(Node))
            end,
            case NewMember of
                error_no_members -> 
                    no_available_clients;
                {Pool, Pid} ->
                    link(Pid),
                    Node1 = node_from_pool(Pool),
                    ets:insert(Clients, #cql_client{node=Node1, busy=false, pid=Pid}),
                    cqerl_client:new_user(Pid, User),
                    {new, Pid, Node1};
                Pid ->
                    link(Pid),
                    ets:insert(Clients, #cql_client{node=Node, busy=false, pid=Pid}),
                    cqerl_client:new_user(Pid, User),
                    {new, Pid, Node}
            end
    end.

-spec prepare_node_info(NodeInfo :: any()) -> Node :: inet().

prepare_node_info({Localhost, Port}) when Localhost == localhost;
                                          Localhost == "localhost" ->
    {{127, 0, 0, 1}, Port};
prepare_node_info({Addr, Port}) when is_list(Addr) ->
    {ok, IpAddr} = inet:parse_address(Addr),
    {IpAddr, Port};
prepare_node_info(Inet) ->    
    Inet.

-spec pool_from_node(Node :: inet()) -> atom().

pool_from_node(Node = { Addr , Port, Keyspace }) when is_tuple(Addr), is_integer(Port), is_atom(Keyspace) ->
    binary_to_atom(base64:encode(term_to_binary(Node)), latin1).

-spec node_from_pool(Pool :: atom()) -> inet().

node_from_pool(PoolName) when is_atom(PoolName) ->
    binary_to_term(base64:decode(atom_to_binary(PoolName, latin1))).

    