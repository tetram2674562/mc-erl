%% @copyright 2012-2013 Gregory Fefelov, Feiko Nanninga

-module(mc_erl_player_logic).
% only pure erlang, only pure hardcore
-export([start_logic/2, packet/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).



-record(ke_metadata, {relocations=0}).

-include("records.hrl").

start_logic(Writer, Name) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [Writer, Name], []),
    Pid.

packet(Logic, Packet) ->
    gen_server:cast(Logic, Packet).

init([Writer, Name]) ->
    process_flag(trap_exit, true),
    {ok, #state{writer=Writer, player=#player{name=Name}}}.

terminate(_Reason, State) when is_record(State, state) ->
    State#state.writer ! stop,
    case State#state.logged_in of
        true ->
            mc_erl_chat:broadcast(State#state.player#player.name
                                  ++ " has left the server."),
            mc_erl_entity_manager:delete_player(State#state.player);
        false -> ok
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(Info, State) ->
    lager:notice("[~s] got unknown info: ~p~n", [?MODULE, Info]),
    {noreply, State}.

handle_call(Req, _From, State) ->
    lager:notice("[~s] got unknown packet: ~p~n", [?MODULE, Req]),
    {noreply, State}.

handle_cast(Req, State) ->
    Writer = State#state.writer,
    MyPlayer = State#state.player,
    MyEid = MyPlayer#player.eid,
    RetState = case Req of
                   % protocol reactions begin
                   login_sequence ->
                       IsValid = mc_erl_chat:is_valid_nickname(State#state.player#player.name),
                       case IsValid of
                           true ->	
                               case mc_erl_entity_manager:register_player(State#state.player) of
                                   {error, name_in_use} ->
                                       lager:warning("[~s] Someone with the same name is already logged in, kicked~n", [?MODULE]),
                                       write(Writer, {disconnect, ["Someone with the same name is already logged in :("]}),
                                       {disconnect, {multiple_login, State#state.player#player.name}, State};

                                   NewPlayer ->
                                       Mode = case NewPlayer#player.mode of
                                                  creative -> 1;
                                                  survival -> 0
                                              end,
                                       receive after 2000 -> ok end,
                                       write(Writer, {login_request, [NewPlayer#player.eid, "DEFAULT", Mode, 0, 0, 0, 100]}),

                                       send_player_abilities(State),
                                       mc_erl_inventory:send_inventory(Writer, NewPlayer#player.inventory),
                                       write(Writer, {spawn_position, [0, 0, 0]}),
                                       {X, Y, Z, Yaw, Pitch} = StartPos = State#state.pos,

                                       Chunks = check_chunks(Writer, {X, Y, Z}),

                                       send_player_list(State),							
                                       write(Writer, {player_position_look, [X,Y+1.62,Y,Z,Yaw,Pitch,1]}),

                                       mc_erl_entity_manager:move_entity(NewPlayer#player.eid, StartPos),

                                       mc_erl_chat:broadcast(NewPlayer#player.name ++ " has joined."),
                                       mc_erl_chat:to_player(self(), mc_erl_config:get(motd, "")),

                                       %proc_lib:spawn_link(fun() -> process_flag(trap_exit, true), mc_erl_player_core:keep_alive_sender(Writer) end),

                                       State#state{player=NewPlayer, chunks=Chunks, logged_in=true}
                               end;
                           false ->
                               lager:warning("[~s] Someone with the wrong nickname has tried to log in, kicked~n", [?MODULE]),
                               write(Writer, {disconnect, ["Invalid username :("]}),
                               {disconnect, {invalid_username, MyPlayer#player.name}, State}
                       end;

                   {packet, {keep_alive, [_]}} ->
                       State;

                   {packet, {locale_view_distance,[_,_,_,_]}} ->
                       State;

                   {packet, {player, _OnGround}} ->
                       State;

                   {packet, {player_position, [X, Y, _Stance, Z, _OnGround]}} ->
                       {_OldX, _OldY, _OldZ, Yaw, Pitch} = State#state.pos,
                       NewPos = {X, Y, Z, Yaw, Pitch},
                       mc_erl_entity_manager:move_entity(MyEid, NewPos),

                       NewState = State#state{chunks=check_chunks(Writer, {X, Y, Z}, State#state.chunks), pos=NewPos},
                       NewState;

                   {packet, {player_look, [Yaw, Pitch, _OnGround]}} ->
                       {X, Y, Z, _OldYaw, _OldPitch} = State#state.pos,
                       NewPos = {X, Y, Z, Yaw, Pitch},
                       mc_erl_entity_manager:move_entity(MyEid, NewPos),
                       State#state{pos=NewPos};

                   {packet, {player_position_look, [X, Y, _Stance, Z, Yaw, Pitch, _OnGround]}} ->
                       NewPos = {X, Y, Z, Yaw, Pitch},
                       mc_erl_entity_manager:move_entity(MyEid, NewPos),
                       State#state{chunks=check_chunks(State#state.writer, {X, Y, Z}, State#state.chunks), pos=NewPos};

                   {packet, net_disconnect} ->
                       {disconnect, {graceful, "Lost connection"}, State};

                   {packet, {disconnect, [Message]}} ->
                       {disconnect, {graceful, Message}, State};

                   {packet, {holding_change, [N]}} when N >= 0, N =< 8 ->
                       NewPlayer = MyPlayer#player{selected_slot=N},
                       State#state{player=NewPlayer};

                   % started digging
                   {packet, {player_digging, [0, X, Y, Z, _]}} ->
                       case MyPlayer#player.mode of
                           creative -> mc_erl_chunk_manager:set_block({X, Y, Z}, {0, 0});
                           survival -> void
                       end,
                       State;

                   % cancelled digging
                   {packet, {player_digging, [1, _X, _Y, _Z, _]}} ->
                       State;

                   % finished digging
                   {packet, {player_digging, [2, X, Y, Z, _]}} ->
                       case MyPlayer#player.mode of
                           creative -> State;
                           survival ->
                               {BlockId, Metadata} = mc_erl_chunk_manager:get_block({X, Y, Z}),
                               %mc_erl_dropped_item:spawn({X, Y, Z}, {0.1, 0, 0}, {BlockId, 1, Metadata}),
                               mc_erl_chunk_manager:set_block({X, Y, Z}, {0, 0}),
                               {NewInv, _Rest} = mc_erl_inventory:inventory_add(Writer, MyPlayer#player.inventory, #slot{id=BlockId, count=1, metadata=Metadata}),
                               State#state{player=State#state.player#player{inventory=NewInv}}
                       end;

                   {packet, {player_block_placement, [-1, 255, -1, -1, #slot{}, _, _, _]}} ->
                       % handle right click when no block selected
                       % handle held item state update (eating food etc.) TODO: recheck this
                       State;

                   {packet, {player_block_placement, [_, _, _, _, empty, _, _, _]}} ->
                       State;

                   {packet, {player_block_placement, [X, Y, Z, Direction, _, _, _, _]}} ->
                       SelectedSlot = MyPlayer#player.selected_slot+36,
                       Inv = MyPlayer#player.inventory,
                       case array:get(SelectedSlot, Inv) of
                           empty ->
                               State;
                           #slot{id=BlockId, metadata=Metadata} ->
                               case mc_erl_chunk_manager:set_block({X, Y, Z, Direction}, {BlockId, Metadata}, State#state.pos) of
                                   ok ->
                                       NewInv = mc_erl_inventory:update_slot(Writer, State#state.player#player.inventory, SelectedSlot, reduce),
                                       State#state{player=State#state.player#player{inventory=NewInv}};
                                   {error, forbidden_block_id, {_RX, _RY, _RZ}} ->
                                       lager:warning("[~s] ~s tried to set a forbidden block (~p)~n", [?MODULE, MyPlayer#player.name, BlockId])
                               end
                       end;

                   {packet, {entity_action, [MyEid, _P]}} ->
                       % crouching, leaving bed, sprinting
                       State;

                   {packet, {chat_message, [Message]}} ->
                    
                        case Message of 
                            [FirstLetter | Cmd] when FirstLetter == 47 -> 
                                lager:notice("Issued command ~p~n",[Message]),
                                lager:notice("~p~n",[State#state.player#player.mode]),
                                New_State = mc_erl_command_handler:execute_command(State,Cmd),
                                lager:notice("~p~n",[New_State#state.player#player.mode]),
                                New_State;
                            _ ->
                                lager:notice("[~p]: ~p~n",[State#state.player#player.name,Message]),
                                mc_erl_chat:broadcast(State#state.player, Message),
                                State    
                        end;
                        
                    

                   {packet, {animation, [MyEid, AnimationId]}} ->
                       mc_erl_entity_manager:broadcast_local(MyEid, {animate, MyEid, AnimationId}),
                       State;

                   {packet, {entity_action, [MyEid, 1]}} -> % crouch
                       mc_erl_entity_manager:broadcast_local(MyEid, {entity_metadata, MyEid, [{0, {byte, 2}}]}),
                       State;

                   {packet, {entity_action, [MyEid, 2]}} -> % uncrouch
                       mc_erl_entity_manager:broadcast_local(MyEid, {entity_metadata, MyEid, [{0, {byte, 0}}]}),
                       State;

                   {packet, {entity_action, [MyEid, _N]}} ->
                       % sprinting, leaving bed
                       State;

                   {packet, {player_abilities, [_, _Flying, _, _]}} ->
                       State;

                   {packet, {window_click, [0, -999, _, _TransactionId, _, _Item]}} ->
                       State#state{cursor_item=empty};

                   {packet, {window_click, [0, SlotNo, 0, _TransactionId, false, _Item]}} -> % left click
                       SelectedSlot = mc_erl_inventory:get_slot(State#state.player#player.inventory, SlotNo),
                       CursorItem = State#state.cursor_item,
                       Equal = mc_erl_inventory:items_equal(SelectedSlot, CursorItem),
                       if
                           SelectedSlot =:= empty ->
                               NewInv = mc_erl_inventory:update_slot(Writer, State#state.player#player.inventory, SlotNo, {replace, CursorItem}),
                               State#state{cursor_item=empty, player=State#state.player#player{inventory=NewInv}};
                           Equal ->
                               {NewInv, Rest} = mc_erl_inventory:inventory_add_to_stack(Writer, MyPlayer#player.inventory, SlotNo, CursorItem),
                               State#state{player=MyPlayer#player{inventory=NewInv}, cursor_item=Rest};
                           true ->
                               NewInv = mc_erl_inventory:update_slot(Writer, State#state.player#player.inventory, SlotNo, {replace, CursorItem}),
                               State#state{cursor_item=SelectedSlot, player=State#state.player#player{inventory=NewInv}}
                       end;

                   {packet, {window_click, [0, SlotNo, 1, _TransactionId, false, _Item]}} -> % right click
                       SelectedSlot = mc_erl_inventory:get_slot(State#state.player#player.inventory, SlotNo),
                       CursorItem = State#state.cursor_item,
                       Equal = mc_erl_inventory:items_equal(SelectedSlot, CursorItem),
                       case {CursorItem, SelectedSlot, Equal} of
                           {empty, empty, _} -> State;
                           {empty, #slot{count=Count}, _} ->
                               SelectedCount = Count div 2,
                               CursorCount = Count - SelectedCount,
                               NewInv = mc_erl_inventory:update_slot(Writer, State#state.player#player.inventory, SlotNo, {replace, SelectedSlot#slot{count=SelectedCount}}),
                               State#state{cursor_item=SelectedSlot#slot{count=CursorCount}, player=State#state.player#player{inventory=NewInv}};
                           {#slot{}, #slot{}, false} ->
                               NewInv = mc_erl_inventory:update_slot(Writer, State#state.player#player.inventory, SlotNo, {replace, CursorItem}),
                               State#state{cursor_item=SelectedSlot, player=State#state.player#player{inventory=NewInv}};
                           {#slot{count=CursorCount}, empty, _} ->
                               {NewInv, empty} = mc_erl_inventory:inventory_add_to_stack(Writer, MyPlayer#player.inventory, SlotNo, CursorItem#slot{count=1}),
                               NewCursorSlot = case CursorCount of
                                                   1 -> empty;
                                                   OldCount -> CursorItem#slot{count=OldCount-1}
                                               end,
                               State#state{cursor_item=NewCursorSlot, player=State#state.player#player{inventory=NewInv}};
                           {#slot{count=CursorCount}, #slot{}, true} ->
                               case mc_erl_inventory:inventory_add_to_stack(Writer, MyPlayer#player.inventory, SlotNo, CursorItem#slot{count=1}) of
                                   {NewInv, empty} ->
                                       NewCursorSlot = case CursorCount of
                                                           1 -> empty;
                                                           OldCount -> CursorItem#slot{count=OldCount-1}
                                                       end,
                                       State#state{cursor_item=NewCursorSlot, player=State#state.player#player{inventory=NewInv}};
                                   {_, _} ->
                                       State
                               end
                       end;

                   {packet, {window_click, [0, SlotNo, _, _TransactionId, true, _Item]}} -> % shift click
                       Inv = MyPlayer#player.inventory,
                       SelectedSlot = mc_erl_inventory:get_slot(Inv, SlotNo),
                       Inv2 = mc_erl_inventory:update_slot(Writer, Inv, SlotNo, empty),
                       if
                           SlotNo >= 9, SlotNo =< 35 ->
                               case mc_erl_inventory:inventory_add(Writer, Inv2, 36, 44, SelectedSlot) of
                                   {NewInv, empty} ->
                                       State#state{player=State#state.player#player{inventory=NewInv}};
                                   {NewInv, Rest} ->
                                       io:format("rest1~n"),
                                       NewInv2 = mc_erl_inventory:update_slot(Writer, NewInv, SlotNo, Rest),
                                       State#state{player=State#state.player#player{inventory=NewInv2}}
                               end;
                           SlotNo >= 36, SlotNo =< 44 ->
                               case mc_erl_inventory:inventory_add(Writer, Inv2, 9, 35, SelectedSlot) of
                                   {NewInv, empty} ->
                                       State#state{player=State#state.player#player{inventory=NewInv}};
                                   {NewInv, Rest} ->
                                       io:format("rest2~n"),
                                       NewInv2 = mc_erl_inventory:update_slot(Writer, NewInv, SlotNo, Rest),
                                       State#state{player=State#state.player#player{inventory=NewInv2}}
                               end;
                           true ->
                               State
                       end;

                   {packet, {window_click, [_, _, _, TransactionId, _, _]}} ->
                       write(Writer, {transaction, [0, TransactionId, false]}),
                       State;

                   {packet, {close_window, [0]}} ->
                       State#state{cursor_item=empty};

                   {packet, {player_abilities, _}} ->
                       State; %% probably check for proper flying/walking change

                   {packet, UnknownPacket} ->
                       lager:notice("[~s] unhandled packet: ~p~n", [?MODULE, UnknownPacket]),
                       State;
                   % protocol reactions end

                   % chat
                   {chat, Message} ->
                       write(Writer, {chat_message, [Message]}),
                       State;

                   {animate, Eid, AnimationId} ->
                       case dict:is_key(Eid, State#state.known_entities) of
                           true -> write(Writer, {animation, [Eid, AnimationId]});
                           false -> ok
                       end,
                       State;

                   {entity_metadata, Eid, Metadata} ->
                       case dict:is_key(Eid, State#state.known_entities) of
                           true -> write(Writer, {entity_metadata, [Eid, Metadata]});
                           false -> ok
                       end,
                       State;

                   {tick, Tick} ->
                       if
                           (Tick rem 20) == 0 ->
                               write(Writer, {time_update, [Tick, Tick]});
                           true -> ok
                       end,
                       FinalState = State#state{last_tick=Tick},
                       FinalState;

                   {block_delta, {X, Y, Z, BlockId, Metadata}} ->
                       case in_range({X, Y, Z}, State) of
                           true ->
                               write(Writer, {block_change, [X, Y, Z, BlockId, Metadata]});
                           false -> ok
                       end,
                       State;

                   % just a notification, player_logic pulls column if necessary
                   % possible enhancement: when compressed columns are cached, chunk_manager can send compressed chunk (hence binaries are referenced!)
                   {update_column, {X, Z}=Coord} ->
                       case sets:is_element(Coord, State#state.chunks) of
                           false -> ok;
                           true ->
                               ChunkData = mc_erl_chunk_manager:get_chunk(Coord),
                               write(Writer, {map_chunk, [X, Z, {parsed, ChunkData}]})
                       end,
                       State;

                   % adds or removes a player on the player list
                   {player_list, Player, Mode} ->
                       write(Writer, {player_list_item, [Player#player.name,
                                                         case Mode of
                                                             new -> true;
                                                             delete -> false
                                                         end, 1]}),
                       State;

                   % === entity messages ===
                   {new_entity, Entity} ->
                       case MyEid =:= Entity#entity.eid of
                           true -> State;
                           false ->
                               NewState = spawn_new_entity(Entity, State),
                               NewState
                       end;

                   {set_entity_speed, Entity, {VX, VY, VZ}} ->
                       Eid = Entity#entity.eid,
                       AVx = trunc(VX*32000),
                       AVy = trunc(VY*32000),
                       AVz = trunc(VZ*32000),
                       write(Writer, {entity_velocity, [Eid, AVx, AVy, AVz]}),
                       State;


                   {delete_entity, Eid} ->
                       NewState = delete_entity(Eid, State),
                       NewState;

                   {update_entity_position, {Entity}} when is_record(Entity, entity) ->
                       NewState = update_entity(Entity, State),
                       NewState;

                   net_disconnect ->
                       {disconnect, net_disconnect, State};

                   {debug_exec, Fun} ->
                       Fun(State);

                   UnknownMessage ->
                       lager:notice("[~s] unknown message: ~p~n", [?MODULE, UnknownMessage]),
                       State
               end,
    case RetState of
        % graceful stops
        {disconnect, net_disconnect, DisconnectState} ->
            lager:warning("[~s] Connection lost with ~s~n", [?MODULE, DisconnectState#state.player#player.name]),
            {stop, normal, DisconnectState};

        {disconnect, {graceful, _QuitMessage}, DisconnectState} ->
            lager:info("[~s] Player ~s has quit~n", [?MODULE, DisconnectState#state.player#player.name]),
            {stop, normal, DisconnectState};

        % not graceful stops
        {disconnect, {invalid_username, AttemptedName}, DisconnectState} ->
            lager:info("[~s] Invalid username trying to log in: ~s~n", [?MODULE, AttemptedName]),
            {stop, normal, DisconnectState};

        {disconnect, {multiple_login, AttemptedName}, DisconnectState} ->
            lager:info("[~s] Multiple login: ~s~n", [?MODULE, AttemptedName]),
            {stop, normal, DisconnectState};

        {disconnect, {cheating, Reason}, DisconnectState} ->
            lager:notice("[~s] player is kicked due cheating: ~p~n", [?MODULE, Reason]),
            {stop, normal, DisconnectState};

        {disconnect, Reason, DisconnectState} -> {stop, Reason, DisconnectState};

        % right path
        Res -> {noreply, Res}
    end.

write(none, _) -> not_sent;
write(Writer, Packet) -> Writer ! {packet, Packet}.

% === entities ===
spawn_new_entity(Entity, State) when is_record(Entity, entity) ->
    Eid = Entity#entity.eid,
    {X, Y, Z, Yaw, Pitch} = Entity#entity.location,
    Writer = State#state.writer,
    case Entity#entity.type of
        player ->
            PName = Entity#entity.name,
            PHolding = Entity#entity.item_id,
            write(Writer, {named_entity_spawn,
                           [Eid, PName, X, Y, Z, trunc(Yaw*256/360), trunc(Yaw*256/360),
                            case PHolding of
                                empty -> 0;
                                N when is_integer(N) -> N
                            end, [{0, {byte, 0}}, {1, {short, 300}}, {8, {int, 0}}] ]}),
            NewKnownEntities = dict:store(Eid, {X, Y, Z, Yaw, Pitch, #ke_metadata{}}, State#state.known_entities),
            State#state{known_entities=NewKnownEntities};
        dropped_item ->
            {Item, Count, Meta} = Entity#entity.item_id,
            write(Writer, {pickup_spawn, [Eid, Item, Count, Meta, X, Y, Z, 0, 0, 0]}),
            NewKnownEntities = dict:store(Eid, {X, Y, Z, Yaw, Pitch, #ke_metadata{}}, State#state.known_entities),
            State#state{known_entities=NewKnownEntities};
        _ ->
            State
    end.

delete_entity(Eid, State) ->
    case dict:is_key(Eid, State#state.known_entities) of
        true ->	
            write(State#state.writer, {destroy_entity, [[Eid]]}),
            NewKnownEntities = dict:erase(Eid, State#state.known_entities),
            State#state{known_entities=NewKnownEntities};
        false ->
            State
    end.

% updates an entity's location
update_entity(Entity, State) when is_record(Entity, entity) ->
    Eid = Entity#entity.eid,
    {X, Y, Z, _, _} = Entity#entity.location,
    if
        Eid == State#state.player#player.eid ->
            State;
        true -> case in_range({X, Y, Z}, State) of
                    false ->
                        case dict:is_key(Eid, State#state.known_entities) of 
                            true -> delete_entity(Eid, State);
                            false -> State
                        end;
                    true ->
                        case dict:is_key(Eid, State#state.known_entities) of
                            true -> move_known_entity(Entity, State);
                            false -> spawn_new_entity(Entity, State)
                        end
                end
    end.

move_known_entity(Entity, State) when is_record(Entity, entity) ->
    Eid = Entity#entity.eid,
    {X, Y, Z, Yaw, Pitch} = Entity#entity.location,
    Writer = State#state.writer,
    {OldX, OldY, OldZ, _OldYaw, _OldPitch, KEMetadata} = dict:fetch(Eid, State#state.known_entities),
    RelativeRelocations = KEMetadata#ke_metadata.relocations,
    DX = X - OldX,
    DY = Y - OldY,
    DZ = Z - OldZ,
    DDistance = lists:max([DX, DY, DZ]),
    FracYaw = trunc(Yaw*256/360),
    FracPitch = trunc(Pitch*256/360),

    ChangePackets = if
                        (DDistance >= 4) or (RelativeRelocations >= 20) ->
                            NewKnownEntities = dict:store(Eid, {X, Y, Z, Yaw, Pitch, KEMetadata#ke_metadata{relocations=0}}, State#state.known_entities),
                            [{entity_teleport, [Eid, X, Y, Z, FracYaw, FracPitch]}];
                        true ->
                            NewKnownEntities = dict:store(Eid, {X, Y, Z, Yaw, Pitch, KEMetadata#ke_metadata{relocations=RelativeRelocations + 1}}, State#state.known_entities),
                            case Entity#entity.type of
                                player -> [{entity_look_move, [Eid, DX, DY, DZ, FracYaw, FracPitch]},
                                           {entity_head_look, [Eid, FracYaw]}];
                                dropped_item -> [{entity_teleport, [Eid, X, Y, Z, 0, 0]}]
                            end
                    end,
    lists:map(fun(Packet) -> write(Writer, Packet) end, ChangePackets),
    State#state{known_entities=NewKnownEntities}.


send_player_list(State) ->
    Writer = State#state.writer,
    Players = mc_erl_entity_manager:get_all_players(),
    lists:foreach(fun(Player) -> write(Writer, {player_list_item,
                                                [Player#entity.name, true, 1]}) end,
                  Players).

send_player_abilities(State) when is_record(State, state) ->
    Player = State#state.player,
    CanFly = case Player#player.can_fly of true -> 1; false -> 0 end,
    Creative = case Player#player.mode of survival -> 0; creative -> 1 end,
    Flags = <<0:4, 0:1, CanFly:1, 0:1, Creative:1>>,
    write(State#state.writer, {player_abilities, [Flags, Player#player.fly_speed,
                                                  Player#player.walk_speed]}).


% ==== Checks if location is in visible range
in_range({X, Y, Z}, State) ->
    ChunkPos = mc_erl_chunk_manager:coord_to_chunk({X, Y, Z}),
    sets:is_element(ChunkPos, State#state.chunks).

% ==== Chunks loading
check_chunks(Writer, PlayerChunk) ->
    check_chunks(Writer, PlayerChunk, sets:new()).

check_chunks(Writer, PlayerChunk, LoadedChunks) ->
    NeededChunks = mc_erl_chunk_manager:chunks_in_range(PlayerChunk, 7),
    unload_chunks(Writer, sets:to_list(sets:subtract(LoadedChunks, NeededChunks))),
    load_chunks(Writer, sets:to_list(sets:subtract(NeededChunks, LoadedChunks))),
    NeededChunks.

load_chunks(_Writer, []) -> ok;
load_chunks(Writer, [{X, Z}|Rest]) ->
    ChunkData = mc_erl_chunk_manager:get_chunk({X, Z}),
    write(Writer, {map_chunk, [X, Z, {parsed, ChunkData}]}),
    load_chunks(Writer, Rest).

unload_chunks(_Writer, []) -> ok;
unload_chunks(Writer, [{X, Z}|Rest]) ->
    write(Writer, {map_chunk, [X, Z, unload]}),
    unload_chunks(Writer, Rest).

