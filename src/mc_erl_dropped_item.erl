%% @copyright 2012 Gregory Fefelov, Feiko Nanninga

-module(mc_erl_dropped_item).

-export([new/2, spawn/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


-include("records.hrl").

-define(pick_up_range, 1).       % unit: m
-define(gravity_acc, -0.0245).    % unit: m/tick^2
-define(life_length, 300).      % unit: seconds


floor(X) when X < 0 ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T - 1
    end;
floor(X) ->
    trunc(X).

spawn({X, Y, Z}, {_VX, _VY, _VZ}=InitialVelocity, {_ItemId, _Count, _Metadata}=Data) ->
    new(#entity{type=dropped_item, location={X,Y,Z,0,0}, item_id=Data}, InitialVelocity).

new(Entity, Velocity) when is_record(Entity, entity), Entity#entity.type =:= dropped_item ->
    {ok, Pid} = gen_server:start(?MODULE, {Entity, Velocity}, []),
    Pid.

init({Entity, Velocity}) ->
    process_flag(trap_exit, true),
    erlang:send_after(?life_length * 1000, self(), suicide),
    {ok, #itemstate{entity=mc_erl_entity_manager:register_dropped_item(Entity, Velocity), velocity=Velocity, moving=true}}.

terminate(_Reason, State) ->
    mc_erl_entity_manager:delete_entity(State#itemstate.entity),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(suicide, State) ->
    {stop, normal, State};

handle_info(Info, State) ->
    lager:notice("[~s] got unknown info: ~p~n", [?MODULE, Info]),
    {noreply, State}.

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Req, _From, State) ->
    lager:notice("[~s] got unknown call: ~p~n", [?MODULE, Req]),
    {noreply, State}.

handle_cast(Req, State) ->
    MyEntity = State#itemstate.entity,
    MyEid = MyEntity#entity.eid,
    RetState = case Req of
                   {tick, Tick} ->
                       NewState = case State#itemstate.moving of
                                      true ->
                                          {VX, VY, VZ} = State#itemstate.velocity,
                                          {X, Y, Z, _, _} = MyEntity#entity.location,

                                          NVY = VY + ?gravity_acc,

                                          {PX, PY, PZ} = {X+VX, Y+NVY, Z+VZ},
                                          ProposedBlock = {floor(PX), floor(PY), floor(PZ)},
                                          case mc_erl_chunk_manager:get_block(ProposedBlock) of
                                              {0, _} ->
                                                  NewLocation = {PX, PY, PZ, 0, 0},
                                                  NewVelocity = {VX, NVY, VZ},
                                                  IsMoving = true;
                                              _ ->
                                                  NewLocation = {X, Y, Z, 0, 0},
                                                  NewVelocity = {0, 0, 0},
                                                  IsMoving = false
                                          end,

                                          mc_erl_entity_manager:move_entity(MyEid, NewLocation),
                                          State#itemstate{entity=MyEntity#entity{location=NewLocation}, velocity=NewVelocity, moving=IsMoving, last_tick=Tick};

                                      false ->
                                          State
                                  end,
                       UpdatedLocation = NewState#itemstate.entity#entity.location,
                       if
                           (Tick rem 20) == 0 -> mc_erl_entity_manager:move_entity(MyEid, UpdatedLocation);
                           true -> ok
                       end,
                       NewState;

                   % don't use these for movement simulation, register for events at chunk_manager
                   {block_delta, _} -> State;
                   {update_column, _} -> State;

                   % adds or removes a player on the player list
                   {player_list, _Player, _Mode} -> State;

                   % === entity messages ===
                   {new_entity, Entity} ->
                       pick_up_check(Entity, State);

                   {delete_entity, Eid} ->
                       case MyEid =:= Eid of
                           true -> {stop, normal, entity_deleted};
                           false -> State
                       end;

                   {update_entity_position, {Entity}} when is_record(Entity, entity) ->
                       pick_up_check(Entity, State);

                   _UnknownMessage ->
                       State
               end,
    case RetState of
        % ...

        % right path
        Res -> {noreply, Res}
    end.

pick_up_check(Entity, State) when Entity#entity.type =:= player ->
    case in_range(Entity#entity.location, State) of
        true -> lager:notice("~p: player in range!~n", [State#itemstate.entity#entity.eid]);
        false -> ok
    end,
    State;
pick_up_check(_, State) -> State.

% ==== Checks if (a player's) location is in pick up range
in_range({X, Y, Z, _, _}, State) ->
    {MyX, MyY, MyZ, _, _} = State#itemstate.entity#entity.location,
    math:sqrt(math:pow(MyX-X,2) + math:pow(MyY-Y,2) + math:pow(MyZ-Z,2)) < ?pick_up_range.


