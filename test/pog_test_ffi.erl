-module(pog_test_ffi).

-export([env_port/2, ssl_probe/1, system_cacerts/0, interceptor_rows/1,
         interceptor_keeper/1]).

%% The rows of the interceptor table for the pool Name.
interceptor_rows(Name) ->
    try ets:lookup(pog_interceptor_table, Name)
    catch error:badarg -> []
    end.

%% The process that removes the interceptor of the pool Name when the pool
%% stops.
interceptor_keeper(Name) ->
    case interceptor_rows(Name) of
        [{Name, Keeper, _Interceptor}] -> {ok, Keeper};
        _ -> {error, nil}
    end.

%% The port in the environment variable Name, or Default when it is not set.
env_port(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        Value -> list_to_integer(Value)
    end.

%% Opens one connection with the pool options that pog makes from the
%% config, without a pool. Gives the driver's error as text, so that a test
%% can see why a connection fails (a pool only says that no connection is
%% available).
ssl_probe(Config) ->
    case pog_ffi:pool_options(Config) of
        {error, Reason} ->
            {error, Reason};
        {ok, Options} ->
            % The same change as pgo_pool:normalize_pool_config/1:
            % the pool gives the driver every binary value as a string.
            Normalized = maps:map(fun(_, V) when is_binary(V) -> binary_to_list(V);
                                     (_, V) -> V
                                  end, Options),
            case pgo_handler:open(pog_ssl_probe, Normalized) of
                {ok, _Conn} ->
                    {ok, nil};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

system_cacerts() ->
    public_key:cacerts_get().
