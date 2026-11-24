-module(pog_ffi).

-export([query/4, query_extended/2, start/1, pool_options/1, coerce/1, null/0, checkout/1, get_pool_interceptor/1, get_pool_interceptor_safe/1, cleanup_checkout_interceptor/1, convert_error/1]).

-include_lib("pog/include/pog_Config.hrl").
-include_lib("pg_types/include/pg_types.hrl").

-define(INTERCEPTOR_TABLE, pog_interceptor_table).

ensure_interceptor_table() ->
    case ets:info(?INTERCEPTOR_TABLE) of
        undefined ->
            % Two processes can both find no table. Then the second ets:new
            % fails, and the table that the first one made is correct.
            try
                ets:new(
                    ?INTERCEPTOR_TABLE,
                    [named_table, public, set, {heir, whereis(init), undefined}]
                )
            catch
                error:badarg -> ok
            end,
            ok;
        _ ->
            ok
    end.

null() ->
    null.

coerce(Value) ->
    Value.

%% Use correct defaults for SSL connections when SSL is enabled.
%% Peers have to be verified & cacerts are fetched directly from the system.
%%
%% `server_name_indication` should be set to the value of the Host, because the
%% connection to Postgres uses a TCP connection that get upgraded to TLS, and
%% the TLS socket is sent as is, meaning the Hostname is lost when ssl module
%% get the socket. server_name_indication overrides that behaviour and send
%% the correct Hostname to the ssl module.
%% `customize_hostname_check` should be set to with the verify hostname match
%% with HTTPS, because otherwise wildcards certificaties (i.e. *.example.com)
%% will not be handled correctly.
default_ssl_options(Host, Ssl) ->
  case Ssl of
    ssl_disabled -> {false, []};
    ssl_unverified -> {true, [{verify, verify_none}]};
    ssl_verified -> {true, [
      {verify, verify_peer},
      {cacerts, public_key:cacerts_get()},
      {server_name_indication, binary_to_list(Host)},
      {customize_hostname_check, [
        {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
      ]}
    ]};
    {ssl_verified_ca_file, Path} -> {true, [
      {verify, verify_peer},
      {cacertfile, binary_to_list(Path)},
      {server_name_indication, binary_to_list(Host)},
      {customize_hostname_check, [
        {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
      ]}
    ]};
    ssl_verified_chain_only -> {true, [
      {verify, verify_peer},
      {cacerts, public_key:cacerts_get()},
      {server_name_indication, binary_to_list(Host)},
      {verify_fun, {fun verify_chain_only/3, nil}}
    ]};
    {ssl_verified_chain_only_ca_file, Path} -> {true, [
      {verify, verify_peer},
      {cacertfile, binary_to_list(Path)},
      {server_name_indication, binary_to_list(Host)},
      {verify_fun, {fun verify_chain_only/3, nil}}
    ]}
  end.

%% The `verify_fun` of the chain-only modes (`verify-ca` of libpq). It is the
%% default `verify_fun` of the ssl application, except that a host name that
%% does not match the certificate is accepted. Every other check of the
%% certificate chain stays.
verify_chain_only(_Cert, {bad_cert, hostname_check_failed}, State) ->
  {valid, State};
verify_chain_only(_Cert, {bad_cert, _} = Reason, _State) ->
  {fail, Reason};
verify_chain_only(_Cert, {extension, _}, State) ->
  {unknown, State};
verify_chain_only(_Cert, valid, State) ->
  {valid, State};
verify_chain_only(_Cert, valid_peer, State) ->
  {valid, State}.

%% A CA file is read when the pool starts, so that a file that is missing or
%% holds no certificate is an error of `start`, not a connection that fails
%% again and again later.
check_ca_file({ssl_verified_ca_file, Path}) -> check_ca_file(Path);
check_ca_file({ssl_verified_chain_only_ca_file, Path}) -> check_ca_file(Path);
check_ca_file(Path) when is_binary(Path) ->
  case file:read_file(Path) of
    {ok, Pem} ->
      case [Der || {'Certificate', Der, not_encrypted} <- pem_entries(Pem)] of
        [] ->
          {error, <<"pog: the CA file ", Path/binary,
                    " holds no PEM certificate">>};
        _ ->
          ok
      end;
    {error, Reason} ->
      {error, iolist_to_binary(io_lib:format(
        "pog: the CA file ~ts cannot be read: ~p", [Path, Reason]))}
  end;
check_ca_file(_) -> ok.

pem_entries(Pem) ->
  try public_key:pem_decode(Pem) catch _:_ -> [] end.

start(Config) ->
    case pool_options(Config) of
        {ok, Options} ->
            #config{pool_name = PoolName, interceptor = Interceptor} = Config,
            ensure_interceptor_table(),
            ets:insert(?INTERCEPTOR_TABLE, {PoolName, Interceptor}),
            pgo_pool:start_link(PoolName, Options);
        {error, _} = Error ->
            Error
    end.

pool_options(Config) ->
    % Unfortunately this has to be supplied via global mutable state currently.
    application:set_env(pg_types, timestamp_config, integer_system_time_microseconds),
    #config{
        host = Host,
        port = Port,
        database = Database,
        user = User,
        password = Password,
        ssl = Ssl,
        connection_parameters = ConnectionParameters,
        pool_size = PoolSize,
        queue_target = QueueTarget,
        queue_interval = QueueInterval,
        idle_interval = IdleInterval,
        trace = Trace,
        ip_version = IpVersion,
        rows_as_map = RowsAsMap
    } = Config,
    case check_ca_file(Ssl) of
        ok ->
            {SslActivated, SslOptions} = default_ssl_options(Host, Ssl),
            Options1 = #{
                host => Host,
                port => Port,
                database => Database,
                user => User,
                ssl => SslActivated,
                ssl_options => SslOptions,
                connection_parameters => ConnectionParameters,
                pool_size => PoolSize,
                queue_target => QueueTarget,
                queue_interval => QueueInterval,
                idle_interval => IdleInterval,
                trace => Trace,
                decode_opts => [{return_rows_as_maps, RowsAsMap}],
                socket_options => case IpVersion of
                    ipv4 -> [];
                    ipv6 -> [inet6]
                end
            },
            Options2 = case Password of
                {some, Pw} -> maps:put(password, Pw, Options1);
                none -> Options1
            end,
            {ok, Options2};
        {error, _} = Error ->
            Error
    end.

query(Pool, Sql, Arguments, Timeout) ->
    Res = case Pool of
        {single_connection, Conn} ->
            pgo_handler:extended_query(Conn, Sql, Arguments, #{});
        {pool, Name} ->
            Options = #{
                pool => Name,
                pool_options => [{timeout, Timeout}]
            },
            pgo:query(Sql, Arguments, Options)
    end,
    case Res of
        #{rows := Rows, num_rows := NumRows} ->
            {ok, {count(NumRows), Rows}};

        {error, Error} ->
            {error, convert_error(Error)}
    end.

query_extended(Conn, Sql) ->
    case pgo_handler:extended_query(Conn, Sql, [], #{queue_time => undefined}) of
        #{rows := Rows, num_rows := NumRows} ->
            {ok, {count(NumRows), Rows}};

        {error, Error} ->
            {error, convert_error(Error)}
    end.

%% The driver gives the row count of the command tag, or for a command
%% without a row count (such as CREATE TABLE) the atom `nil` or the object
%% of the tag (such as `table`). Such a command has the count 0, as
%% `PQcmdTuples` of libpq gives an empty string for it.
count(NumRows) when is_integer(NumRows) ->
    NumRows;
count(_) ->
    0.

checkout(Name) when is_atom(Name) ->
    case pgo:checkout(Name) of
        {ok, Ref, Conn} ->
            % Copy pool's interceptor to connection for transaction support
            case pool_interceptor(Name) of
                {some, Interceptor} -> put({pog_conn_interceptor, Conn}, Interceptor);
                none -> ok
            end,
            {ok, {Ref, Conn}};
        {error, Error} -> {error, convert_error(Error)}
    end.

convert_error(none_available) ->
    connection_unavailable;
convert_error({pgo_protocol, {parameters, Expected, Got}}) ->
    {unexpected_argument_count, Expected, Got};
convert_error({pgsql_error, #{
    message := Message,
    constraint := Constraint,
    detail := Detail
}}) ->
    {constraint_violated, Message, Constraint, Detail};
convert_error({pgsql_error, #{code := Code, message := Message}}) ->
    Constant = case pog:error_code_name(Code) of
        {ok, X} -> X;
        {error, nil} -> <<"unknown">>
    end,
    {postgresql_error, Code, Constant, Message};
convert_error(#{
    error := badarg_encoding,
    type_info := #type_info{name = Expected},
    value := Value
}) ->
    Got = list_to_binary(io_lib:format("~p", [Value])),
    {unexpected_argument_type, Expected, Got};
convert_error(closed) ->
    query_timeout;
%% Catch-all: pgo can emit shapes outside the documented set
%% (e.g. {pgo_error, _}, {unexpected_message, _}, client_disconnected,
%% client_timeout, ssl_refused, {unimplemented, _}, etc.). Without this
%% clause those shapes raise function_clause and crash the calling
%% process, which can be a long-lived process of the application.
%% We map them all to connection_unavailable
%% so callers see a known, recoverable variant.
%%
%% Emits a structured `logger:warning` so consumers with a structured
%% formatter (e.g. JSON) get queryable fields, while consumers with a
%% string formatter still get something readable via `~p`. We
%% intentionally do NOT set `domain` metadata: many default handlers
%% install a `no_domain` filter that drops events whose domain is set
%% to anything other than the handler's expected list, which would
%% silence this warning instead of routing it. The error term is
%% captured as a binary so it can't tunnel through a JSON formatter as
%% a raw Erlang term.
convert_error(Other) ->
    logger:warning(#{
        component => pog_convert_error,
        event => unhandled_driver_error,
        error_term => list_to_binary(io_lib:format("~p", [Other]))
    }),
    connection_unavailable.

%% Interceptor support
%% The interceptor of a pool is the row {PoolName, Interceptor} of the
%% interceptor table, with the interceptor as an option. The row is written
%% before the pool starts, so the first query of the pool uses it.
pool_interceptor(PoolName) ->
    try ets:lookup(?INTERCEPTOR_TABLE, PoolName) of
        [{PoolName, Interceptor}] -> Interceptor;
        [] -> none
    catch
        error:badarg -> none
    end.

%% Get interceptor for a connection
get_pool_interceptor(Connection) ->
    case Connection of
        {pool, Name} ->
            pool_interceptor(Name);
        {single_connection, Conn} ->
            % For single connections (from transactions), lookup by connection handle
            case get({pog_conn_interceptor, Conn}) of
                undefined -> none;
                Interceptor -> {some, Interceptor}
            end
    end.

get_pool_interceptor_safe(Connection) ->
    case Connection of
        {pool, _} -> get_pool_interceptor(Connection);
        {single_connection, _} -> get_pool_interceptor(Connection);
        {disconnected, _} -> none;
        _ -> none
    end.

%% Cleanup interceptor reference when connection is checked back in
cleanup_checkout_interceptor(Conn) ->
    erase({pog_conn_interceptor, Conn}),
    nil.
