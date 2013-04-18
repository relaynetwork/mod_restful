%%%----------------------------------------------------------------------
%%% File    : mod_restful_admin.erl
%%% Author  : Jonas Ådahl <jadahl@gmail.com>
%%% Purpose : Provides admin interface via mod_restful
%%% Created : 11 Nov 2010 by Jonas Ådahl <jadahl@gmail.com>
%%%
%%%
%%% Copyright (C) 2010   Jonas Ådahl
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------
%%%
%%% API
%%%
%%% To run a command, using admin@localhost:secret as basic authentication:
%%%   POST /api/admin HTTP/1.1
%%%   Host: example.net
%%%   Authorization: Basic YWRtaW5AbG9jYWxob3N0OnNlY3JldAo==
%%%   Content-Type: application/json
%%%   Content-Length: 63
%%%
%%%   {"command":"register","args":["test","example.net","secret"]}
%%%
%%% To run a command, using a shared secret key:
%%%   POST /api/admin HTTP/1.1
%%%   Host: example.net
%%%   Content-Type: application/json
%%%   Content-Length: 78
%%%
%%%   {"key":"secret","command":"register","args":["test","example.net","secret"]}
%%%
%%% Using a shared secret key, one need to configure mod_restful_admin as follows:
%%%   {mod_restful, [
%%%                  {api, [
%%%                         {["admin"], mod_restful_admin, [{key, "secret"}, {allowed_commands, [register]}]}
%%%                        ]}
%%%                 ]}
%%%
%%% Leaving out {key, "secret"} an admin credentials has to be specified using
%%% HTTP Basic Auth.
%%%


-module(mod_restful_admin).
-author('jadahl@gmail.com').

-export([process_rest/1, 
    get_room_occupants/1, 
    get_room_state/1, 
    get_room_messages/1, 
    post_message_to_room/4,
    handle_post_message_to_room/2]).

-behaviour(gen_restful_api).

-include("ejabberd.hrl").

-include("mod_muc/mod_muc_room.hrl").
-include("include/mod_restful.hrl").

process_rest(#rest_req{http_request = #request{method = 'POST'}, path = Path} = Req) ->
    case tl(Path) of
        [] ->
            case authorized(Req) of
                allow ->
                    do_process(Req);
                deny ->
                    {error, not_allowed}
            end;
        ["room", RoomName, "message"] ->
          {simple, handle_post_message_to_room(RoomName, Req)};
          % {simple, io_lib:format("This is where we'd post a message to the Room: ~p: Path=~p~n", [RoomName, Path])};
        _ ->
          {simple, io_lib:format("[POST] Not Found: Path=~p~n",[Path])}
          %{error, not_found}
    end;
process_rest(#rest_req{http_request = #request{method = 'GET'}, path = Path} = _Req) ->
    case Path of
        [] ->
          {simple, io_lib:format("A Response, no path: ~p~n", [Path])};
        [_] ->
          {simple, io_lib:format("A Response, with 1 path elt: ~p~n", [Path])};
        [_, "room", RoomName, "occupants"] ->
          {ok, #rest_resp{ format = json, output = iolist_to_binary(mod_restful_mochijson2:encode([list_to_binary(X) || X <- get_room_occupants(RoomName)]))}};
        [_, "room", RoomName, "messages"] ->
          {ok, #rest_resp{ format = json, output = iolist_to_binary(mod_restful_mochijson2:encode(get_room_messages(RoomName)))}};
        _ ->
          {simple, io_lib:format("Fell through: A Response: ~p~n", [Path])}
    end;

process_rest(_) ->
    {error, not_found}.

gen_msg_id(Prefix) ->
  {MegaSec, Secs, MicroSecs} = now(),
  Timestamp = MegaSec * 1000000 * 1000000 + Secs * 1000000 + MicroSecs,
  lists:flatten(io_lib:format("~p~p", [Prefix, Timestamp])).

post_message_to_room(RoomName, FromUserName, FriendlyFrom, Body) ->
  ?INFO_MSG("handle_post_message_to_room/posting: RoomName=~p From=~p Body=~p~n", [RoomName, FromUserName, Body]),
  From1 = string:concat(RoomName, "@conference.localhost"),
  From2 = string:concat(From1, "/"),
  From  = string:concat(From2, binary_to_list(FromUserName)),
  case get_room_state(RoomName) of
    {ok, StateData} ->
      ?INFO_MSG("post_message_to_room: got state data for room=~p~n", [RoomName]),
      JabberFrom = {jid, 
                    From,
                    "localhost",
                    "the resource",
                    From,
                    "localhost",
                    "the resource"},
	    {FromNick1, _Role} = get_participant_data(JabberFrom, StateData),
      FromNick = if length(FromNick1) == 0 -> binary_to_list(FromUserName); true -> FromNick1 end,
      ?INFO_MSG("post_message_to_room: got participant data FromNick=~p Role=~p~n", [FromNick, _Role]),
      To1 = string:concat(binary_to_list(FromUserName), "@conference.localhost"),
      To2 = string:concat(To1, "/"),
      To  = string:concat(To2, gen_msg_id('res')),
      ?INFO_MSG("To: ~p", [To]),
      MessageId = gen_msg_id('system'),
      Packet = {xmlelement,"message",
                     [{"type","groupchat"},
                      {"id",MessageId},
                      {"friendly_from",FriendlyFrom},
                      {"chatmessageid",gen_msg_id('cmid')},
                      {"to",To}],
                    [{xmlelement,"body",[],[{xmlcdata,Body}]}]},
      ?INFO_MSG("post_message_to_room: foreaching, MessageId=~p~n", [MessageId]),
      lists:foreach(  fun({_LJID, Info}) ->
            ejabberd_router:route(
              jlib:jid_replace_resource( StateData#state.jid, FromNick),
              Info#user.jid,
              Packet)
        end,
        ?DICT:to_list(StateData#state.users)),

      gen_fsm:send_all_state_event(get_room_pid(RoomName), {add_message_to_history, FromNick, From, Packet}),

      ?INFO_MSG("post_message_to_room: after foreach~n", []),
      io_lib:format("Posted Message[id=~p] to Room[~p].", [MessageId, RoomName]);
    _ ->
      io_lib:format("Room[~p] Not Found.", [RoomName])
  end.



handle_post_message_to_room(RoomName, #rest_req{format = json, data = Data}) -> 
  {struct, Props} = Data, %mod_restful_mochijson2:decode(Data),
  %% NB: should harden these so they can detect missing Body/From and report that back sensibly
  [{_, Body}]         = lists:filter(fun ({Key,_Val}) -> Key == <<"body">> end, Props),
  [{_, From}]         = lists:filter(fun ({Key,_Val}) -> Key == <<"from">> end, Props),
  [{_, FriendlyFrom}] = lists:filter(fun ({Key,_Val}) -> Key == <<"friendly_from">> end, Props),
  post_message_to_room(RoomName, From, FriendlyFrom, Body);

handle_post_message_to_room(RoomName, Req) ->
  io_lib:format("handle_post_message_to_room/unahndled: RoomName=~p Req=~p~n", [RoomName, Req]).

get_room_pid(RoomName) ->
  case mnesia:dirty_read(muc_online_room,{RoomName,"conference.localhost"}) of
    [{_, _, Pid}] ->
      Pid;
      _ ->
        notfound
    end.

get_room_state(RoomName) ->
  case get_room_pid(RoomName) of
    Pid -> 
      case gen_fsm:sync_send_all_state_event(Pid, get_state) of
        {ok, R} ->
          {ok, R};
        _ ->
          {error, "Unable to get room state."}
      end;
    _ ->
      notfound
  end.

get_room_occupants(RoomName) ->
  case get_room_state(RoomName) of
      {ok, State} ->
        dict:fold(fun (_Key, Value, Acc) ->
              {jid, UserName, _Server, _Resource, _, _, _} = Value#user.jid,
              [UserName|Acc]
          end,
          [],
          State#state.users);
      _ ->
        []
    end.

get_body_from_xmlelement([]) ->
  notfound;
get_body_from_xmlelement([H|T]) ->
  case get_body_from_xmlelement(H) of
      notfound ->
        get_body_from_xmlelement(T);
      Body ->
        Body
    end;
get_body_from_xmlelement({xmlelement, "body", _Attributes, [{xmlcdata, Body}]}) ->
  Body;
get_body_from_xmlelement({xmlelement, _, _Attributes, Children}) ->
  get_body_from_xmlelement(Children);
get_body_from_xmlelement(_) ->
  notfound.

get_room_messages(RoomName) ->
  case get_room_state(RoomName) of
      {ok, State} ->
        History = queue:to_list(State#state.history#lqueue.queue),
        lists:map( 
          fun ({From, Content, _, _Timestamp, _}) -> 
              Body = get_body_from_xmlelement(Content),
              [{from, list_to_binary(From)}, {body, Body}]
          end, 
          History);
      _ ->
        []
    end.

do_process(Request) ->
    case parse_request(Request) of
        {command, Command, Args} ->
            case command_allowed(Command, Request) of
                allow ->
                    case run_command(Command, Args, Request) of
                        {error, Reason} ->
                            {error, Reason};
                        Result ->
                            Result
                    end;
                deny ->
                    {error, not_allowed}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_request(#rest_req{format = json, data = Data}) ->
    parse_json(Data).

parse_json({struct, Struct}) ->
    case lists:foldl(fun(El, In) ->
                         case In of
                             {Command, Args} ->
                                 case El of
                                     {<<"command">>, NewCommand} ->
                                         {NewCommand, Args};
                                     {<<"args">>, NewArgs} ->
                                         {Command, NewArgs};
                                     _ ->
                                         {Command, Args}
                                 end;
                             _ ->
                                 undefined
                         end
                     end, {undefined, undefined}, Struct) of
        {CMD, ARGV} when is_binary(CMD) and is_list(ARGV) ->
            {command,
                list_to_atom(binary_to_list(CMD)),
                [binary_to_list(ARG) || ARG <- ARGV]};
        _ ->
            {error, bad_request}
    end;
parse_json(_) ->
    {error, bad_request}.

command_allowed(Command, #rest_req{options = Options}) ->
    case gen_restful_api:opts(allowed_commands, Options) of
        undefined ->
            deny;
        AllowedCommands ->
            case lists:member(Command, AllowedCommands) of
                true -> allow;
                _ -> deny
            end
    end.

authorized(Request) ->
    case gen_restful_api:authorize_key_request(Request) of
        {error, no_key_configured} ->
            gen_restful_api:authenticate_admin_request(Request);
        deny ->
            deny;
        allow ->
            allow
    end.

run_command(Command, Args, Req) ->
    case ejabberd_commands:get_command_format(Command) of
        {error, _E} ->
            {error, bad_request};
        {ArgsF, ResF} ->
            case format_args(ArgsF, Args) of
                {error, Reason} ->
                    {error, Reason};
                ArgsFormatted ->
                    case ejabberd_commands:execute_command(Command, ArgsFormatted) of
                        {error, _Error} ->
                            {error, bad_request};
                        Result ->
                            format_result(ResF, Result, Req)
                    end
            end
    end.

format_args(ArgsF, Args) ->
    case catch [format_arg(ArgF, Arg) || {ArgF, Arg} <- lists:zip(ArgsF, Args)] of
        {'EXIT', _} ->
            {error, bad_request};
        ArgsFormatted ->
            ArgsFormatted
    end.

format_arg({_, integer}, Arg) ->
    list_to_integer(Arg);
format_arg({_, string}, Arg) ->
    Arg.

format_result(ResF, Res, #rest_req{format = json}) ->
    {ok, #rest_resp{format = json, output = format_result_json(Res, ResF)}};
format_result(_ResF, _Res, #rest_req{format = xml}) ->
    % FIXME not implemented
    {error, bad_request}.

format_result_json({error, ErrorAtom}, _) ->
    [{error, ErrorAtom}];
format_result_json(Atom, {_, atom}) ->
    Atom;
format_result_json(Int, {_, integer}) ->
    integer_to_list(Int);
format_result_json(String, {_, string}) ->
    list_to_binary(String);
format_result_json(Code, {_, rescode}) ->
    Code;
format_result_json({Code, Text}, {_, restuple}) ->
    [{Code, list_to_binary(Text)}];
format_result_json([E], {_, {list, ElementsF}}) ->
    [format_result_json(E, ElementsF)];
format_result_json([E|T], {X, {list, ElementsF}}) ->
    [format_result_json(E, ElementsF) | format_result_json(T, {X, {list, ElementsF}}) ];
format_result_json(Tuple, {_, {tuple, ElementsF}}) ->
    TupleL = tuple_to_list(Tuple),
    % format a tuple as a list
    [format_result_json(E, F) || {E, F} <- lists:zip(TupleL, ElementsF)].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% copied from:  ejabberd-2.1.11/src/mod_muc/mod_muc_room.erl:980
get_participant_data(From, StateData) ->
    case ?DICT:find(jlib:jid_tolower(From), StateData#state.users) of
	{ok, #user{nick = FromNick, role = Role}} ->
	    {FromNick, Role};
	error ->
	    {"", moderator}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
