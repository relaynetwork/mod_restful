-module(mod_restful_debug).
-author('Paul, The Heart').
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% -export([start/0, checkout/2, lookup/1, return/1]).
-export([start/0, save/2, lookup/1]).

% These are all wrappers for calls to the server
start() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

save(Name, Value) -> gen_server:call(?MODULE, {save, Name, Value}).	
lookup(Name) -> gen_server:call(?MODULE, {lookup, Name}).

% This is called when a connection is made to the server
init([]) ->
	Library = dict:new(),
	{ok, Library}.

% handle_call is invoked in response to gen_server:call
handle_call({save, Name, Value}, _From, Library) ->
  NewLibrary = dict:store(Name, Value, Library),
  {reply, ok, NewLibrary};

handle_call({lookup, Name}, _From, Library) ->
	Response = case dict:is_key(Name, Library) of
		true ->
      {ok, dict:fetch(Name, Library)};
		false ->
			{not_found, Name}
	end,
	{reply, Response, Library}.

% We get compile warnings from gen_server unless we define these
handle_cast(_Message, Library) -> {noreply, Library}.
handle_info(_Message, Library) -> {noreply, Library}.
terminate(_Reason, _Library) -> ok.
code_change(_OldVersion, Library, _Extra) -> {ok, Library}.
