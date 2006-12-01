%%%----------------------------------------------------------------------
%%% File    : mod_archive.erl
%%% Author  : Olivier Goffart  <ogoffar@kde.org>
%%% Purpose : Message Archiving  (JEP-0136)
%%% Created : 19 Aug 2006
%%%----------------------------------------------------------------------

%% Version 0.0.1  2006-08-19
%% Version 0.0.2  2006-08-21
%% Version 0.0.3  2006-08-22
%% Version 0.0.4  2006-09-10  (RSM JEP-0059 v0.13   JEP-0136 v0.6 with RSM)


%% Options:
%%  save_default -> true | false      if messages are stored by default or not
%%  session_duration ->  time in secondes before the timeout of a session


-module(mod_archive).
-author('ogoffart@kde.org').

-vsn('0.0.4').
-behaviour(gen_mod).

-export([start/2,  stop/1,  loop/3 ,
        remove_user/2, send_packet/3, receive_packet/4,
         process_iq/3, process_local_iq/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").


-define(PROCNAME, ejabberd_mod_archive).
-define(NS_ARCHIVE,      "http://jabber.org/protocol/archive").
-define(INFINITY,  calendar:datetime_to_gregorian_seconds({{2038,1,19},{0,0,0}}) ).

-define(MYDEBUG(Format, Args), io:format("D(~p:~p:~p) : "++Format++"~n",
                                       [calendar:local_time(),?MODULE,?LINE]++Args)).


%NOTE  i was not sure what format to adopt for archive_option.    otr_list  is unused 
-record(archive_options, {us, default=unset , save_list = [] , nosave_list =[] , otr_list = [] }).
%-record(archive_options, {usj, us , jid , type , value}).
-record(archive_message, { usjs , us , jid , start , message_list=[] , subject=""}).
-record(msg , {dirrection , secs, body }).

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    Save_Default = gen_mod:get_opt(save_default, Opts, false),
    Session_Duration = gen_mod:get_opt(session_duration, Opts, 1300),
    mnesia:create_table(archive_options,[{disc_copies, [node()]},  {attributes, record_info(fields, archive_options)}]),
    mnesia:create_table(archive_message,[{disc_copies, [node()]},  {attributes, record_info(fields, archive_message)}]),
%    mnesia:add_table_index(archive_options, us),
    mnesia:add_table_index(archive_message, us),
    ejabberd_hooks:add(remove_user, Host,  ?MODULE, remove_user, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_ARCHIVE, ?MODULE, process_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_ARCHIVE, ?MODULE, process_local_iq, IQDisc),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, send_packet, 90),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, receive_packet, 90),
    catch mod_disco:register_feature(Host, ?NS_ARCHIVE ++ "#manage"),
    catch mod_disco:register_feature(Host, ?NS_ARCHIVE ++ "#save"),
    catch mod_disco:register_feature(Host, ?NS_ARCHIVE ++ "#manual"),
    register(gen_mod:get_module_proc(Host, ?PROCNAME),  spawn(?MODULE, loop, [Host, [], { Save_Default, Session_Duration }])).

stop(Host) ->
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_ARCHIVE),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_ARCHIVE),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, send_packet, 90),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, receive_packet, 90),
    catch mod_disco:unregister_feature(Host, ?NS_ARCHIVE ++ "#manage"),
    catch mod_disco:unregister_feature(Host, ?NS_ARCHIVE ++ "#save"),
    catch mod_disco:unregister_feature(Host, ?NS_ARCHIVE ++ "#manual"),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Proc ! stop,
    {wait, Proc}.


%Workarounf the fact that if the client send <iq type='get'>  it end up like <iq type='get' from='u@h' to = 'u@h'>
process_iq(From, To, IQ) ->
    #iq{sub_el = SubEl} = IQ,
    #jid{lserver = LServer, luser = LUser} = To,
    #jid{luser = FromUser} = From,
    case {LUser , LServer , lists:member(LServer, ?MYHOSTS)} of
    { FromUser , _ , true } ->
        process_local_iq(From, To, IQ);
    { "" , _ , true } ->
        process_local_iq(From, To, IQ);
    { "" , "" , _ } ->
        process_local_iq(From, To, IQ);
    _ ->
        IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
    end.

process_local_iq(From, To, #iq{sub_el = SubEl} = IQ) ->
    case lists:member(From#jid.lserver, ?MYHOSTS) of
    false ->
        IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
    true ->
        {xmlelement, Name, _Attrs, _Els} = SubEl,
        case Name of
            "save" -> process_local_iq_save( From, To , IQ ) ;
%           "otr" -> process_local_iq_otr( From, To , IQ ) ;
            "list" -> process_local_iq_list( From , To , IQ ) ;
            "retrieve" -> process_local_iq_retrieve( From , To , IQ );
            "store" -> process_local_iq_store( From , To , IQ );
            "remove" -> process_local_iq_remove( From , To , IQ );
            _ -> IQ#iq{type = error, sub_el = [SubEl, ?ERR_FEATURE_NOT_IMPLEMENTED]}
            end
    end.
    
    
remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    US = {LUser, LServer},
    F = fun() ->
        lists:foreach(fun(R) ->
                    mnesia:delete_object(R)
                end,
                mnesia:index_read(archive_message, US, #archive_message.us))
        end,
    mnesia:transaction(F),
    F1 = fun() ->
            mnesia:delete({archive_options, US})
        end,
    mnesia:transaction(F1).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  3 Automated archiving
%%

send_packet(From, To, P) ->
    Host = From#jid.lserver,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Proc ! {addlog, {to, From#jid.luser, Host , To, P}}.

receive_packet(_JID, From, To, P) -> 
    Host = To#jid.lserver,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Proc ! {addlog, {from, To#jid.luser, Host , From, P}}.


% storage loop.     Storages is a list containing 'open' storage element
%    storage element are in the form: { Timestamp , { LUser , LServer ,  Jid , Start } }
loop(Host , Storages, { Save_Default, Session_Duration } ) ->
    receive
        {addlog, { Dirrection , LUser , LServer , Jid , P  }} ->
            NStorages = case catch should_store_jid( LUser , LServer , Jid  , Save_Default) of
                false -> Storages;
                true ->
                    case parse_message(P) of
                        ignore ->  Storages;
                        Body -> catch do_log( Storages , LUser, LServer, Jid , Dirrection, Body , Session_Duration )
                    end
            end,
            loop(Host, NStorages, { Save_Default, Session_Duration });
        {get_save_default, Pid} ->
            Pid ! Save_Default,
            loop(Host, Storages, { Save_Default, Session_Duration });
        stop ->
           ok;
        _ ->
           loop(Host, Storages, { Save_Default, Session_Duration })
    end.



% parce a message and return the body string if sicessfull,  return  ignore if the message should not be stored 
parse_message({xmlelement , "message" , _ , _ } = Packet) ->
    case xml:get_subtag(Packet, "body") of
         false ->  ignore;
         Body_xml ->
            case xml:get_tag_attr_s("type", Packet) of
                "groupchat" -> ignore ;
                _ ->  xml:get_tag_cdata(Body_xml)
             end
    end;
parse_message(_) -> ignore.

% archive the message Body    return the list of new Storages
%  Storages:  a list of open storages key (usjs)
%  LUser , LServer :  the local user's information
%  Jid : the contact's jid
%  Body : the message body
do_log( Storages, LUser, LServer, Jid , Dirrection,  Body , Session_Duration ) ->
    NStorages = smart_find_storage( LUser , LServer, Jid , Storages , get_timestamp() + Session_Duration ),
    [{Tm , { _ , _ , _ , Start } = Key } | _ ] = NStorages,
    Message = #msg{dirrection=Dirrection , secs=(Tm-Start), body = Body },
    mnesia:transaction( fun() ->
        NE = case mnesia:read({archive_message, Key }) of
                [] ->
                    #archive_message{ usjs= Key , 
                                      us = { LUser , LServer } ,
                                      jid = jlib:jid_tolower(jlib:jid_remove_resource(Jid)) ,
                                      start = Tm ,
                                      message_list = [ Message ]  };
                [E] -> E#archive_message{ message_list=lists:append( E#archive_message.message_list , [ Message ] ) }
          end,
          mnesia:write( NE )
        end),
    NStorages.

%find a storage for Jid and move it on the begin on the storage list,  if none are found, a new storage is created, old storages element are removed
smart_find_storage( LUser, LServer, Jid , [ C | Tail ] , TimeStampLimit ) ->
    NGid=jlib:jid_remove_resource(jlib:jid_tolower(Jid)),
    case C of
        { _ , { LUser , LServer , NGid , _ } = St } -> 
                [ { get_timestamp() , St } | Tail ];
        { Tm , _ }  ->
            if  Tm > TimeStampLimit -> 
                    smart_find_storage( LUser, LServer, Jid , [ ] , TimeStampLimit );
                true -> 
                    [ UJ | NT ] = smart_find_storage( LUser , LServer , Jid , Tail , TimeStampLimit ),
                    [ UJ | [ C | NT ]  ]
            end
    end;


smart_find_storage( LUser, LServer, Jid , [ ] , _Limit ) ->
    Tm = get_timestamp() ,
    [ { Tm , { LUser, LServer , jlib:jid_tolower(jlib:jid_remove_resource(Jid)) , Tm } } ].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  3.1 Save Mode
%%

process_local_iq_save(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    Result = case Type of
        set ->
            {xmlelement, _Name, _Attrs, Els} = SubEl, 
            process_save_set(From#jid.luser , From#jid.lserver, Els);
        get ->
            process_save_get(From#jid.luser , From#jid.lserver)
        end,
    case Result of
        {result , R } ->
            IQ#iq{type = result, sub_el = [R] };
        ok -> 
            broadcast_iq(From, IQ#iq{type = set, sub_el=[SubEl]}),
            IQ#iq{type = result, sub_el = [] };
        {error , E } ->
            IQ#iq{type = error, sub_el = [SubEl , E]};
        _ ->
            IQ#iq{type = error, sub_el = [SubEl , ?ERR_INTERNAL_SERVER_ERROR]}
    end.




% return {error , xmlelement} or {result , xmlelement }
process_save_get(LUser, LServer) ->
    case catch mnesia:dirty_read(archive_options, {LUser, LServer}) of
        {'EXIT', _Reason} ->
            {error, ?ERR_INTERNAL_SERVER_ERROR};
        [] ->
            {result, {xmlelement , "save" , [{"xmlns", ?NS_ARCHIVE}] , [default_element(LServer)]}}; 
        [#archive_options{default = Default, save_list = Save_list , nosave_list = Nosave_list}] ->
            LItems =  lists:append( 
                            lists:map( fun(J) ->
                                    {xmlelement, "item", [{"jid", jlib:jid_to_string(J)}, {"save","true"}] , []}
                                end, Save_list),
                            lists:map( fun(J) ->
                                    {xmlelement, "item", [{"jid", jlib:jid_to_string(J)}, {"save","false"}] , []}
                                end, Nosave_list) ),
            DItem = case Default of
                        true ->
                            {xmlelement, "default",[{"save", "true"} ], []};
                        false ->
                            {xmlelement, "default",[{"save", "false"} ], []};
                        _ -> 
                            default_element(LServer)
                    end,
            {result, {xmlelement , "save" , [{"xmlns", ?NS_ARCHIVE}] , [DItem | LItems] } }
    end.
    
%return the <default save='unset' service='...' /> element
default_element(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Proc ! {get_save_default , self()},
    receive
        Service ->
            {xmlelement, "default",[{"save", "unset"} , {"service" , atom_to_list(Service)}], []}
    end.


% return {error , xmlelement} or {result , xmlelement } or  ok
process_save_set(LUser, LServer, Elms) ->
    F = fun() ->
            NE = case mnesia:read({archive_options, {LUser, LServer}}) of
                [] ->
                    #archive_options{ us = { LUser , LServer }  };
                [E] ->
                    E
                end,
            SNE=transaction_parse_save_elem(NE,Elms),
            case SNE of
                {error , _} -> SNE;
                _ -> mnesia:write( SNE )
            end
       end,
    case mnesia:transaction(F) of
        {atomic, {error, _} = Error} ->
            Error;
        {atomic, _ } ->
            ok;
        _ ->  {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.


% transaction_parse_save_elem( archive_options , ListOfXmlElement ) -> #archive_options
%  parse the list of xml element, and modify the given archive_option
transaction_parse_save_elem(Options, [ {xmlelement , "default" , Attrs , _ } | Tail]) ->
    V = case xml:get_attr_s("save", Attrs) of
            "true" -> true;
            "false" -> false;
            _ -> unset
        end,
    transaction_parse_save_elem( Options#archive_options{default = V} , Tail );

transaction_parse_save_elem(Options, [ {xmlelement , "item" , Attrs , _}  | Tail]) ->
    case jlib:string_to_jid(xml:get_attr_s("jid", Attrs)) of
        error -> { error , ?ERR_JID_MALFORMED };
        #jid{luser=LUser,lserver=LServer,lresource=LResource} ->
            Jid = {LUser, LServer, LResource }, 
            case xml:get_attr_s("save", Attrs) of
                "true" -> 
                    transaction_parse_save_elem( Options#archive_options{save_list=[Jid | lists:delete(Jid,Options#archive_options.save_list) ]  , 
                                                                        nosave_list=lists:delete(Jid,Options#archive_options.nosave_list) 
                                                                        } , Tail );
                "false" ->
                    transaction_parse_save_elem( Options#archive_options{save_list=lists:delete(Jid,Options#archive_options.save_list) , 
                                                                        nosave_list=[Jid | lists:delete(Jid,Options#archive_options.nosave_list) ]
                                                                        } , Tail );
                _ -> 
                    transaction_parse_save_elem( Options#archive_options{save_list=lists:delete(Jid,Options#archive_options.save_list ) , 
                                                                        nosave_list=lists:delete(Jid,Options#archive_options.nosave_list)
                                                                        } , Tail )
              end
    end;

transaction_parse_save_elem(Options, [ ]) ->  Options;
transaction_parse_save_elem(Options, [ _ | Tail ]) ->  transaction_parse_save_elem(Options,  Tail).


broadcast_iq(#jid{luser = User, lserver = Server}, IQ) ->
    Fun = fun(Resource) ->
        ejabberd_router:route(
                    jlib:make_jid("", Server, ""),
                    jlib:make_jid(User, Server, Resource),
                    jlib:iq_to_xml(IQ#iq{id="push"}))
        end,
    lists:foreach(Fun, ejabberd_sm:get_user_resources(User,Server)).
    


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  3.1 Off-the-Record Mode
%%

%TODO







%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Utility function

% Return true if LUser@LServer should log message for the contact Jid
should_store_jid( LUser , LServer , Jid , Service_Default) ->
    case catch mnesia:dirty_read(archive_options, {LUser, LServer}) of
        [#archive_options{default = Default, save_list = Save_list , nosave_list = Nosave_list}] ->
            Jid_t = jlib:jid_tolower(Jid),
            Jid_b = jlib:jid_remove_resource(Jid_t),
            A = lists:member(Jid_t, Save_list),
            B = lists:member(Jid_t, Nosave_list),
            C = lists:member(Jid_b, Save_list),
            D = lists:member(Jid_b, Nosave_list),
            if  A -> true;
                B -> false;
                C -> true;
                D -> false;
                Default == true -> true;
                Default == false -> false;
                true -> Service_Default
            end;
        _ -> Service_Default
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%   4. Manual Archiving
%%


process_local_iq_store(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case Type of
        get ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        set ->
            case parse_store_element ( LUser, LServer, SubEl ) of
                { error , E } ->  IQ#iq{type = error, sub_el = [SubEl , E ]} ;
                Collection ->
                     case mnesia:transaction(fun() -> mnesia:write( Collection ) end) of
                        {atomic, _ } ->
                            IQ#iq{type = result , sub_el=[]};
                        _ ->
                            IQ#iq{type = error, sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]}
                        end
            end
    end.



% return a #archive_message   StoreElem is an xmlelement   , or return  {error, E}
parse_store_element(LUser, LServer, {xmlelement, "store" , Attrs , SubEls } ) ->
     case index_from_argument(LUser, LServer, Attrs)  of
        {error , E } -> {error , E} ;
        { LUser , LServer , Jid , Start } = Index ->
            Messages = parse_store_element_sub( SubEls ) ,
            #archive_message{ usjs = Index , 
                              us = { LUser, LServer} , 
                              jid = Jid ,
                              start = Start,
                              subject = xml:get_attr_s("subject" , Attrs ) ,
                              message_list = Messages  }  
    end.

parse_store_element_sub( [ {xmlelement , Dir , _  , _ }  = E | Tail ] ) ->
    [ #msg{  dirrection=list_to_atom(Dir) , secs= list_to_integer(xml:get_tag_attr_s("secs" , E)), body=xml:get_tag_cdata(xml:get_subtag(E,"body")) } |
            parse_store_element_sub( Tail ) ];

parse_store_element_sub( [ ] ) -> [];
parse_store_element_sub( [ _ | Tail ] ) -> parse_store_element_sub( Tail ).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%   5. Archive Management
%%


process_local_iq_list(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case Type of
        set ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        get ->
            {xmlelement, _ , Attrs, SubEls} = SubEl,
            RSM = parse_rsm(SubEls),
            ?MYDEBUG("RSM Results: ~p ~n" , [RSM]),
            Result = case parse_root_argument(Attrs) of 
                {error , E } -> {error , E};
                {interval, Start , Stop } -> get_list(LUser, LServer , Start, Stop, '_' );
                {interval, Start , Stop , Jid } -> get_list(LUser, LServer , Start, Stop, Jid);
                _ -> { error , ?ERR_BAD_REQUEST }
            end,
            case Result of
                {ok, Items} ->
                    FunId = fun(El) -> ?MYDEBUG("FunId  ~p  ~n" , [El] ),  integer_to_list(element(5,El)) end,
                    FunCompare = fun(Id , El) -> 
                                        Id2=list_to_integer(FunId(El)), 
                                        Id1=list_to_integer(Id),
                                        if Id1 == Id2 -> equal;
                                           Id1 > Id2 -> greater;
                                           Id1 < Id2 -> smaller
                                        end
                                    end,
                    case catch execute_rsm(RSM, lists:keysort(5, Items), FunId,FunCompare )  of
                        {error, R} ->
                            IQ#iq{type = error, sub_el = [SubEl , R]};
                        {'EXIT' , Errr} ->
                            ?MYDEBUG("INTERNAL ERROR  ~p  ~n" , [Errr] ),
                            IQ#iq{type = error, sub_el = [SubEl , ?ERR_INTERNAL_SERVER_ERROR]};
                        { RSM_Elem , Items2 } ->
                            Zero = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
                            Fun = fun(A) ->
                                    Seconds= A#archive_message.start-Zero,
                                    Start2 =  jlib:now_to_utc_string(  {Seconds div 1000000, Seconds rem 1000000, 0} ) ,
                                    Args0 = [{"with", jlib:jid_to_string(A#archive_message.jid)} , {"start" , Start2 }  ] ,
                                    Args = case  A#archive_message.subject of
                                                "" -> Args0;
                                                Subject -> [ {"subject",Subject} | Args0 ]
                                            end,
                                    {xmlelement, "store", Args , [] }
                                end,
                            IQ#iq{type = result, sub_el = [{xmlelement, "list", [{"xmlns", ?NS_ARCHIVE}], lists:append(lists:map(Fun, Items2 ),[ RSM_Elem ] ) }] }
                    end;
                {error, R} ->
                    IQ#iq{type = error, sub_el = [SubEl , R]}
            end
        end.
    
    
    
    
process_local_iq_retrieve(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case Type of
        set ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        get ->
            {xmlelement, _ , Attrs , SubEls } = SubEl,
            RSM = parse_rsm(SubEls),
            case index_from_argument(LUser, LServer, Attrs  )  of
                { error , E } ->  IQ#iq{type = error, sub_el = [SubEl , E ]} ;
                Index -> 
                    case retrieve_collection( Index, RSM ) of
                            {error, Err } ->  IQ#iq{type = error, sub_el = [SubEl , Err]};
                            Store -> IQ#iq{type = result, sub_el = [Store] }
                    end
                end
        end.
        

retrieve_collection(Index, RSM) ->
    case get_collection(Index) of
        {error, E} ->
            {error, E};
        A ->
            Zero = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
            Seconds = A#archive_message.start-Zero,
            Start2 =  jlib:now_to_utc_string(  {Seconds div 1000000, Seconds rem 1000000, 0} ) ,
            Args0 = [{"xmlns", ?NS_ARCHIVE} , {"with", jlib:jid_to_string(A#archive_message.jid)} , {"start" , Start2 } ] ,
            Args = case  A#archive_message.subject of
                            "" -> Args0;
                            Subject -> [ Subject | Args0 ]
                    end,
            case catch execute_rsm(RSM, A#archive_message.message_list, index , index )  of
                {error, R} ->
                    {error , R};
                {'EXIT' , _ } ->
                    {error, ?ERR_INTERNAL_SERVER_ERROR};
                {RSM_Elem , Items} ->
                    Format_Fun = fun(Elem) ->
                        {xmlelement,  atom_to_list( Elem#msg.dirrection) , 
                            [ {"secs" , integer_to_list(Elem#msg.secs) } ] ,
                            [ {xmlelement , "body" , [] , [{xmlcdata,  Elem#msg.body }] } ] }
                    end,
                    {xmlelement, "store", Args , lists:append(lists:map(Format_Fun, Items ), [RSM_Elem]) }
            end
        end.
        
            
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%   5.3 Removing a Collection
%%


process_local_iq_remove(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    #jid{luser = LUser, lserver = LServer} = From,
    case Type of
        get ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        set ->
            {xmlelement, _,  Attrs, _} = SubEl,
            Result = case parse_root_argument(Attrs) of
                {error , E } ->  IQ#iq{type = error, sub_el = [SubEl, E ] } ;
                {interval, Start , Stop } -> process_remove_interval(LUser, LServer , Start, Stop, '_');
                {interval, Start , Stop , Jid } -> process_remove_interval(LUser, LServer , Start, Stop, Jid);
                {index , Jid, Start } -> process_remove_index({LUser, LServer , Jid, Start})
            end,
            case Result of
                { error , Ee } ->  IQ#iq{type = error, sub_el = [SubEl , Ee ]} ;
                ok -> IQ#iq{type = result , sub_el=[]}
            end
        end.
        
process_remove_index( Index ) ->
    case mnesia:transaction(fun() -> mnesia:delete({archive_message, Index})  end) of
         {atomic, _} ->
            ok; 
         {aborted, _} ->   
           {error, ?ERR_ITEM_NOT_FOUND}
    end.

process_remove_interval(LUser, LServer , Start, End, With) ->
    Fun = fun() ->
                Pat = #archive_message{ usjs= '_' ,  us = { LUser, LServer } , jid= With ,   
                                    start='$1' , message_list='_' , subject = '_' },
                Guard = [{'>=', '$1', Start},{'<', '$1', End}],

                lists:foreach(fun(R) ->  mnesia:delete_object(R)    end,
                     mnesia:select(archive_message, [{Pat, Guard, ['$_']}]) )
            end,
            
    case mnesia:transaction( Fun ) of
        {atomic, _} ->
            ok; 
        {aborted, _} ->   
            {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.
    


% return { ok, [ { #archive_message } ] } or { error , xmlelement }
% With is a tuple Jid,  or '_'
get_list(LUser, LServer , Start, End, With ) ->
    case mnesia:transaction(fun() ->
                               Pat = #archive_message{ usjs= '_' ,  us = { LUser, LServer } , jid= With ,   
                                                        start='$1' , message_list='_' , subject = '_' },
                               Guard = [{'>=', '$1', Start},{'<', '$1', End}],
                                mnesia:select(archive_message, [{Pat, Guard, ['$_']}]) 
                            end) of
         {atomic, Result} -> 
                  {ok, Result};
         {aborted, _} ->   
           {error, ?ERRT_INTERNAL_SERVER_ERROR("",  "plop" )}
    end.


% Index is  {LUser, LServer , With , Start} 
get_collection( Index ) ->
    case catch mnesia:dirty_read(archive_message, Index) of
        {'EXIT', _Reason} ->
            {error, ?ERR_INTERNAL_SERVER_ERROR};
        [] ->  
            {error, ?ERR_ITEM_NOT_FOUND};
        [C] -> C
    end.




%%%%%%%%%%%%%%%%%%%%%%%%%%
% Utility


% return either  {error , Err }  or {LUser, LServer , Jid , Start}   
index_from_argument(LUser, LServer,  Attrs ) ->
    case parse_root_argument( Attrs ) of
        { error , E } ->  { error , E } ;
        { index , Jid , Start } -> {LUser, LServer , Jid , Start};
        _ -> { error, ?ERR_BAD_REQUEST }
    end.

%parse commons arguments of root elements
parse_root_argument( Attrs ) ->
    case parse_root_argument_aux(Attrs , { undefined , undefined , undefined} ) of
        {error , E } -> {error , E};
        {{ok,Jid } , {ok,Start} , undefined }   ->  { index , Jid , Start };
        {{ok,Jid } , undefined  , undefined }   ->  { interval , 0 , ?INFINITY , Jid };
        {{ok,Jid } , {ok,Start} , {ok,Stop} }   ->  { interval , Start , Stop , Jid };
        {undefined , {ok,Start} , {ok,Stop} }   ->  { interval , Start , Stop };
        {undefined , undefined  , undefined }   ->  { interval , 0 , ?INFINITY  };
        _ -> {error,  ?ERR_BAD_REQUEST}
    end.

parse_root_argument_aux([{"with", JidStr} | Tail ] , { _ , AS , AE} ) ->
    case jlib:string_to_jid( JidStr ) of
        error -> { error , ?ERR_JID_MALFORMED };
        JidS -> 
            Jid = jlib:jid_tolower(JidS),
            parse_root_argument_aux( Tail  , { {ok , Jid} , AS , AE  } )
    end;
parse_root_argument_aux([{"start", Str} | Tail ] , { AW , _ , AE} ) ->
    case jlib:datetime_string_to_timestamp( Str ) of
        undefined -> { error , ?ERR_BAD_REQUEST };
        No ->
            Val = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(No)),
            parse_root_argument_aux( Tail  , { AW , {ok , Val} , AE  } )
    end;
parse_root_argument_aux([{"end", Str} | Tail ] , { AW , AS , _} ) ->
    case jlib:datetime_string_to_timestamp( Str ) of
        undefined -> { error , ?ERR_BAD_REQUEST };
        No ->
            Val = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(No)),
            parse_root_argument_aux( Tail  , { AW , AS , {ok , Val}  } )
    end;
parse_root_argument_aux([ _ | Tail ] , A ) ->
    parse_root_argument_aux( Tail , A );
parse_root_argument_aux([ ] , A ) ->  A.
    


get_timestamp() -> calendar:datetime_to_gregorian_seconds(calendar:local_time()).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%  Result Set Management (  JEP-0059 )
%
% USAGE:
%   RSM = parce_rsm( Xmlelement )
%   case execute_rsm( RSM , List,  GetIdFun , IdCompareFun) of
%      {error , E } -> .... ;
%      {RSMElement , Items} ->
%           SubElements = lists:append(lists:map(Format_Fun, Items ), [RSMElement]), 
%           ...;
%   end

-define(NS_RSM, "http://jabber.org/protocol/rsm").




%  { Start , Max , Order } | error |  none  % | count

parse_rsm( [ A | Tail ]  ) ->
    ?MYDEBUG("parse RSM elem ~p " , [A ] ),
    case A of
        {xmlelement , _ ,  Attrs1, _} ->
            case xml:get_attr_s("xmlns", Attrs1) of
                ?NS_RSM ->
                    parse_rsm( A );
                HEPO ->
                    ?MYDEBUG("HEPO ~p " , [ HEPO ] ),
                    parse_rsm( Tail )
            end;
        _ -> 
            parse_rsm( Tail )
    end;
parse_rsm( [] ) ->
    none;

% parse_rsm( {xmlelement , "count" , _ , _}  ) ->
%     count;
    
parse_rsm( {xmlelement , "set" , _ , SubEls } ) ->
    parse_rsm_aux( SubEls , { 0 , infinity , normal } );
    
parse_rsm( _ ) ->
    error.

parse_rsm_aux([ {xmlelement , "max" , _Attrs , Contents} | Tail] , Acc) ->
    case catch list_to_integer(xml:get_cdata(Contents)) of
        P when is_integer(P) ->
            case Acc of
                { Start , infinity , Order } ->
                    parse_rsm_aux(Tail , {Start , P , Order});
                _ ->
                    error
            end;
        HEPO ->
            ?MYDEBUG("<max> Not an INTEGER ~p " , [ HEPO ] ),
            error
    end;
    
parse_rsm_aux([ {xmlelement , "index" , _Attrs , Contents} | Tail] , Acc) ->
    case catch list_to_integer(xml:get_cdata(Contents)) of
        P when is_integer(P) ->
            case Acc of
                { 0 , Max , normal } ->
                    parse_rsm_aux( Tail , { P , Max , normal}); 
                _ ->
                    error
            end;
        _ ->
            error
    end;
    
parse_rsm_aux([ {xmlelement , "after" , _Attrs , Contents} | Tail] , Acc) ->
    case Acc of
        { 0 , Max , normal } ->
            parse_rsm_aux( Tail , { {id, xml:get_cdata(Contents)} , Max , normal}); 
        _ ->
            error
    end;
    

parse_rsm_aux([ {xmlelement , "before" , _Attrs , Contents} | Tail] , Acc) ->
    case Acc of
        { 0 , Max , normal } ->
            case xml:get_cdata(Contents) of
                [] ->
                    parse_rsm_aux( Tail , { 0 , Max , reversed});
                CD ->
                    parse_rsm_aux( Tail , { {id, CD} , Max , reversed})
            end;
        _ ->
            error
    end;
    
parse_rsm_aux([ _ | Tail] , Acc) ->
    parse_rsm_aux( Tail , Acc);
parse_rsm_aux([], Acc) ->
    Acc.

%  RSM = { Start , Max , Order }  
%  GetId = fun(Elem) -> Id
%  IdCompare = fun(Id , Elem) -> equal | greater | smaller
%
%  ->  { RSMElement , List } | { error , ErrElement }

execute_rsm(RSM , List, GetId , IdCompare ) ->
    ?MYDEBUG("execute_rsm RSM ~p  ~n" , [RSM ] ),
    case execute_rsm_aux( RSM , List , IdCompare , 0) of
        none ->
            { {xmlcdata, ""} , List};
%         count ->
%             { {xmlelement , "count" , [{"xmlns" , ?NS_RSM}] , [{xmlcdata,  integer_to_list(length(List)) }] } , [] };
        { error , E } ->
            { error , E };
        { _ , [] } ->
              { {xmlelement , "set" , [{"xmlns", ?NS_RSM}] , [{xmlelement , "count" , [] , [{xmlcdata,  integer_to_list(length(List)) }] } ] }, [] };
        { Index , L } ->
            case GetId of
                index ->
                    { make_rsm(Index , integer_to_list(Index) , integer_to_list(Index+length(L)) ,length(List) ) , L};
                _ ->
                    { make_rsm(Index , GetId(hd(L)) , GetId(lists:last(L)) ,length(List) ) , L}
            end
    end.


% execute_rsm_aux(count , _List, _ , _) ->
%      count;
     
execute_rsm_aux(none, _List , _ , _ ) ->
    none;
    
execute_rsm_aux(error, _List , _ , _ ) ->
    { error, ?ERR_BAD_REQUEST};
    
execute_rsm_aux({S , M , reversed}, List , IdFun , Acc) ->
    {NewFun,NewS} = case IdFun of
        index ->
            {index , 
                case S of 
                    {id, IdentIndex } ->
                        integer_to_list(length(List) - list_to_integer(IdentIndex));
                    _ -> S
                end } ;
        _ ->
            {fun( Index, Elem ) ->  
                    case IdFun( Index, Elem ) of
                        equal -> equal;
                        greater -> smaller;
                        smaller -> greater;
                        O -> O 
                    end
                end,
               S}
        end,
    { Index , L2 } =  execute_rsm_aux({NewS,M,normal} , lists:reverse(List) , NewFun, 0), 
    { Acc + length(List) - Index , lists:reverse( L2 )};

execute_rsm_aux({ {id,I} , M , normal } , List ,  index,  Acc ) ->
    execute_rsm_aux({ list_to_integer(I) , M , normal }, List ,  index,  Acc );

execute_rsm_aux({ {id,I} , M , normal } = RSM , [ E | Tail ] ,  IdFun,  Acc ) ->
    case IdFun(I, E) of
        smaller ->
            execute_rsm_aux( RSM , Tail ,  IdFun ,  Acc + 1);
         _ ->
            execute_rsm_aux( { 0 , M , normal} , [ E | Tail ] ,  IdFun , Acc )
    end;

execute_rsm_aux({ {id,_} , _ , normal }  , [ ] , _ , Acc ) ->
    { Acc , [] };
    
execute_rsm_aux({ 0 , infinity , normal } , List , _, Acc ) ->
    {Acc, List};
    
execute_rsm_aux({ _ , 0 , _ } , _ , _ , Acc) ->
    {Acc , []};

execute_rsm_aux({ S , M , _ } , List , _ , Acc )  when  is_integer(S) and is_integer(M) ->
    ?MYDEBUG("execute_rsm_aux  sublist  ~p  ~n" , [{S,M,List,Acc}] ),
    { Acc + S , lists:sublist(List, S+1,M) }.

make_rsm(FirstIndex, FirstId, LastId , Count) ->
    {xmlelement , "set" , [{"xmlns", ?NS_RSM}] , [
        {xmlelement , "first" , [{"index", integer_to_list(FirstIndex)}] , [{xmlcdata,  FirstId }] } ,
        {xmlelement , "last" , [] , [{xmlcdata,  LastId }] } ,
        {xmlelement , "count" , [] , [{xmlcdata,  integer_to_list(Count) }] } ] }.
        

