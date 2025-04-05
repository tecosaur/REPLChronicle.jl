module REPLChronicle

using StyledStrings: @styled_str as @S_str, Face, addface!, face!, annotations, AnnotatedIOBuffer, AnnotatedString, AnnotatedChar
using JuliaSyntaxHighlighting: highlight
using Base.Threads
using Dates
using REPL

include("histfile.jl")
include("resumablefiltering.jl")
include("prompt.jl")
include("display.jl")
include("search.jl")

const HISTORY = Ref{HistoryFile}()

const FACES = (
    # :repl_history_search_prompt      => Face(foreground=:blue, inherit=:julia_prompt),
    :repl_history_search_seperator   => Face(foreground=:blue),
    :repl_history_search_prefix      => Face(foreground=:magenta),
    :repl_history_search_selected    => Face(foreground=:blue),
    :repl_history_search_unselected  => Face(foreground=:grey),
    # :repl_history_search_preview_box => Face(foreground=:grey),
    :repl_history_search_hint        => Face(foreground=:magenta, slant=:italic, weight=:light),
    :repl_history_search_results     => Face(inherit=:shadow),
)

function __init__()
    HISTORY[] = HistoryFile(REPL.find_hist_file())
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
    result = runsearch!()
    selection = result.candidates[result.selected]
    if isempty(selection)
        hov = gethover(result)
        !isnothing(hov) && push!(selection, hov)
    end
    mode = if isempty(selection)
        mistate.current_mode
    else
        get(mistate.interface.modes[1].hist.mode_mapping, first(selection).mode, mistate.current_mode)
    end
    pstate = mistate.mode_state[mode]
    REPL.LineEdit.raw!(term, true)
    mistate.current_mode = mode
    REPL.LineEdit.activate(mode, REPL.LineEdit.state(mistate, mode), termbuf, term)
    REPL.LineEdit.commit_changes(term, termbuf)
    content = join(map(e -> e.content, selection), '\n')
    REPL.LineEdit.edit_insert(pstate, content)
    REPL.LineEdit.refresh_multi_line(mistate)
    nothing
end


end
