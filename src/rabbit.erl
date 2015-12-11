%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2015 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit).

-behaviour(application).

-export([start/0, boot/0, stop/0,
         stop_and_halt/0, await_startup/0, status/0, is_running/0,
         is_running/1, environment/0, rotate_logs/1, force_event_refresh/1,
         start_fhc/0]).
-export([start/2, stop/1]).
-export([start_apps/1, stop_apps/1]).
-export([log_location/1, config_files/0]). %% for testing and mgmt-agent

-ifdef(TEST).

-export([start_logger/0]).

-endif.

%%---------------------------------------------------------------------------
%% Boot steps.
-export([maybe_insert_default_data/0, boot_delegate/0, recover/0]).

%% for tests
-export([validate_msg_store_io_batch_size_and_credit_disc_bound/2]).

-rabbit_boot_step({pre_boot, [{description, "rabbit boot start"}]}).

-rabbit_boot_step({codec_correctness_check,
                   [{description, "codec correctness check"},
                    {mfa,         {rabbit_binary_generator,
                                   check_empty_frame_size,
                                   []}},
                    {requires,    pre_boot},
                    {enables,     external_infrastructure}]}).

%% rabbit_alarm currently starts memory and disk space monitors
-rabbit_boot_step({rabbit_alarm,
                   [{description, "alarm handler"},
                    {mfa,         {rabbit_alarm, start, []}},
                    {requires,    pre_boot},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({database,
                   [{mfa,         {rabbit_mnesia, init, []}},
                    {requires,    file_handle_cache},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({database_sync,
                   [{description, "database sync"},
                    {mfa,         {rabbit_sup, start_child, [mnesia_sync]}},
                    {requires,    database},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({file_handle_cache,
                   [{description, "file handle cache server"},
                    {mfa,         {rabbit, start_fhc, []}},
                    %% FHC needs memory monitor to be running
                    {requires,    rabbit_alarm},
                    {enables,     worker_pool}]}).

-rabbit_boot_step({worker_pool,
                   [{description, "worker pool"},
                    {mfa,         {rabbit_sup, start_supervisor_child,
                                   [worker_pool_sup]}},
                    {requires,    pre_boot},
                    {enables,     external_infrastructure}]}).

-rabbit_boot_step({external_infrastructure,
                   [{description, "external infrastructure ready"}]}).

-rabbit_boot_step({rabbit_registry,
                   [{description, "plugin registry"},
                    {mfa,         {rabbit_sup, start_child,
                                   [rabbit_registry]}},
                    {requires,    external_infrastructure},
                    {enables,     kernel_ready}]}).

-rabbit_boot_step({rabbit_event,
                   [{description, "statistics event manager"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_event]}},
                    {requires,    external_infrastructure},
                    {enables,     kernel_ready}]}).

-rabbit_boot_step({kernel_ready,
                   [{description, "kernel ready"},
                    {requires,    external_infrastructure}]}).

-rabbit_boot_step({rabbit_memory_monitor,
                   [{description, "memory monitor"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_memory_monitor]}},
                    {requires,    rabbit_alarm},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({guid_generator,
                   [{description, "guid generator"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_guid]}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({delegate_sup,
                   [{description, "cluster delegate"},
                    {mfa,         {rabbit, boot_delegate, []}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({rabbit_node_monitor,
                   [{description, "node monitor"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_node_monitor]}},
                    {requires,    [rabbit_alarm, guid_generator]},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({rabbit_epmd_monitor,
                   [{description, "epmd monitor"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [rabbit_epmd_monitor]}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-rabbit_boot_step({core_initialized,
                   [{description, "core initialized"},
                    {requires,    kernel_ready}]}).

-rabbit_boot_step({empty_db_check,
                   [{description, "empty DB check"},
                    {mfa,         {?MODULE, maybe_insert_default_data, []}},
                    {requires,    core_initialized},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({recovery,
                   [{description, "exchange, queue and binding recovery"},
                    {mfa,         {rabbit, recover, []}},
                    {requires,    core_initialized},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({mirrored_queues,
                   [{description, "adding mirrors to queues"},
                    {mfa,         {rabbit_mirror_queue_misc, on_node_up, []}},
                    {requires,    recovery},
                    {enables,     routing_ready}]}).

-rabbit_boot_step({routing_ready,
                   [{description, "message delivery logic ready"},
                    {requires,    core_initialized}]}).

-rabbit_boot_step({log_relay,
                   [{description, "error log relay"},
                    {mfa,         {rabbit_sup, start_child,
                                   [rabbit_error_logger_lifecycle,
                                    supervised_lifecycle,
                                    [rabbit_error_logger_lifecycle,
                                     {rabbit_error_logger, start, []},
                                     {rabbit_error_logger, stop,  []}]]}},
                    {requires,    routing_ready},
                    {enables,     networking}]}).

-rabbit_boot_step({direct_client,
                   [{description, "direct client"},
                    {mfa,         {rabbit_direct, boot, []}},
                    {requires,    log_relay}]}).

-rabbit_boot_step({networking,
                   [{mfa,         {rabbit_networking, boot, []}},
                    {requires,    log_relay}]}).

-rabbit_boot_step({notify_cluster,
                   [{description, "notify cluster nodes"},
                    {mfa,         {rabbit_node_monitor, notify_node_up, []}},
                    {requires,    networking}]}).

-rabbit_boot_step({background_gc,
                   [{description, "background garbage collection"},
                    {mfa,         {rabbit_sup, start_restartable_child,
                                   [background_gc]}},
                    {enables,     networking}]}).

%%---------------------------------------------------------------------------

-include("rabbit_framing.hrl").
-include("rabbit.hrl").

-define(APPS, [os_mon, mnesia, rabbit_common, rabbit]).

%% HiPE compilation uses multiple cores anyway, but some bits are
%% IO-bound so we can go faster if we parallelise a bit more. In
%% practice 2 processes seems just as fast as any other number > 1,
%% and keeps the progress bar realistic-ish.
-define(HIPE_PROCESSES, 2).
-define(ASYNC_THREADS_WARNING_THRESHOLD, 8).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(file_suffix() :: binary()).
%% this really should be an abstract type
-type(log_location() :: 'tty' | 'undefined' | file:filename()).
-type(param() :: atom()).
-type(app_name() :: atom()).

-spec(start/0 :: () -> 'ok').
-spec(boot/0 :: () -> 'ok').
-spec(stop/0 :: () -> 'ok').
-spec(stop_and_halt/0 :: () -> no_return()).
-spec(await_startup/0 :: () -> 'ok').
-spec(status/0 ::
        () -> [{pid, integer()} |
               {running_applications, [{atom(), string(), string()}]} |
               {os, {atom(), atom()}} |
               {erlang_version, string()} |
               {memory, any()}]).
-spec(is_running/0 :: () -> boolean()).
-spec(is_running/1 :: (node()) -> boolean()).
-spec(environment/0 :: () -> [{param(), term()}]).
-spec(rotate_logs/1 :: (file_suffix()) -> rabbit_types:ok_or_error(any())).
-spec(force_event_refresh/1 :: (reference()) -> 'ok').

-spec(log_location/1 :: ('sasl' | 'kernel') -> log_location()).

-spec(start/2 :: ('normal',[]) ->
		      {'error',
		       {'erlang_version_too_old',
                        {'found',string(),string()},
                        {'required',string(),string()}}} |
		      {'ok',pid()}).
-spec(stop/1 :: (_) -> 'ok').

-spec(maybe_insert_default_data/0 :: () -> 'ok').
-spec(boot_delegate/0 :: () -> 'ok').
-spec(recover/0 :: () -> 'ok').
-spec(start_apps/1 :: ([app_name()]) -> 'ok').
-spec(stop_apps/1 :: ([app_name()]) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

%% HiPE compilation happens before we have log handlers - so we have
%% to io:format/2, it's all we can do.

maybe_hipe_compile() ->
    {ok, Want} = application:get_env(rabbit, hipe_compile),
    Can = code:which(hipe) =/= non_existing,
    case {Want, Can} of
        {true,  true}  -> hipe_compile();
        {true,  false} -> false;
        {false, _}     -> {ok, disabled}
    end.

log_hipe_result({ok, disabled}) ->
    ok;
log_hipe_result({ok, already_compiled}) ->
    rabbit_log:info(
      "HiPE in use: modules already natively compiled.~n", []);
log_hipe_result({ok, Count, Duration}) ->
    rabbit_log:info(
      "HiPE in use: compiled ~B modules in ~Bs.~n", [Count, Duration]);
log_hipe_result(false) ->
    io:format(
      "~nNot HiPE compiling: HiPE not found in this Erlang installation.~n"),
    rabbit_log:warning(
      "Not HiPE compiling: HiPE not found in this Erlang installation.~n").

%% HiPE compilation happens before we have log handlers and can take a
%% long time, so make an exception to our no-stdout policy and display
%% progress via stdout.
hipe_compile() ->
    {ok, HipeModulesAll} = application:get_env(rabbit, hipe_modules),
    HipeModules = [HM || HM <- HipeModulesAll,
                   code:which(HM) =/= non_existing andalso
                   %% We skip modules already natively compiled. This
                   %% happens when RabbitMQ is stopped (just the
                   %% application, not the entire node) and started
                   %% again.
                   already_hipe_compiled(HM)],
    case HipeModules of
        [] -> {ok, already_compiled};
        _  -> do_hipe_compile(HipeModules)
    end.

already_hipe_compiled(Mod) ->
    try
    %% OTP 18.x or later
	Mod:module_info(native) =:= false
    %% OTP prior to 18.x
    catch error:badarg ->
	code:is_module_native(Mod) =:= false
    end.

do_hipe_compile(HipeModules) ->
    Count = length(HipeModules),
    io:format("~nHiPE compiling:  |~s|~n                 |",
              [string:copies("-", Count)]),
    T1 = time_compat:monotonic_time(),
    %% We use code:get_object_code/1 below to get the beam binary,
    %% instead of letting hipe get it itself, because hipe:c/{1,2}
    %% expects the given filename to actually exist on disk: it does not
    %% work with an EZ archive (rabbit_common is one).
    %%
    %% Then we use the mode advanced hipe:compile/4 API because the
    %% simpler hipe:c/3 is not exported (as of Erlang 18.1.4). This
    %% advanced API does not load automatically the code, except if the
    %% 'load' option is set.
    PidMRefs = [spawn_monitor(fun () -> [begin
                                             {M, Beam, _} =
                                               code:get_object_code(M),
                                             {ok, _} =
                                               hipe:compile(M, [], Beam,
                                                            [o3, load]),
                                             io:format("#")
                                         end || M <- Ms]
                              end) ||
                   Ms <- split(HipeModules, ?HIPE_PROCESSES)],
    [receive
         {'DOWN', MRef, process, _, normal} -> ok;
         {'DOWN', MRef, process, _, Reason} -> exit(Reason)
     end || {_Pid, MRef} <- PidMRefs],
    T2 = time_compat:monotonic_time(),
    Duration = time_compat:convert_time_unit(T2 - T1, native, seconds),
    io:format("|~n~nCompiled ~B modules in ~Bs~n", [Count, Duration]),
    {ok, Count, Duration}.

split(L, N) -> split0(L, [[] || _ <- lists:seq(1, N)]).

split0([],       Ls)       -> Ls;
split0([I | Is], [L | Ls]) -> split0(Is, Ls ++ [[I | L]]).

ensure_application_loaded() ->
    %% We end up looking at the rabbit app's env for HiPE and log
    %% handling, so it needs to be loaded. But during the tests, it
    %% may end up getting loaded twice, so guard against that.
    case application:load(rabbit) of
        ok                                -> ok;
        {error, {already_loaded, rabbit}} -> ok
    end.

start() ->
    start_it(fun() ->
                     %% We do not want to upgrade mnesia after just
                     %% restarting the app.
                     ok = ensure_application_loaded(),
                     HipeResult = maybe_hipe_compile(),
                     ok = start_logger(),
                     log_hipe_result(HipeResult),
                     rabbit_node_monitor:prepare_cluster_status_files(),
                     rabbit_mnesia:check_cluster_consistency(),
                     broker_start()
             end).

boot() ->
    start_it(fun() ->
                     ok = ensure_application_loaded(),
                     HipeResult = maybe_hipe_compile(),
                     ok = start_logger(),
                     log_hipe_result(HipeResult),
                     rabbit_node_monitor:prepare_cluster_status_files(),
                     ok = rabbit_upgrade:maybe_upgrade_mnesia(),
                     %% It's important that the consistency check happens after
                     %% the upgrade, since if we are a secondary node the
                     %% primary node will have forgotten us
                     rabbit_mnesia:check_cluster_consistency(),
                     broker_start()
             end).

broker_start() ->
    Plugins = rabbit_plugins:setup(),
    ToBeLoaded = Plugins ++ ?APPS,
    start_apps(ToBeLoaded),
    case code:load_file(sd_notify) of
        {module, sd_notify} -> SDNotify = sd_notify,
                               SDNotify:sd_notify(0, "READY=1");
        {error, _} -> ok
    end,
    ok = log_broker_started(rabbit_plugins:active()).

start_it(StartFun) ->
    Marker = spawn_link(fun() -> receive stop -> ok end end),
    case catch register(rabbit_boot, Marker) of
        true -> try
                    case is_running() of
                        true  -> ok;
                        false -> StartFun()
                    end
                catch
                    throw:{could_not_start, _App, _Reason} = Err ->
                        boot_error(Err, not_available);
                    _:Reason ->
                        boot_error(Reason, erlang:get_stacktrace())
                after
                    unlink(Marker),
                    Marker ! stop,
                    %% give the error loggers some time to catch up
                    timer:sleep(100)
                end;
        _    -> unlink(Marker),
                Marker ! stop
    end.

stop() ->
    case whereis(rabbit_boot) of
        undefined -> ok;
        _         -> await_startup(true)
    end,
    rabbit_log:info("Stopping RabbitMQ~n", []),
    Apps = ?APPS ++ rabbit_plugins:active(),
    stop_apps(app_utils:app_dependency_order(Apps, true)),
    rabbit_log:info("Stopped RabbitMQ application~n", []).

stop_and_halt() ->
    try
        stop()
    after
        rabbit_log:info("Halting Erlang VM~n", []),
        init:stop()
    end,
    ok.

start_apps(Apps) ->
    app_utils:load_applications(Apps),
    OrderedApps = app_utils:app_dependency_order(Apps, false),
    case lists:member(rabbit, Apps) of
        false -> rabbit_boot_steps:run_boot_steps(Apps); %% plugin activation
        true  -> ok                    %% will run during start of rabbit app
    end,
    ok = app_utils:start_applications(OrderedApps,
                                      handle_app_error(could_not_start)).

stop_apps(Apps) ->
    ok = app_utils:stop_applications(
           Apps, handle_app_error(error_during_shutdown)),
    case lists:member(rabbit, Apps) of
        %% plugin deactivation
        false -> rabbit_boot_steps:run_cleanup_steps(Apps);
        true  -> ok %% it's all going anyway
    end,
    ok.

handle_app_error(Term) ->
    fun(App, {bad_return, {_MFA, {'EXIT', ExitReason}}}) ->
            throw({Term, App, ExitReason});
       (App, Reason) ->
            throw({Term, App, Reason})
    end.

await_startup() ->
    await_startup(false).

await_startup(HaveSeenRabbitBoot) ->
    %% We don't take absence of rabbit_boot as evidence we've started,
    %% since there's a small window before it is registered.
    case whereis(rabbit_boot) of
        undefined -> case HaveSeenRabbitBoot orelse is_running() of
                         true  -> ok;
                         false -> timer:sleep(100),
                                  await_startup(false)
                     end;
        _         -> timer:sleep(100),
                     await_startup(true)
    end.

status() ->
    S1 = [{pid,                  list_to_integer(os:getpid())},
          {running_applications, rabbit_misc:which_applications()},
          {os,                   os:type()},
          {erlang_version,       erlang:system_info(system_version)},
          {memory,               rabbit_vm:memory()},
          {alarms,               alarms()},
          {listeners,            listeners()}],
    S2 = rabbit_misc:filter_exit_map(
           fun ({Key, {M, F, A}}) -> {Key, erlang:apply(M, F, A)} end,
           [{vm_memory_high_watermark, {vm_memory_monitor,
                                        get_vm_memory_high_watermark, []}},
            {vm_memory_limit,          {vm_memory_monitor,
                                        get_memory_limit, []}},
            {disk_free_limit,          {rabbit_disk_monitor,
                                        get_disk_free_limit, []}},
            {disk_free,                {rabbit_disk_monitor,
                                        get_disk_free, []}}]),
    S3 = rabbit_misc:with_exit_handler(
           fun () -> [] end,
           fun () -> [{file_descriptors, file_handle_cache:info()}] end),
    S4 = [{processes,        [{limit, erlang:system_info(process_limit)},
                              {used, erlang:system_info(process_count)}]},
          {run_queue,        erlang:statistics(run_queue)},
          {uptime,           begin
                                 {T,_} = erlang:statistics(wall_clock),
                                 T div 1000
                             end},
          {kernel,           {net_ticktime, net_kernel:get_net_ticktime()}}],
    S1 ++ S2 ++ S3 ++ S4.

alarms() ->
    Alarms = rabbit_misc:with_exit_handler(rabbit_misc:const([]),
                                           fun rabbit_alarm:get_alarms/0),
    N = node(),
    %% [{{resource_limit,memory,rabbit@mercurio},[]}]
    [Limit || {{resource_limit, Limit, Node}, _} <- Alarms, Node =:= N].

listeners() ->
    Listeners = try
                    rabbit_networking:active_listeners()
                catch
                    exit:{aborted, _} -> []
                end,
    [{Protocol, Port, rabbit_misc:ntoa(IP)} ||
        #listener{node       = Node,
                  protocol   = Protocol,
                  ip_address = IP,
                  port       = Port} <- Listeners, Node =:= node()].

%% TODO this only determines if the rabbit application has started,
%% not if it is running, never mind plugins. It would be nice to have
%% more nuance here.
is_running() -> is_running(node()).

is_running(Node) -> rabbit_nodes:is_process_running(Node, rabbit).

environment() ->
    [{A, environment(A)} ||
        {A, _, _} <- lists:keysort(1, application:which_applications())].

environment(App) ->
    Ignore = [default_pass, included_applications],
    lists:keysort(1, [P || P = {K, _} <- application:get_all_env(App),
                           not lists:member(K, Ignore)]).


rotate_logs(BinarySuffix) ->
    rabbit_log:info("Rotating logs with suffix '~s'~n", [BinarySuffix]),
    Suffix = binary_to_list(BinarySuffix),
    ok = rotate_lager_handlers(Suffix, application:get_env(lager, handlers)),
    ok = rotate_lager_sinks(Suffix),
    timer:sleep(2000),
    rabbit_log:info("New log after rotation."),
    error_logger:info_msg("New sasl log after rotation.").

rotate_lager_handlers(_Suffix, undefined) -> 
    error_logger:error_msg("Cannot rotate logs. No lager handlers defined."),
    ok;
rotate_lager_handlers(Suffix, {ok, Handlers}) -> 
    rotate_lager_handlers(Suffix, Handlers);
rotate_lager_handlers(Suffix, Handlers) when is_list(Handlers) -> 
    lists:foreach(
        fun({lager_file_backend, Settings}) ->
            {file, File} = proplists:lookup(file, Settings),
            {ok, Dir} = application:get_env(lager, log_root),
            FileName = filename:join(Dir, File),
            case Suffix of
                [] -> 
                    file:delete(FileName);
                _ -> 
                    NextFile = FileName ++ Suffix,
                    file:rename(FileName, NextFile)
            end;
           (_) -> ok
        end,
        Handlers).

rotate_lager_sinks(Suffix) -> 
    case application:get_env(lager, extra_sinks) of
        undefined -> 
            error_logger:error_msg(
              "Cannot rotate logs. No lager extra_sinks defined."),
            ok;
        {ok, Sinks} ->
            lists:foreach(
              fun({_, Sink}) -> 
                  rotate_lager_handlers(Suffix, 
                                        proplists:get_value(handlers, Sink))
              end,
              Sinks)
    end.

%%--------------------------------------------------------------------

start(normal, []) ->
    case erts_version_check() of
        ok ->
            rabbit_log:info("Starting RabbitMQ ~s on Erlang ~s~n~s~n~s~n",
                            [rabbit_misc:version(), rabbit_misc:otp_release(),
                             ?COPYRIGHT_MESSAGE, ?INFORMATION_MESSAGE]),
            {ok, SupPid} = rabbit_sup:start_link(),
            true = register(rabbit, self()),
            print_banner(),
            log_banner(),
            warn_if_kernel_config_dubious(),
            warn_if_disc_io_options_dubious(),
            rabbit_boot_steps:run_boot_steps(),
            {ok, SupPid};
        Error ->
            Error
    end.

stop(_State) ->
    ok = rabbit_alarm:stop(),
    ok = case rabbit_mnesia:is_clustered() of
             true  -> rabbit_amqqueue:on_node_down(node());
             false -> rabbit_table:clear_ram_only_tables()
         end,
    ok.

-ifdef(use_specs).
-spec(boot_error/2 :: (term(), not_available | [tuple()]) -> no_return()).
-endif.
boot_error({could_not_start, rabbit, {{timeout_waiting_for_tables, _}, _}},
           _Stacktrace) ->
    AllNodes = rabbit_mnesia:cluster_nodes(all),
    Suffix = "~nBACKGROUND~n==========~n~n"
        "This cluster node was shut down while other nodes were still running.~n"
        "To avoid losing data, you should start the other nodes first, then~n"
        "start this one. To force this node to start, first invoke~n"
        "\"rabbitmqctl force_boot\". If you do so, any changes made on other~n"
        "cluster nodes after this one was shut down may be lost.~n",
    {Err, Nodes} =
        case AllNodes -- [node()] of
            [] -> {"Timeout contacting cluster nodes. Since RabbitMQ was"
                   " shut down forcefully~nit cannot determine which nodes"
                   " are timing out.~n" ++ Suffix, []};
            Ns -> {rabbit_misc:format(
                     "Timeout contacting cluster nodes: ~p.~n" ++ Suffix, [Ns]),
                   Ns}
        end,
    log_boot_error_and_exit(
      timeout_waiting_for_tables,
      Err ++ rabbit_nodes:diagnostics(Nodes) ++ "~n~n", []);
boot_error(Reason, Stacktrace) ->
    Fmt = "Error description:~n   ~p~n~n"
        "Log files (may contain more information):~n   ~s~n   ~s~n~n",
    Args = [Reason, log_location(kernel), log_location(sasl)],
    boot_error(Reason, Fmt, Args, Stacktrace).

-ifdef(use_specs).
-spec(boot_error/4 :: (term(), string(), [any()], not_available | [tuple()])
                      -> no_return()).
-endif.
boot_error(Reason, Fmt, Args, not_available) ->
    log_boot_error_and_exit(Reason, Fmt, Args);
boot_error(Reason, Fmt, Args, Stacktrace) ->
    log_boot_error_and_exit(Reason, Fmt ++ "Stack trace:~n   ~p~n~n",
                            Args ++ [Stacktrace]).

log_boot_error_and_exit(Reason, Format, Args) ->
    io:format("~n~nBOOT FAILED~n===========~n~n" ++ Format, Args),
    rabbit_log:info(Format, Args),
    timer:sleep(1000),
    exit(Reason).

%%---------------------------------------------------------------------------
%% boot step functions

boot_delegate() ->
    {ok, Count} = application:get_env(rabbit, delegate_count),
    rabbit_sup:start_supervisor_child(delegate_sup, [Count]).

recover() ->
    rabbit_policy:recover(),
    Qs = rabbit_amqqueue:recover(),
    ok = rabbit_binding:recover(rabbit_exchange:recover(),
                                [QName || #amqqueue{name = QName} <- Qs]),
    rabbit_amqqueue:start(Qs).

maybe_insert_default_data() ->
    case rabbit_table:needs_default_data() of
        true  -> insert_default_data();
        false -> ok
    end.

insert_default_data() ->
    {ok, DefaultUser} = application:get_env(default_user),
    {ok, DefaultPass} = application:get_env(default_pass),
    {ok, DefaultTags} = application:get_env(default_user_tags),
    {ok, DefaultVHost} = application:get_env(default_vhost),
    {ok, [DefaultConfigurePerm, DefaultWritePerm, DefaultReadPerm]} =
        application:get_env(default_permissions),
    ok = rabbit_vhost:add(DefaultVHost),
    ok = rabbit_auth_backend_internal:add_user(DefaultUser, DefaultPass),
    ok = rabbit_auth_backend_internal:set_tags(DefaultUser, DefaultTags),
    ok = rabbit_auth_backend_internal:set_permissions(DefaultUser,
                                                      DefaultVHost,
                                                      DefaultConfigurePerm,
                                                      DefaultWritePerm,
                                                      DefaultReadPerm),
    ok.

%%---------------------------------------------------------------------------
%% logging

start_logger() ->
  application:stop(lager),
  ensure_lager_configured(),
  lager:start(),
  rabbit_log:info("Lager found. Using lager for logs"),
  error_logger:info_msg("Lager found. Using lager for sasl logs"),
  ensure_log_working(),
  ok.

ensure_log_working() ->
    {ok, Dir} = application:get_env(lager, log_root),
    {ok, Handlers} = application:get_env(lager, handlers),
    Sinks = application:get_env(lager, extra_sinks, []),
    [ ensure_lager_handler_file_exist(Dir, Handler)
      || Handler <- Handlers ],
    case proplists:get_value(rabbitmq_lager_event, Sinks) of
        undefined -> throw({error, 
            {cannot_log, rabbitmq_lager_event_sink_undefined}});
        Sink ->
            SinkHandlers = proplists:get_value(handlers, Sink, []),
            [ ensure_lager_handler_file_exist(Dir, Handler)
              || Handler <- SinkHandlers ]
    end.

ensure_lager_handler_file_exist(Dir, {lager_file_backend, Settings}) ->
    FileName = lager_file_name(Settings),
    ensure_logfile_exist(Dir, FileName);
ensure_lager_handler_file_exist(_Dir, _) -> ok.

lager_file_name(Settings) when is_list(Settings) ->
    {file, FileName} = proplists:lookup(file, Settings),
    FileName;
lager_file_name({FileName, _}) -> FileName;
lager_file_name({FileName, _, _, _, _}) -> FileName;
lager_file_name(_) -> 
    throw({error, {cannot_log, lager_file_backend_config_invalid}}).


ensure_logfile_exist(Dir, FileName) ->
    LogFile = filename:join(Dir, FileName),
    case rabbit_file:read_file_info(filename:join(Dir, FileName)) of
      {ok,_} -> ok;
      {error, Err} -> throw({error, {cannot_log_to_file, LogFile, Err}})
    end.

lager_handlers(Silent) when Silent == silent; Silent == false ->
  [];
lager_handlers(tty) ->
  [{lager_console_backend, debug}];
lager_handlers({file, FileName}) ->
  {ok, Dir} = application:get_env(lager, log_root),
  rabbit_file:ensure_parent_dirs_exist(filename:join(Dir, FileName)),
  [{lager_file_backend, [
    {file, FileName}, {level, debug}, {date, ""}, {size, 0}]}].


ensure_lager_configured() ->
    case lager_configured() of
        false -> configure_lager();
        true -> ok
    end.

% Lager should have handlers or sinks
lager_configured() ->
    application:get_env(lager, handlers) =/= undefined
    andalso
    application:get_env(lager, extra_sinks) =/= undefined.

configure_lager() ->
    application:load(lager),
    case application:get_env(lager, log_root) of
        undefined -> 
            application:set_env(lager, log_root, 
                application:get_env(rabbit, log_base, undefined));
        _ -> ok
    end,
    case application:get_env(lager, handlers) of
        undefined ->
            DefaultHandlers = lager_handlers(application:get_env(rabbit, 
                                                                 error_logger, 
                                                                 tty)),
            SaslHandlers = lager_handlers(application:get_env(rabbit, 
                                                              sasl_error_logger, 
                                                              tty)),
            Sinks = [
                {rabbitmq_lager_event, [{handlers, DefaultHandlers}]}
                 % TODO Waiting for PR https://github.com/basho/lager/pull/303
                 % ,{error_logger_lager_event, [{handlers, SaslHandlers}]}
                ],
                Handlers = SaslHandlers,
            application:set_env(lager, handlers, Handlers),
            application:set_env(lager, extra_sinks, Sinks);
        _ -> ok
    end.

log_location(Type) ->
    ensure_lager_configured(),
    LagerHandlers = case Type of 
        kernel ->
            proplists:get_value(handlers, 
                proplists:get_value(rabbitmq_lager_event, 
                    application:get_env(lager, extra_sinks, [])));
        sasl ->
            application:get_env(lager, handlers, undefined)
    end,
    case LagerHandlers of
        undefined -> 
            throw({error, {cannot_log, lager_handlers_undefined, Type}, application:get_env(rabbit, sasl_error_logger)});
        _ ->
            case proplists:get_value(lager_file_backend, LagerHandlers) of
                undefined -> 
                    case proplists:get_value(lager_console_backend, 
                                             LagerHandlers) of
                        undefined -> undefined;
                        _ -> tty
                    end;
                Settings ->
                    lager_file_name(Settings)
            end
    end.

force_event_refresh(Ref) ->
    rabbit_direct:force_event_refresh(Ref),
    rabbit_networking:force_connection_event_refresh(Ref),
    rabbit_channel:force_event_refresh(Ref),
    rabbit_amqqueue:force_event_refresh(Ref).

%%---------------------------------------------------------------------------
%% misc

log_broker_started(Plugins) ->
    PluginList = iolist_to_binary([rabbit_misc:format(" * ~s~n", [P])
                                   || P <- Plugins]),
    rabbit_log:info(
      "Server startup complete; ~b plugins started.~n~s",
      [length(Plugins), PluginList]),
    io:format(" completed with ~p plugins.~n", [length(Plugins)]).

erts_version_check() ->
    ERTSVer = erlang:system_info(version),
    OTPRel = erlang:system_info(otp_release),
    case rabbit_misc:version_compare(?ERTS_MINIMUM, ERTSVer, lte) of
        true when ?ERTS_MINIMUM =/= ERTSVer ->
            ok;
        true when ?ERTS_MINIMUM =:= ERTSVer andalso ?OTP_MINIMUM =< OTPRel ->
            %% When a critical regression or bug is found, a new OTP
            %% release can be published without changing the ERTS
            %% version. For instance, this is the case with R16B03 and
            %% R16B03-1.
            %%
            %% In this case, we compare the release versions
            %% alphabetically.
            ok;
        _ -> {error, {erlang_version_too_old,
                      {found, OTPRel, ERTSVer},
                      {required, ?OTP_MINIMUM, ?ERTS_MINIMUM}}}
    end.

print_banner() ->
    {ok, Product} = application:get_key(id),
    {ok, Version} = application:get_key(vsn),
    io:format("~n              ~s ~s. ~s"
              "~n  ##  ##      ~s"
              "~n  ##  ##"
              "~n  ##########  Logs: ~s"
              "~n  ######  ##        ~s"
              "~n  ##########"
              "~n              Starting broker...",
              [Product, Version, ?COPYRIGHT_MESSAGE, ?INFORMATION_MESSAGE,
               log_location(kernel), log_location(sasl)]).

log_banner() ->
    Settings = [{"node",           node()},
                {"home dir",       home_dir()},
                {"config file(s)", config_files()},
                {"cookie hash",    rabbit_nodes:cookie_hash()},
                {"log",            log_location(kernel)},
                {"sasl log",       log_location(sasl)},
                {"database dir",   rabbit_mnesia:dir()}],
    DescrLen = 1 + lists:max([length(K) || {K, _V} <- Settings]),
    Format = fun (K, V) ->
                     rabbit_misc:format(
                       "~-" ++ integer_to_list(DescrLen) ++ "s: ~s~n", [K, V])
             end,
    Banner = iolist_to_binary(
               [case S of
                    {"config file(s)" = K, []} ->
                        Format(K, "(none)");
                    {"config file(s)" = K, [V0 | Vs]} ->
                        [Format(K, V0) | [Format("", V) || V <- Vs]];
                    {K, V} ->
                        Format(K, V)
                end || S <- Settings]),
    rabbit_log:info("~s", [Banner]).

warn_if_kernel_config_dubious() ->
    case erlang:system_info(kernel_poll) of
        true  -> ok;
        false -> rabbit_log:warning(
                   "Kernel poll (epoll, kqueue, etc) is disabled. Throughput "
                   "and CPU utilization may worsen.~n")
    end,
    AsyncThreads = erlang:system_info(thread_pool_size),
    case AsyncThreads < ?ASYNC_THREADS_WARNING_THRESHOLD of
        true  -> rabbit_log:warning(
                   "Erlang VM is running with ~b I/O threads, "
                   "file I/O performance may worsen~n", [AsyncThreads]);
        false -> ok
    end,
    IDCOpts = case application:get_env(kernel, inet_default_connect_options) of
                  undefined -> [];
                  {ok, Val} -> Val
              end,
    case proplists:get_value(nodelay, IDCOpts, false) of
        false -> rabbit_log:warning("Nagle's algorithm is enabled for sockets, "
                                    "network I/O latency will be higher~n");
        true  -> ok
    end.

warn_if_disc_io_options_dubious() ->
    %% if these values are not set, it doesn't matter since
    %% rabbit_variable_queue will pick up the values defined in the
    %% IO_BATCH_SIZE and CREDIT_DISC_BOUND constants.
    CreditDiscBound = rabbit_misc:get_env(rabbit, msg_store_credit_disc_bound,
                                          undefined),
    IoBatchSize = rabbit_misc:get_env(rabbit, msg_store_io_batch_size,
                                      undefined),
    case catch validate_msg_store_io_batch_size_and_credit_disc_bound(
                 CreditDiscBound, IoBatchSize) of
        ok -> ok;
        {error, {Reason, Vars}} ->
            rabbit_log:warning(Reason, Vars)
    end.

validate_msg_store_io_batch_size_and_credit_disc_bound(CreditDiscBound,
                                                       IoBatchSize) ->
    case IoBatchSize of
        undefined ->
            ok;
        IoBatchSize when is_integer(IoBatchSize) ->
            if IoBatchSize < ?IO_BATCH_SIZE ->
                    throw({error,
                     {"io_batch_size of ~b lower than recommended value ~b, "
                      "paging performance may worsen~n",
                      [IoBatchSize, ?IO_BATCH_SIZE]}});
               true ->
                    ok
            end;
        IoBatchSize ->
            throw({error,
             {"io_batch_size should be an integer, but ~b given",
              [IoBatchSize]}})
    end,

    %% CreditDiscBound = {InitialCredit, MoreCreditAfter}
    {RIC, RMCA} = ?CREDIT_DISC_BOUND,
    case CreditDiscBound of
        undefined ->
            ok;
        {IC, MCA} when is_integer(IC), is_integer(MCA) ->
            if IC < RIC; MCA < RMCA ->
                    throw({error,
                     {"msg_store_credit_disc_bound {~b, ~b} lower than"
                      "recommended value {~b, ~b},"
                      " paging performance may worsen~n",
                      [IC, MCA, RIC, RMCA]}});
               true ->
                    ok
            end;
        {IC, MCA} ->
            throw({error,
             {"both msg_store_credit_disc_bound values should be integers, but ~p given",
              [{IC, MCA}]}});
        CreditDiscBound ->
            throw({error,
             {"invalid msg_store_credit_disc_bound value given: ~p",
              [CreditDiscBound]}})
    end,

    case {CreditDiscBound, IoBatchSize} of
        {undefined, undefined} ->
            ok;
        {_CDB, undefined} ->
            ok;
        {undefined, _IBS} ->
            ok;
        {{InitialCredit, _MCA}, IoBatchSize} ->
            if IoBatchSize < InitialCredit ->
                    throw(
                      {error,
                       {"msg_store_io_batch_size ~b should be bigger than the initial "
                        "credit value from msg_store_credit_disc_bound ~b,"
                        " paging performance may worsen~n",
                        [IoBatchSize, InitialCredit]}});
               true ->
                    ok
            end
    end.

home_dir() ->
    case init:get_argument(home) of
        {ok, [[Home]]} -> Home;
        Other          -> Other
    end.

config_files() ->
    Abs = fun (F) ->
                  filename:absname(filename:rootname(F, ".config") ++ ".config")
          end,
    case init:get_argument(config) of
        {ok, Files} -> [Abs(File) || [File] <- Files];
        error       -> case config_setting() of
                           none -> [];
                           File -> [Abs(File) ++ " (not found)"]
                       end
    end.

%% This is a pain. We want to know where the config file is. But we
%% can't specify it on the command line if it is missing or the VM
%% will fail to start, so we need to find it by some mechanism other
%% than init:get_arguments/0. We can look at the environment variable
%% which is responsible for setting it... but that doesn't work for a
%% Windows service since the variable can change and the service not
%% be reinstalled, so in that case we add a magic application env.
config_setting() ->
    case application:get_env(rabbit, windows_service_config) of
        {ok, File1} -> File1;
        undefined   -> case os:getenv("RABBITMQ_CONFIG_FILE") of
                           false -> none;
                           File2 -> File2
                       end
    end.

%% We don't want this in fhc since it references rabbit stuff. And we can't put
%% this in the bootstep directly.
start_fhc() ->
    ok = rabbit_sup:start_restartable_child(
      file_handle_cache,
      [fun rabbit_alarm:set_alarm/1, fun rabbit_alarm:clear_alarm/1]),
    ensure_working_fhc().

ensure_working_fhc() ->
    %% To test the file handle cache, we simply read a file we know it
    %% exists (Erlang kernel's .app file).
    %%
    %% To avoid any pollution of the application process' dictionary by
    %% file_handle_cache, we spawn a separate process.
    Parent = self(),
    TestFun = fun() ->
        ReadBuf = case application:get_env(rabbit, fhc_read_buffering) of
            {ok, true}  -> "ON";
            {ok, false} -> "OFF"
        end,
        WriteBuf = case application:get_env(rabbit, fhc_write_buffering) of
            {ok, true}  -> "ON";
            {ok, false} -> "OFF"
        end,
        rabbit_log:info(
          "FHC read buffering:  ~s~n"
          "FHC write buffering: ~s~n", [ReadBuf, WriteBuf]),
        Filename = filename:join(code:lib_dir(kernel, ebin), "kernel.app"),
        {ok, Fd} = file_handle_cache:open(Filename, [raw, binary, read], []),
        {ok, _} = file_handle_cache:read(Fd, 1),
        ok = file_handle_cache:close(Fd),
        Parent ! fhc_ok
    end,
    TestPid = spawn_link(TestFun),
    %% Because we are waiting for the test fun, abuse the
    %% 'mnesia_table_loading_timeout' parameter to find a sane timeout
    %% value.
    Timeout = rabbit_table:wait_timeout(),
    receive
        fhc_ok                       -> ok;
        {'EXIT', TestPid, Exception} -> throw({ensure_working_fhc, Exception})
    after Timeout ->
            throw({ensure_working_fhc, {timeout, TestPid}})
    end.
