%% @copyright 2012-2013 Gregory Fefelov, Feiko Nanninga

-module(mc_erl_app).
-export([setup/0, start/2, stop/1, os_setup/0, os_run/0]).

%% initial server setup, needs to be done only once
setup() ->
    mc_erl_chunk_manager:setup().

ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error, {already_started, App}} -> ok
    end.

start(_StartType, _StartArgs) ->
    mc_erl_server_sup:start_link().

stop(_State) -> mc_erl_server_sup:shutdown().

-spec os_setup() -> no_return().
os_setup() ->
    ok = mnesia:create_schema([node()]),
    mnesia:start(),
    {atomic, ok} = setup(),
    mnesia:stop(),
    halt(0).

%% to be called from OS' command line
os_run() ->
    lager:start(),
    ensure_started(mnesia),
    ensure_started(cutkey),
    ok = application:start(mc_erl).
