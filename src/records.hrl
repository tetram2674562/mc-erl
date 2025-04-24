
% ======================================================================
% entities
% ======================================================================

%% used for (RAM) entity table
%% eid: [key]
%% name: only used for players [index]
%% type: player|mob|drop|falling_block
%% item_id: hold item for players/mobs, Slot = {ItemId, Count, Metadata} for drops
-record(entity, {eid, name, type, logic, location, item_id = empty}).

%% used for persistent player table and within player_logic
-record(player, {eid, name, location={0,0,0,0,0},inventory=array:new(45, {default, empty}), selected_slot=0,mode=survival, fly_speed=12, walk_speed=25, can_fly=true}).

-record(estate, {next_eid=0}).

-record(itemstate, {entity, velocity={0,0,0}, moving=false, last_tick}).

-record(state, {writer, player, mode=creative, chunks=none, cursor_item=empty,logged_in=false, known_entities=dict:new(), last_tick,pos={0.5, 70, 0.5, 0, 0}}).
% ======================================================================
% blocks/chunks
% ======================================================================

-record(block_type, {id, name, maxstack=64, placeable=false}).

-record(chunk_column_data, {full_column, chunks=[], add_data=[], biome}).
-record(chunk_data, {types, metadata, block_light, sky_light}).

-record(slot, {id, count=1, metadata=0, enchantments=[]}).

% ======================================================================
% Server state
% ======================================================================


-record(server_state, {listen, public_key, private_key}).