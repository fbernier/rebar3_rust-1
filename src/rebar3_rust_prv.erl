-module(rebar3_rust_prv).

-export([init/1, do/1, format_error/1]).

-include_lib("kernel/include/file.hrl").

-define(PROVIDER, compile).
-define(NAMESPACE, rust).
-define(DEPS, []).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},               % The 'user friendly' name of the task
            {namespace, ?NAMESPACE},
            {module, ?MODULE},               % The module implementation of the task
            {bare, true},                    % The task can be run by the user, always true
            {deps, ?DEPS},                   % The list of dependencies
            {example, "rebar3 compile"},     % How to use the plugin
            {opts, []},                      % list of options understood by the plugin
            {short_desc, "Compile Rust crates"},
            {desc, "Compile Rust crates"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.


-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    %% execute for each app
    [ do_app(App, State) || App <- get_apps(State) ],
    {ok, State}.

get_apps(State) ->
    case rebar_state:current_app(State) of
        undefined ->
            rebar_state:project_apps(State);
        AppInfo ->
            [AppInfo]
    end.

%% process for one application
do_app(App, _State) ->
    Opts = rebar_app_info:opts(App),
    AppDir = rebar_app_info:dir(App),
    %PrivDir = rebar_app_info:priv_dir(App),  % ensure_dir/1 fails if priv not present (ref https://github.com/erlang/rebar3/issues/1173)
    PrivDir = filename:join(AppDir, "priv"),


    Tomls = filelib:wildcard("crates/*/Cargo.toml", AppDir),
    AbsTomls = [ filename:absname(T, AppDir) || T <- Tomls ],
    CrateDirs = [ filename:dirname( T) || T <- AbsTomls ],

    [ begin
          OutDir = filename:join([PrivDir, "crates", filename:basename(CrateDir)]),
          do_crate(CrateDir, OutDir, Opts)
      end || CrateDir <- CrateDirs ],
    ok.

do_crate(CrateDir, OutDir, _Opts) ->

    %% get the manifest
    {ok, ManifestIOData} = rebar_utils:sh("cargo read-manifest", [{cd, CrateDir}, {use_stdout, false}]),

    %% extract just the targets that are to be built
    #{targets := Targets0, name := _CrateName} = jsx:decode(
        erlang:iolist_to_binary(ManifestIOData),
        [return_maps, {labels, attempt_atom}]
    ),


    %% and tidy them up
    Targets = [ begin
                    #{name := Name0, kind := [Kind0|_]} = Target,
                    Kind = case Kind0 of
                               <<"bin">>    -> bin;
                               <<"dylib">>  -> dylib;
                               <<"cdylib">> -> dylib
                           end,
                    Name = binary_to_list(Name0),
                    #{name => Name, kind => Kind}
                end || Target <- Targets0 ],

    %OutDir = filename:join(OutDir0, CrateName),

    %% and build each target
    [ do_target(Target, CrateDir, OutDir) || Target <- Targets ],



    % Don't do this for Rust because it parallelizes builds.  Rust builds can use gobs of RAM.
    % Instead let Cargo parallelize as desired.
    % Furthermore Crates don't neccessarily fit the file translation model this function uses.
    %rebar_base_compiler:run(Opts, [], FoundFiles, CompileFun)
    ok.


do_target(#{kind := Kind, name := Name}, CrateDir, OutDir) ->
    %% build artifacts individually because some need special args
    KindSwitch = case Kind of
                     bin -> "--bin " ++ Name;
                     dylib -> "--lib"
                 end,
    LinkerArgs = linker_args(Kind),
    Cmd = lists:flatten(
        io_lib:format("cargo rustc --verbose ~s ~s", [KindSwitch, LinkerArgs])),
    {ok, _} = rebar_utils:sh(Cmd, [{cd, CrateDir}, {use_stdout, true}]),

    {DstName, SrcName} = target_filenames(Kind, Name),
    SrcPath = filename:join([CrateDir, "target", "debug", SrcName]),
    DstPath = filename:join([OutDir, DstName]),


    ok = filelib:ensure_dir(DstPath),

    cp(SrcPath, DstPath),


    ok.

%%
-spec(target_filenames(bin|dylib, string()) -> {Dst::string(), Src::string()}).
target_filenames(Kind, Name) -> target_filenames(Kind, Name, os_type()).
target_filenames(bin, Name, win)   -> {Name ++ ".exe", Name ++ ".exe"};
target_filenames(dylib, Name, win) -> {Name ++ ".dll", Name ++ ".dll"};
target_filenames(bin, Name, osx)   -> {Name, Name};
target_filenames(dylib, Name, osx) -> {"lib" ++ Name ++ ".so", "lib" ++ Name ++ ".dylib"};
target_filenames(bin, Name, unix)   -> {Name, Name};
target_filenames(dylib, Name, unix) -> {"lib" ++ Name ++ ".so", "lib" ++ Name ++ ".so"}.

%% OSX needs special args when linking a shared lib for Erlang.
linker_args(Kind) -> linker_args(Kind, os_type()).
linker_args(dylib, osx) -> "-- --codegen 'link-args=-flat_namespace -undefined suppress'";
linker_args(_, _) -> "".


os_type() ->
    case os:type() of
        {win32, nt} -> win;
        {unix, osx} -> osx;  %% FIXME: this is a guess.
        {unix, _} -> unix
    end.

cp(Src,Dst) ->
    {ok,_} = file:copy(Src, Dst),

    % sigh, file:copy() doesn't preserve executable bits, so copy that too
    case os:type() of
        {unix, _} ->
            {ok, #file_info{mode = Mode}} = file:read_file_info(Src),
            ok = file:change_mode(Dst, Mode),
            ok;
        {win32, _} ->
            ok
    end.

