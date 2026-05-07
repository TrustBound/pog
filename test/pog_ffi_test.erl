%%% Regression tests for `pog_ffi:convert_error/1`.
%%%
%%% Background: a previous version had no catch-all clause. Any pgo error
%%% term outside the documented set raised `function_clause`, which
%%% propagated up through `pog:query` and crashed the calling Gleam
%%% actor. In the proxy this manifested as long-lived service actors
%%% (audit_service, token_usage_writer, pricing_cache) all dying when
%%% the driver hit an undocumented error path.
%%%
%%% These tests pin two invariants:
%%%   1. Documented shapes still map to their specific QueryError variants
%%%      (regression guard: don't accidentally re-route them through the
%%%      catch-all).
%%%   2. Previously-fatal shapes now map to `connection_unavailable`
%%%      and do NOT raise.
%%%
%%% The third test (actor_survives) is the high-signal test: it proves
%%% the catch-all does what it's supposed to do at the layer that
%%% matters (process survival), not just at the FFI return-value layer.

-module(pog_ffi_test).

-include_lib("eunit/include/eunit.hrl").

%% --------------------------------------------------------------------
%% Documented shapes still map correctly.
%% --------------------------------------------------------------------

known_none_available_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error(none_available)).

known_closed_test() ->
    ?assertEqual(query_timeout, pog_ffi:convert_error(closed)).

known_unexpected_argument_count_test() ->
    ?assertEqual({unexpected_argument_count, 2, 3},
                 pog_ffi:convert_error({pgo_protocol, {parameters, 2, 3}})).

known_pgsql_error_with_constraint_test() ->
    ErrorTerm = {pgsql_error, #{
        message => <<"duplicate key">>,
        constraint => <<"users_email_key">>,
        detail => <<"Key (email)=(x) already exists.">>
    }},
    ?assertEqual({constraint_violated,
                  <<"duplicate key">>,
                  <<"users_email_key">>,
                  <<"Key (email)=(x) already exists.">>},
                 pog_ffi:convert_error(ErrorTerm)).

%% --------------------------------------------------------------------
%% Catch-all: previously-fatal shapes now return connection_unavailable.
%%
%% NOTE: this test is non-exhaustive by definition — pgo can introduce
%% new shapes any time. The point isn't to enumerate every possible
%% term; it's to assert that *some specific shapes that used to crash*
%% no longer do, and that the catch-all is wired up.
%% --------------------------------------------------------------------

catchall_pgo_error_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error({pgo_error, some_inner})).

catchall_client_disconnected_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error(client_disconnected)).

catchall_unexpected_message_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error({unexpected_message, foo})).

catchall_ssl_refused_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error(ssl_refused)).

catchall_unimplemented_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error({unimplemented, sasl_server_final})).

catchall_arbitrary_atom_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error(some_atom_we_have_never_seen)).

catchall_arbitrary_tuple_test() ->
    ?assertEqual(connection_unavailable,
                 pog_ffi:convert_error({a, b, c, d, e})).

%% --------------------------------------------------------------------
%% The high-signal test: a process calling convert_error/1 with a
%% previously-fatal shape exits NORMALLY rather than crashing with
%% function_clause. Without the catch-all this monitor would receive
%% {'DOWN', _, process, _, {function_clause, _}}.
%% --------------------------------------------------------------------

actor_survives_unmatched_shape_test() ->
    Self = self(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        connection_unavailable = pog_ffi:convert_error({pgo_error, x}),
        connection_unavailable = pog_ffi:convert_error(client_disconnected),
        connection_unavailable = pog_ffi:convert_error(ssl_refused),
        Self ! {self(), all_calls_returned}
    end),
    receive
        {Pid, all_calls_returned} -> ok
    after
        2000 ->
            ?assert(false)  %% process never reported back
    end,
    receive
        {'DOWN', MonRef, process, Pid, normal} -> ok;
        {'DOWN', MonRef, process, Pid, OtherReason} ->
            ?assertEqual(normal, OtherReason)
    after
        2000 ->
            ?assert(false)  %% no DOWN message — monitor missed exit
    end.
