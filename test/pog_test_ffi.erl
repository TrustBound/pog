-module(pog_test_ffi).

-export([env_port/2]).

%% The port in the environment variable Name, or Default when it is not set.
env_port(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        Value -> list_to_integer(Value)
    end.
