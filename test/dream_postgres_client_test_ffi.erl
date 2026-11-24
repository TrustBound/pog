-module(dream_postgres_client_test_ffi).

-export([env_port/2, ssl_probe/1, system_cacerts/0]).

%% The port in the environment variable Name, or Default when it is not set.
env_port(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        Value -> list_to_integer(Value)
    end.

%% Opens one connection with the pool options that dream_postgres_client makes from the
%% config, without a pool. Gives the driver's error as text, so that a test
%% can see why a connection fails (a pool only says that no connection is
%% available).
ssl_probe(Config) ->
    case dream_postgres_client_ffi:pool_options(Config) of
        {error, Reason} ->
            {error, Reason};
        {ok, Options} ->
            % The same change as dream_postgres_driver_pool:normalize_pool_config/1:
            % the pool gives the driver every binary value as a string.
            Normalized = maps:map(fun(_, V) when is_binary(V) -> binary_to_list(V);
                                     (_, V) -> V
                                  end, Options),
            case dream_postgres_driver_handler:open(dream_postgres_client_ssl_probe, Normalized) of
                {ok, _Conn} ->
                    {ok, nil};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

system_cacerts() ->
    public_key:cacerts_get().
