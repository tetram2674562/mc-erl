%% @copyright 2025 tetram26 aka tetram2674562 aka gaspardAlizand


-module(mc_erl_command_handler).

-include("records.hrl").

-export([execute_command/2]).

execute_command(State,FullCommand) ->
    Args = parse_args(FullCommand),
    Command = parse_command(FullCommand),
    
    New_State = case Command of 
        Command when Command == "gamemode" ->
            %lager:notice("Default State : ~p~n",[State]),
            %lager:notice("Command : ~p Args : ~p~n",[Command,Args]),
            if length(Args) == 1 -> 
                    %lager:notice("Gamemode : ~p~n",[Args]),
                    case hd(Args) of
                        "survival" -> 
                            NewPMode = State#state.player#player{mode=survival},
                            mc_erl_player_core:write(State#state.writer, {new_invalid_state,[3,0]}),
                            State#state{player=NewPMode};
                        "creative" -> 
                            NewPMode = State#state.player#player{mode=creative},
                            mc_erl_player_core:write(State#state.writer, {new_invalid_state,[3,1]}),
                            State#state{player=NewPMode};
                       _ ->  mc_erl_chat:to_player(self(),"Invalid gamemode : Please enter a correct one ! "),
                       State
                    end;
                true -> mc_erl_chat:to_player(self(),"Invalid usage : '/gamemode <gamemode>'"),
                State
            end;

        Command when Command == "tp" ->
            if length(Args) == 1 -> 
                lager:notice("Teleporting ~p to ~p~n",[State#state.player#player.name,hd(Args)]);
            true -> mc_erl_chat:to_player(self(),"Unknown command : " ++ Command)
            end,
            State;

        _ -> 
            mc_erl_chat:to_player(self(),"Unknown command : " ++ Command),
            State
    end,
    %lager:notice("New State ~p~n",[New_State]),
    New_State.



% Return args and the given command string (format : command arg1 arg2 arg3 etc.)
parse_args(CommandArgs) -> 
    Args = string:split(CommandArgs," "),
    if length(Args) > 1 -> tl(Args);
        true -> [] 
    end.
    
parse_command(CommandArgs) -> 
    hd(string:split(CommandArgs," ")).


    
    