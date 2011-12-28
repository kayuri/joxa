%% -*- mode: Erlang; fill-column: 76; comment-column: 76; -*-
-module(jxa_compile).

-export([main/0, main/1, comp/1, format_exception/1]).

-include_lib("joxa/include/joxa.hrl").
%%=============================================================================
%% Types
%%=============================================================================

%%=============================================================================
%% Public API
%%=============================================================================
main() ->
    main(init:get_plain_arguments()).

main(Args) ->
    case getopt:parse(option_spec_list(), Args) of
        {ok, {Options, [Target]}} ->
            {Ctx0, Binary} = comp(Target),
            save_beam(Options, Binary, Ctx0);
        _ ->
            usage(option_spec_list()),
            ?JXA_THROW(invalid_options_passed_in)
    end.

-spec comp(string() | binary()) -> {jxa_ctx:ctx(), binary()}.
comp(FileName) when is_list(FileName) ->
    case file:read_file(FileName) of
        {ok, Binary} ->
            Result = {Ctx0, ModuleBinary} = comp(Binary),
            ModuleName = jxa_ctx:module_name(Ctx0),
            {module, ModuleName} =
                code:load_binary(ModuleName, FileName, ModuleBinary),
            Result;
        {error, Reason} ->
            ?JXA_THROW({file_access, Reason, FileName})
    end;
comp(BinaryData) when is_binary(BinaryData) ->
    {Annots, Ast0} = jxa_parser:parse(BinaryData),
    Ctx0 = jxa_ctx:new(Annots),
    {_, Ctx3, Binary} =
        lists:foldl(fun(DefAst, {Path, Ctx1, _Binary}) ->
                            {Ctx2, Binary1} = comp_forms(jxa_path:add(Path),
                                                         Ctx1, DefAst),
                            ModuleName = jxa_ctx:module_name(Ctx2),
                            {module, ModuleName} =
                                code:load_binary(ModuleName,
                                                 "", Binary1),
                            {jxa_path:incr(Path), jxa_ctx:update(Ctx2),
                             Binary1}
                    end, {jxa_path:new(), Ctx0, <<>>}, Ast0),
    {Ctx3, Binary}.

-spec format_exception(ExceptionBody::term()) -> IoList::[term()].
format_exception({file_access, enoent, FileName}) ->
    io_lib:format("File does not exist ~s", [FileName]);
format_exception({file_access, eacces, FileName}) ->
    io_lib:format("Missing  permission for reading the file: ~s",
                  [FileName]);
format_exception({file_access, eisdir, FileName}) ->
    io_lib:format("The named file is a directory: ~s",
                  [FileName]);
format_exception({file_access, enomem, FileName}) ->
    io_lib:format("There is not enough memory for the contents of the file: ~s",
                  [FileName]);
format_exception({file_access, Reason, FileName}) ->
    io_lib:format("Unexpected error (~p) attempting to read file: ~s",
                  [Reason, FileName]).

%%=============================================================================
%% Internal Functions
%%=============================================================================
save_beam(Options, Binary, Ctx3) ->
    OutDir = proplists:get_value(outdir, Options, "./"),
    ModuleName = atom_to_list(jxa_ctx:module_name(Ctx3)),
    Path = re:split(ModuleName, "\\."),
    OutPath = filename:join([OutDir | Path]),
    OutFile = lists:flatten([binary_to_list(OutPath), ".beam"]),
    ok = filelib:ensure_dir(OutPath),
    ok = file:write_file(OutFile, Binary).

usage(OptSpecList) ->
    getopt:usage(OptSpecList, "", "[option1 option2 ...] jxa-file",
                 []).

-spec option_spec_list() -> list().
option_spec_list() ->
    [{outdir, $o, "outdir", string, "the directory to output beam files"}].


-spec comp_forms(jxa_path:state(),
                 jxa_ctx:context(),
                 [term()]) ->
                        jxa_ctx:context().
comp_forms(Path0, Ctx0, Module = [module | _]) ->
    Ctx1 = jxa_module:comp(Path0, Ctx0, Module),
    compile_context(Ctx1);
comp_forms(Path0, Ctx0, Definition) ->
    Ctx1 = jxa_definition:comp(Path0, Ctx0, Definition),
    compile_context(Ctx1).

-spec compile_context(jxa_ctx:context()) -> jxa_ctx:context().
compile_context(Ctx0) ->
    Ctx1 = compile_module_info(Ctx0),
    Line = jxa_ctx:line(Ctx1),
    ModuleName = cerl:ann_c_atom([Line],
                                 jxa_ctx:module_name(Ctx1)),
    Exports = [cerl:ann_c_fname([ELine], Fun, Arity) ||
                  {Fun, Arity, ELine} <- sets:to_list(jxa_ctx:exports(Ctx1))],
    Attrs0 = jxa_ctx:attrs(Ctx1),
    Defs = [Value || {_, Value} <-
                         ec_dictionary:to_list(jxa_ctx:definitions(Ctx1))],
    {Ctx1, erl_comp(cerl:ann_c_module([Line], ModuleName,
                                      Exports, Attrs0, Defs))}.

-spec compile_module_info(jxa_ctx:context()) -> jxa_ctx:context().
compile_module_info(Ctx0) ->
    ModuleName = cerl:c_atom(jxa_ctx:module_name(Ctx0)),
    ArglessBody = cerl:c_call(cerl:c_atom(erlang),
                              cerl:c_atom(get_module_info), [ModuleName]),
    Ctx1 = jxa_ctx:add_exported_definition(0, module_info, [],
                                           ArglessBody, Ctx0),
    VarName = cerl:c_var(mdetail),
    ArgBody = cerl:c_call(cerl:c_atom(erlang),
                          cerl:c_atom(get_module_info),
                          [ModuleName, VarName]),
    jxa_ctx:add_exported_definition(0, module_info, [VarName],
                                    ArgBody, Ctx1).


-spec erl_comp(cerl:cerl()) -> binary().
erl_comp(CerlAST) ->
    case compile:forms(CerlAST, [from_core,binary,no_bopt]) of
        {ok, _, Result} ->
            Result;
        Error = {error, _Errors, _Warnings} ->
            ?JXA_THROW(Error);
        InternalError ->
            ?JXA_THROW(InternalError)
    end.