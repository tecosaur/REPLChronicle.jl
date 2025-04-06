struct SelectorState
    area::@NamedTuple{height::Int, width::Int}
    query::String
    candidates::Vector{HistEntry}
    scroll::Int
    selected::Vector{Int}
    hover::Int
end

const EMPTY_STATE = SelectorState((0, 0), "", [], 0, [], 0)

STATES = Pair{SelectorState,SelectorState}[]

Base.copy(s::SelectorState) = SelectorState(s.area, s.query, copy(s.candidates), s.scroll, copy(s.selected), s.hover)

function redisplay_all(
    io::IO,
    oldstate::SelectorState,
    newstate::SelectorState,
    pstate::REPL.LineEdit.PromptState;
    buf::IOContext{IOBuffer} = IOContext(IOBuffer(), io),
)
    # Calculate dimensions
    oldrows = componentrows(oldstate)
    newrows = componentrows(newstate)
    # Redisplay components
    println(buf) # Move to line under prompt
    currentrow = 1
    if newstate.query == FILTER_HELP_QUERY
        print(buf, "\e[J", FILTER_HELPSTRING)
        currentrow += count('\n', FILTER_HELPSTRING)
    else
        if oldstate.area.width > newstate.area.width || oldstate.query == FILTER_HELP_QUERY
            print(buf, "\e[J")
            oldstate = EMPTY_STATE
        end
        if oldstate.candidates != newstate.candidates ||
           oldstate.area.width != newstate.area.width ||
           oldstate.scroll != newstate.scroll ||
           oldstate.selected != newstate.selected ||
           oldstate.hover != newstate.hover
            redisplay_candidates(buf, oldstate, oldrows.candidates, newstate, newrows.candidates)
            currentrow += newrows.candidates
        end
        if (@view oldstate.candidates[oldstate.selected]) != (@view newstate.candidates[newstate.selected]) ||
           gethover(oldstate) != gethover(newstate) ||
           oldstate.area.width != newstate.area.width
            redisplay_preview(buf, oldstate, oldrows.preview, newstate, newrows.preview)
            currentrow += (newrows.preview - 1)
        end
    end
    # Restore position
    print(buf, "\e[", currentrow, "A\e[1G")
    redisplay_prompt(buf, oldstate, newstate, pstate)
    # TODO: Redisplay prompt with highlighting
    print(buf, "\e[", textwidth(PROMPT_TEXT) + position(pstate.input_buffer) + 1, 'G')
    write(io, seekstart(buf.io))
    truncate(buf.io, 0)
    flush(io)
end

function componentrows(state::SelectorState)
    availible_rows = 2 * (state.area.height - 1) ÷ 3 # REVIEW: maybe `min(height, ?)`
    preview_min, preview_max = availible_rows ÷ 3, 2 * availible_rows ÷ 3
    nlines_preview = # if isempty(state.selected) && state.hover < length(state.candidates)
    #     1 + count('\n', state.candidates[hovidx(state)].content)
    # else
        countlines_selected(state.candidates, state.selected)
    # end
    preview_rows = clamp(nlines_preview, preview_min, preview_max)
    candidate_rows = availible_rows - preview_rows
    (; candidates = candidate_rows, preview = preview_rows)
end

function countlines_selected(candidates::Vector{HistEntry}, selected::Vector{Int})
    nlines = 0
    for idx in selected
        entry = candidates[idx]
        nlines += 1 + count('\n', entry.content)
    end
    nlines
end

const BASE_MODE = :julia

const MODE_FACES = Dict(:julia => :green, :shell => :red, :pkg => :blue, :help => :yellow)

function redisplay_prompt(io::IO, _::SelectorState, newstate::SelectorState, pstate::REPL.LineEdit.PromptState)
    hov = gethover(newstate)
    mface = if newstate.query == FILTER_HELP_QUERY
        :grey
    elseif !isnothing(hov)
        get(MODE_FACES, hov.mode, :grey)
    else
        :blue
    end
    query = newstate.query
    styquery = S"$query"
    styconds = ConditionSet(styquery)
    qpos = position(pstate.input_buffer)
    kindname = ""
    patend = 0
    for (name, substrs) in (
        ("words", styconds.words),
        ("exact", styconds.exacts),
        ("negative", styconds.negatives),
        ("initialism", styconds.initialisms),
        ("regexp", styconds.regexps),
        ("fuzzy", styconds.fuzzy),
        ("mode", styconds.modes),
    )
        for substr in substrs
            start, len = substr.offset, substr.ncodeunits
            patend = max(patend, start + len)
            if start > 1
                if query[start] == FILTER_SEPARATOR
                    face!(styquery[start:start], :repl_history_search_seperator)
                else
                    face!(styquery[start:start], :repl_history_search_prefix)
                    face!(styquery[start-1:start-1], :repl_history_search_seperator)
                end
            elseif start > 0
                face!(styquery[start:start], if query[start] == FILTER_SEPARATOR
                    :repl_history_search_seperator
                else
                    :repl_history_search_prefix
                end)
            end
            isempty(kindname) || continue
            if start <= qpos <= start + len
                kindname = name
                break
            end
        end
    end
    if patend < ncodeunits(query)
        if query[patend+1] == FILTER_SEPARATOR
            face!(styquery[patend+1:patend+1], :repl_history_search_seperator)
            if patend + 1 < ncodeunits(query) && query[patend+2] ∈ FILTER_PREFIXES
                face!(styquery[patend+2:patend+2], :repl_history_search_prefix)
            elseif isempty(kindname)
                kindname = "separator"
            end
        elseif ncodeunits(query) == 1 && query[1] ∈ FILTER_PREFIXES
            face!(styquery[1:1], :repl_history_search_prefix)
        end
    end
    prefix = S"{bold,$mface:▪: }"
    ncand = length(newstate.candidates)
    resultnum = S"{repl_history_search_results:[$(ncand - newstate.hover + 1)/$ncand]}"
    padspaces = newstate.area.width - sum(textwidth, (prefix, styquery, resultnum))
    suffix = if isempty(styquery)
        S"{repl_history_search_hint,shadow:try {repl_history_search_hint,(slant=normal):?} for help} "
    elseif newstate.query == FILTER_HELP_QUERY
        S"{repl_history_search_hint:help} "
    elseif kindname != ""
        S"{repl_history_search_hint:$kindname} "
    else
        S""
    end
    if textwidth(suffix) < padspaces
        padspaces -= textwidth(suffix)
    else
        suffix = S""
    end
    print(io, prefix, styquery, ' '^padspaces, suffix, resultnum)
end

const LIST_MARKERS = (
    selected = AnnotatedChar('⬤', [(:face, :repl_history_search_selected)]),
    unselected = AnnotatedChar('∘', [(:face, :repl_history_search_unselected)]),
    pending = AnnotatedChar('⁃', [(:face, :shadow)]),
)

hovidx(state::SelectorState) = length(state.candidates) - state.hover + 1
ishover(state::SelectorState, idx::Int) = idx == hovidx(state)

function gethover(state::SelectorState)
    idx = hovidx(state)
    if idx ∈ axes(state.candidates, 1)
        state.candidates[idx]
    end
end

function redisplay_candidates(io::IO, oldstate::SelectorState, oldrows::Int, newstate::SelectorState, newrows::Int)
    thisline = 1
    oldoffset = max(0, length(oldstate.candidates) - oldrows - oldstate.scroll)
    newoffset = max(0, length(newstate.candidates) - newrows - newstate.scroll)
    oldcands = @view oldstate.candidates[max(begin, begin + oldoffset):min(end, begin + oldoffset + newrows - 1)]
    newcands = @view newstate.candidates[max(begin, begin + newoffset):min(end, begin + newoffset + newrows - 1)]
    for (i, (old, new)) in enumerate(zip(oldcands, newcands))
        oldidx = i + oldoffset
        newidx = i + newoffset
        # I'm sorry about how awful this condition is, I did my best.
        if old == new &&
           (oldidx ∈ oldstate.selected) == (newidx ∈ newstate.selected) &&
           ishover(oldstate, oldidx) == ishover(newstate, newidx) &&
           (
               oldstate.area.width == newstate.area.width ||
               (textwidth(old.content) <= oldstate.area.width && !isnewhover)
           )
            println(io)
            thisline += 1
            continue
        end
        print_candidate(
            io,
            new,
            newstate.area.width;
            selected = newidx ∈ newstate.selected,
            hover = ishover(newstate, newidx),
        )
        thisline = i + 1
    end
    for (i, new) in enumerate(newcands)
        i <= length(oldstate.candidates) && continue
        newidx = i + newoffset
        print_candidate(
            io,
            new,
            newstate.area.width;
            selected = newidx ∈ newstate.selected,
            hover = newidx == hovidx(newstate),
        )
        thisline = i + 1
    end
    for _ = thisline:newrows
        print(io, "\e[K ", LIST_MARKERS.pending, '\n')
    end
end

function print_candidate(io::IO, cand::HistEntry, width::Int; selected::Bool, hover::Bool)
    print(io, ' ', if selected
        LIST_MARKERS.selected
    else
        LIST_MARKERS.unselected
    end, ' ')
    candstr = if cand.mode === :julia
        highlight_squashlines(cand.content, width - 4)
    else
        rtruncate(S"$(cand.content)", width - 4, LINE_ELLIPSIS)
    end
    if hover
        modehint = if cand.mode == BASE_MODE
            S""
        else
            modeface = get(MODE_FACES, cand.mode, :grey)
            S"{$modeface,light,region: ($(cand.mode))}"
        end
        candstr = rpad(candstr, width - 4 - textwidth(modehint))
        face!(candstr, :region)
        println(io, candstr, modehint)
    else
        println(io, "\e[K", candstr)
    end
end

const NEWLINE_MARKER = "↩ "
const LINE_ELLIPSIS = S"{shadow:…}"

rtruncpad(s::AbstractString, width::Int) = rpad(rtruncate(s, width, LINE_ELLIPSIS), width)

"""
    highlight_squashlines(code::String, maxwidth::Int)

Highlight the Julia `code` replacing newlines with `$NEWLINE_MARKER`.
"""
function highlight_squashlines(code::String, maxwidth::Int)
    # TODO: Clean up by using `replace` once annotations are supported.
    # Currently modelled after `Base.annotated_chartransform`
    codehl = highlight(code)
    if '\n' ∉ code
        return rtruncate(codehl, maxwidth, LINE_ELLIPSIS)
    end
    flatstr = IOBuffer()
    annots = @NamedTuple{region::UnitRange{Int}, label::Symbol, value::Any}[]
    nlannots = empty(annots)
    bytepos = firstindex(code)
    offsets = [(bytepos - 1) => 0]
    width = 0
    while true
        nlpos = findnext('\n', code, bytepos)
        isnothing(nlpos) && break
        skipstr = @view code[bytepos:thisind(code, nlpos - 1)]
        write(flatstr, skipstr)
        width += ncodeunits(skipstr)
        width > maxwidth && break
        lastws = nlpos
        while lastws < ncodeunits(code) && isspace(code[lastws])
            lastws = nextind(code, lastws)
        end
        oldnb = lastws - nlpos
        newnb = ncodeunits(NEWLINE_MARKER)
        write(flatstr, String(NEWLINE_MARKER))
        let loff = last(last(offsets))
            push!(nlannots, (nlpos+loff:nlpos+loff+ncodeunits(NEWLINE_MARKER)-1, :face, :shadow))
        end
        if newnb != oldnb
            push!(offsets, nlpos => last(last(offsets)) + newnb - oldnb)
        end
        bytepos = lastws
    end
    if bytepos < ncodeunits(code) && width < maxwidth
        write(flatstr, @view code[bytepos:end])
        bytepos = ncodeunits(code) + 1
    end
    for annot in annotations(codehl)
        start, stop = first(annot.region), last(annot.region)
        start_offset = last(offsets[findlast(<=(start) ∘ first, offsets)::Int])
        start_offset > bytepos && continue
        stop_offset = last(offsets[findlast(<=(stop) ∘ first, offsets)::Int])
        push!(annots, Base.setindex(annot, (start+start_offset):(stop+stop_offset), :region))
    end
    append!(annots, nlannots)
    rtruncate(AnnotatedString(String(take!(flatstr)), annots), maxwidth, LINE_ELLIPSIS)
end

function redisplay_preview(io::IO, oldstate::SelectorState, oldrows::Int, newstate::SelectorState, newrows::Int)
    function highlightcand(cand::HistEntry)
        if cand.mode === :julia
            highlight(cand.content)
        else
            S"$(cand.content)"
        end
    end
    bar = S"{shadow:│}"
    innerwidth = newstate.area.width - 2
    midline = '─'^innerwidth
    if oldstate.area.width != newstate.area.width ||
       (oldstate.area.height - oldrows) != (newstate.area.height - newrows)
        println(io, S"{shadow:╭$(midline)╮}")
    else
        println(io)
    end
    selection_lines = [1 + count('\n', newstate.candidates[i].content) for i in newstate.selected]
    # Look at how many of the candidates to be shown are the same
    # across the old and new states, looking from the start and end
    # of the selected candidates.
    lastunchanged = 0
    if oldrows == newrows
        for (old, new) in zip(oldstate.selected, newstate.selected)
            if oldstate.candidates[old] == newstate.candidates[new] && ishover(oldstate, old) == ishover(newstate, new)
                lastunchanged += 1
            else
                break
            end
        end
    end
    lastchanged = length(newstate.selected)
    for (old, new) in zip(Iterators.reverse(oldstate.selected), Iterators.reverse(newstate.selected))
        if oldstate.candidates[old] == newstate.candidates[new] && ishover(oldstate, old) == ishover(newstate, new)
            lastchanged -= 1
        else
            break
        end
    end
    slines = sum(selection_lines)
    if newrows - 2 < 1
        # Well, this is awkward.
    elseif isempty(newstate.selected) && gethover(newstate) != gethover(oldstate)
        linesprinted = 0
        hovcand = gethover(newstate)
        if !isnothing(hovcand)
            hovcontent = highlightcand(hovcand)
            hovlines = 1 + count('\n', hovcontent)
            for line in eachsplit(hovcontent, '\n')
                hline = rtruncpad(S"{light:$line}", innerwidth - 2)
                println(io, bar, ' ', hline, ' ', bar)
                linesprinted += 1
                linesprinted == newrows - 2 - (hovlines > newrows - 2) && break
            end
            if hovlines > newrows - 2
                println(
                    io,
                    bar,
                    ' ',
                    rtruncpad(S"{julia_comment:⋮ {italic:$(hovlines - newrows + 2) lines hidden}}", innerwidth - 2),
                    ' ',
                    bar,
                )
                linesprinted += 1
            end
        end
        for _ = linesprinted:(newrows-3)
            println(io, bar, ' '^innerwidth, bar)
        end
    elseif slines <= newrows - 2
        for (i, sel) in enumerate(newstate.selected)
            if i <= lastunchanged
                print(io, '\n'^selection_lines[i])
                continue
            end
            codehl = highlightcand(newstate.candidates[sel])
            for line in eachsplit(codehl, '\n')
                line = rtruncpad(line, innerwidth - 2)
                ishover(newstate, sel) && face!(line, :region)
                println(io, bar, ' ', line, ' ', bar)
            end
        end
        for _ = slines:(newrows-3)
            println(io, bar, ' '^innerwidth, bar)
        end
    else
        nlinesabove = (newrows - 3) ÷ 2
        nlinesbelow = newrows - 3 - nlinesabove
        printedabove = 0
        for (i, sel) in enumerate(newstate.selected)
            if i <= lastunchanged
                nlclamp = min(selection_lines[i], nlinesabove - printedabove)
                print(io, '\n'^nlclamp)
                printedabove += nlclamp
                continue
            end
            codehl = highlightcand(newstate.candidates[sel])
            for line in eachsplit(codehl, '\n')
                printedabove >= nlinesabove && break
                ishover(newstate, sel) && face!(line, :region)
                println(io, bar, ' ', rtruncpad(line, innerwidth - 2), ' ', bar)
                printedabove += 1
            end
        end
        println(
            io,
            bar,
            ' ',
            rtruncpad(S"{julia_comment:⋮ {italic:$(slines - newrows + 3) lines hidden}}", innerwidth - 2),
            ' ',
            bar,
        )
        linesbelow = SubString{AnnotatedString{String}}[]
        for (i, sel) in enumerate(Iterators.reverse(newstate.selected))
            idx = length(newstate.selected) - i + 1
            if idx > lastchanged
                nlclamp = min(selection_lines[idx], nlinesbelow - length(linesbelow))
                for _ = 1:nlclamp
                    push!(linesbelow, SubString(S""))
                end
                continue
            end
            codehl = highlight(newstate.candidates[sel].content)
            lines = split(codehl, '\n')
            for line in Iterators.reverse(lines)
                length(linesbelow) >= nlinesbelow && break
                ishover(newstate, sel) && face!(line, :region)
                push!(linesbelow, rtruncpad(line, innerwidth - 2))
            end
        end
        for line in Iterators.reverse(linesbelow)
            if isempty(line)
                println(io)
            else
                println(io, bar, ' ', line, ' ', bar)
            end
        end
    end
    if oldstate.area.width != newstate.area.width || oldstate.area.height != newstate.area.height
        print(io, S"{shadow:╰$(midline)╯}")
    end
end
