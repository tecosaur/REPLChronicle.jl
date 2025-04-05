module REPLChronicle

using StyledStrings: @styled_str as @S_str, Face, addface!, face!, annotations, AnnotatedIOBuffer, AnnotatedString, AnnotatedChar
using JuliaSyntaxHighlighting: highlight
using Base.Threads
using Dates
using REPL

using PrecompileTools: @setup_workload, @compile_workload

include("histfile.jl")
include("resumablefiltering.jl")
include("prompt.jl")
include("display.jl")
include("search.jl")

HISTORY::HistoryFile = HistoryFile(IOStream("", UInt8[]), [])

const FACES = (
    # :REPL_history_search_prompt      => Face(foreground=:blue, inherit=:julia_prompt),
    :REPL_history_search_seperator   => Face(foreground=:blue),
    :REPL_history_search_prefix      => Face(foreground=:magenta),
    :REPL_history_search_selected    => Face(foreground=:blue),
    :REPL_history_search_unselected  => Face(foreground=:grey),
    # :REPL_history_search_preview_box => Face(foreground=:grey),
    :REPL_history_search_hint        => Face(foreground=:magenta, slant=:italic, weight=:light),
    :REPL_history_search_results     => Face(inherit=:shadow),
    :REPL_history_search_match       => Face(weight = :bold, underline = true),
)

function __init__()
    global HISTORY = HistoryFile(REPL.find_hist_file())
    foreach(addface!, FACES)
    # Hook into the REPL
    Base.active_repl.interface.modes[1].keymap_dict['\x12'] =
        (s::REPL.LineEdit.MIState, _...) -> repl_history_hook!(s)
end

function repl_history_hook!(mistate::REPL.LineEdit.MIState)
    REPL.LineEdit.cancel_beep(mistate)
    termbuf = REPL.LineEdit.TerminalBuffer(IOBuffer())
    term = REPL.LineEdit.terminal(Base.active_repl.mistate)
    mistate.mode_state[REPL.LineEdit.mode(mistate)] =
        REPL.LineEdit.deactivate(REPL.LineEdit.mode(mistate), REPL.LineEdit.state(mistate), termbuf, term)
    result = fullselection(runsearch!())
    mode = if isnothing(result.mode)
        mistate.current_mode
    else
        get(mistate.interface.modes[1].hist.mode_mapping,
            result.mode,
            mistate.current_mode)
    end
    pstate = mistate.mode_state[mode]
    REPL.LineEdit.raw!(term, true)
    mistate.current_mode = mode
    REPL.LineEdit.activate(mode, REPL.LineEdit.state(mistate, mode), termbuf, term)
    REPL.LineEdit.commit_changes(term, termbuf)
    REPL.LineEdit.edit_insert(pstate, result.text)
    REPL.LineEdit.refresh_multi_line(mistate)
    nothing
end

@setup_workload begin
    tmphist = tempname()
    write(tmphist, """
    # time: 2020-10-31 13:16:39 AWST
    # mode: julia
    \tcos
    # time: 2020-10-31 13:16:40 AWST
    # mode: julia
    \tsin
    # time: 2020-11-01 02:19:36 AWST
    # mode: help
    \t?
    """)
    global HISTORY = HistoryFile(tmphist)
    rawpts, ptm = REPL.Precompile.FakePTYs.open_fake_pty()
    pts = open(rawpts)::Base.TTY
    if Sys.iswindows()
        pts.ispty = false
    else
        # workaround libuv bug where it leaks pts
        Base._fd(pts) == rawpts || Base.close_stdio(rawpts)
    end
    orig_stdin, orig_stdout = stdin, stdout
    redirect_stdin(pts)
    redirect_stdout(pts)
    @compile_workload begin
        t = @spawn runsearch!()
        write(ptm, "?\e[A\e[B\t")
        wait(t)
    end
    redirect_stdin(isopen(orig_stdin) ? orig_stdin : devnull)
    redirect_stdout(isopen(orig_stdout) ? orig_stdout : devnull)
    close(pts)
    global HISTORY = HistoryFile(IOStream("", UInt8[]), [])
end

precompile(repl_history_hook!, (REPL.LineEdit.MIState,))

end
