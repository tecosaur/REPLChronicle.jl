const PROMPT_TEXT = "▪: "
const KEY_UP_ARROW = "\e[A"
const KEY_CTRL_P = "^P"
const KEY_DOWN_ARROW = "\e[B"
const KEY_CTRL_N = "^N"
const KEY_TAB = '\t'
const KEY_PAGE_UP = "\e[5~"
const KEY_PAGE_DOWN = "\e[6~"
const KEY_META_LT = "\e<"
const KEY_META_GT = "\e>"
const KEY_CTRL_C = "^C"
const KEY_CTRL_D = "^D"
const KEY_CTRL_S = "^S"

function select_keymap(events::Channel{Symbol})
    REPL.LineEdit.keymap([
        Dict{Any,Any}(
            # Up Arrow
            KEY_UP_ARROW => (_...) -> (push!(events, :moveup); :ignore),
            KEY_CTRL_P => (_...) -> (push!(events, :moveup); :ignore),
            # Down Arrow
            KEY_DOWN_ARROW => (_...) -> (push!(events, :movedown); :ignore),
            KEY_CTRL_N => (_...) -> (push!(events, :movedown); :ignore),
            # Tab
            KEY_TAB => (_...) -> (push!(events, :tab); :ignore),
            # Page up
            KEY_PAGE_UP => (_...) -> (push!(events, :pageup); :ignore),
            # Page down
            KEY_PAGE_DOWN => (_...) -> (push!(events, :pagedown); :ignore),
            # Meta + < / >
            KEY_META_LT => (_...) -> (push!(events, :jumpfirst); :ignore),
            KEY_META_GT => (_...) -> (push!(events, :jumplast); :ignore),
            # Exits
            KEY_CTRL_C => Returns(:abort),
            KEY_CTRL_D => Returns(:abort),
            KEY_CTRL_S => Returns(:save),
        ),
        REPL.LineEdit.default_keymap,
        REPL.LineEdit.escape_defaults,
    ])
end

function create_prompt(events::Channel{Symbol})
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", Sys.iswindows() ? "" : "dumb"), stdin, stdout, stderr)
    prompt = REPL.LineEdit.Prompt(
        PROMPT_TEXT, # prompt
        "\e[90m",
        "\e[0m", # prompt_prefix, prompt_suffix
        "",
        "",
        "", # output_prefix, output_prefix_prefix, output_prefix_suffix
        select_keymap(events), # keymap_dict
        nothing, # repl
        REPL.LatexCompletions(), # complete
        _ -> true, # on_enter
        () -> nothing, # on_done
        REPL.LineEdit.EmptyHistoryProvider(), # hist
        false,
    ) # sticky
    interface = REPL.LineEdit.ModalInterface([prompt])
    istate = REPL.LineEdit.init_state(term, interface)
    pstate = istate.mode_state[prompt]
    (; term, prompt, istate, pstate)
end

function runprompt!((; term, prompt, pstate, istate), events::Channel{Symbol})
    Base.reseteof(term)
    REPL.LineEdit.raw!(term, true)
    REPL.LineEdit.enable_bracketed_paste(term)
    try
        pstate.ias = REPL.LineEdit.InputAreaState(0, 0)
        REPL.LineEdit.refresh_multi_line(term, pstate)
        while true
            kmap = REPL.LineEdit.keymap(pstate, prompt)
            matchfn = REPL.LineEdit.match_input(kmap, istate)
            kdata = REPL.LineEdit.keymap_data(pstate, prompt)
            status = matchfn(istate, kdata)
            if status === :ok
                push!(events, :edit)
            elseif status === :ignore
                istate.last_action = istate.current_action
            elseif status === :done
                print("\e[F")
                push!(events, :confirm)
                break
            elseif status === :save
                print("\e[1G\e[J")
                REPL.LineEdit.raw!(term, false) && REPL.LineEdit.disable_bracketed_paste(term)
                push!(events, :save)
                break
            else
                push!(events, :abort)
                break
            end
        end
    finally
        REPL.LineEdit.raw!(term, false) && REPL.LineEdit.disable_bracketed_paste(term)
    end
end
