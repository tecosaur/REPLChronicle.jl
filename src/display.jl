struct SelectorState
    area::@NamedTuple{height::Int, width::Int}
    query::String
    candidates::Vector{HistEntry}
    scroll::Int
    selection::@NamedTuple{active::Vector{Int}, gathered::Vector{HistEntry}}
    hover::Int
end

SelectorState((height, width), query::String, candidates::Vector{HistEntry} = HistEntry[], gathered::Vector{HistEntry} = HistEntry[]) =
    SelectorState((height, width), query, candidates, -length(gathered),
                  (; active = Int[], gathered), 1)

const EMPTY_STATE = SelectorState((0, 0), "", [], 0, (active = Int[], gathered = HistEntry[]), 0)

STATES = Pair{SelectorState, SelectorState}[]

Base.copy(s::SelectorState) =
    SelectorState(s.area, s.query, copy(s.candidates), s.scroll, copy(s.selection.active), s.hover)

const LABELS = (
    gatherdivider = S"{italic:carried over}",
    preview_suggestion = S"Ctrl+S to save",
    help_prompt = S"{repl_history_search_hint,shadow:try {repl_history_search_hint,(slant=normal):?} for help} ",
)

function redisplay_all(io::IO, oldstate::SelectorState, newstate::SelectorState, pstate::REPL.LineEdit.PromptState;
                       buf::IOContext{IOBuffer} = IOContext(IOBuffer(), io))
    # Calculate dimensions
    oldrows = componentrows(oldstate)
    newrows = componentrows(newstate)
    # Redisplay components
    println(buf, "\eP=1s\e\\") # Start sync update, move to line under prompt
    currentrow = 1
    if newstate.query == FILTER_HELP_QUERY
        print(buf, "\e[1G\e[J", FILTER_HELPSTRING)
        currentrow += 1 + count('\n', String(FILTER_HELPSTRING))
    else
        if oldstate.area.width > newstate.area.width || oldstate.query == FILTER_HELP_QUERY
            print(buf, "\e[1G\e[J")
            oldstate = EMPTY_STATE
        end
        if oldstate.candidates != newstate.candidates ||
            oldstate.area.width != newstate.area.width ||
            oldstate.scroll != newstate.scroll ||
            oldstate.selection != newstate.selection ||
            oldstate.hover != newstate.hover
            redisplay_candidates(buf, oldstate, oldrows.candidates, newstate, newrows.candidates)
            currentrow += newrows.candidates
        end
        if (@view oldstate.candidates[oldstate.selection.active]) != (@view newstate.candidates[newstate.selection.active]) ||
            oldstate.selection.gathered != newstate.selection.gathered ||
            gethover(oldstate) != gethover(newstate) ||
            oldstate.area.width != newstate.area.width
            redisplay_preview(buf, oldstate, oldrows.preview, newstate, newrows.preview)
            currentrow += max(0, newrows.preview - 1)
        end
    end
    # Restore row pos
    print(buf, "\e[", currentrow, "A\e[1G")
    redisplay_prompt(buf, oldstate, newstate, pstate)
    # Restore column pos
    print(buf, "\e[", textwidth(PROMPT_TEXT) + position(pstate.input_buffer) + 1, 'G')
    print(buf, "\eP=2s\e\\") # End sync update
    write(io, seekstart(buf.io))
    truncate(buf.io, 0)
    flush(io)
end

function componentrows(state::SelectorState)
    availible_rows = 2 * (state.area.height - 1) ÷ 3 # REVIEW: maybe `min(height, ?)`
    preview_min, preview_max = availible_rows ÷ 3, 2 * availible_rows ÷ 3
    nlines_preview = countlines_selected(state)
    preview_rows = clamp(nlines_preview, preview_min, preview_max)
    if preview_min <= 2
        preview_rows = 0 # Not worth just showing the frame
    end
    candidate_rows = availible_rows - preview_rows
    (; candidates = candidate_rows, preview = preview_rows)
end

function countlines_selected((; candidates, selection)::SelectorState)
    (; active, gathered) = selection
    nlines = 0
    for idx in active
        entry = candidates[idx]
        nlines += 1 + count('\n', entry.content)
    end
    if !isempty(gathered)
        nlines += 1 # The divider line
        for entry in gathered
            nlines += 1 + count('\n', entry.content)
        end
    end
    nlines
end

const BASE_MODE = :julia

const MODE_FACES = Dict(
    :julia => :green,
    :shell => :red,
    :pkg => :blue,
    :help => :yellow,
)

function redisplay_prompt(io::IO, oldstate::SelectorState, newstate::SelectorState, pstate::REPL.LineEdit.PromptState)
    # oldstate.query == newstate.query && return
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
    for (name, substrs) in (("words", styconds.words),
                            ("exact", styconds.exacts),
                            ("negative", styconds.negatives),
                            ("initialism", styconds.initialisms),
                            ("regexp", styconds.regexps),
                            ("fuzzy", styconds.fuzzy),
                            ("mode", styconds.modes))
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
                face!(styquery[start:start],
                      if query[start] == FILTER_SEPARATOR
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
        LABELS.help_prompt
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
    print(io, prefix, styquery, ' ' ^ max(0, padspaces), suffix, resultnum)
end

# Circles:
# - large: ● ○
# - medium: ⏺🞉🞈🞇🞆🞅⚬🞊⦿⦾
# - small: •⋅∙∘◦
# - dots: 🞄⁃
const LIST_MARKERS = (
    selected = AnnotatedChar('⬤', [(:face, :repl_history_search_selected)]),
    hover = AnnotatedChar('🞇', [(:face, :repl_history_search_selected)]),
    unselected = AnnotatedChar('◦', [(:face, :repl_history_search_unselected)]),
    pending = AnnotatedChar('🞄', [(:face, :shadow)]),
)

function hoveridx(state::SelectorState)
    if state.hover > 0
        length(state.candidates) - state.hover + 1
    else
        state.hover
    end
end

ishover(state::SelectorState, idx::Int) = idx == hoveridx(state)

function gethover(state::SelectorState)
    idx = hoveridx(state)
    if idx ∈ axes(state.candidates, 1)
        state.candidates[idx]
    elseif idx < 0 && -idx ∈ axes(state.selection.gathered, 1)
        state.selection.gathered[-idx]
    end
end

struct CandsState{V<:AbstractVector{HistEntry}}
    entries::V
    selected::Vector{Int}
    hover::Int
    rows::Int
    width::Int
end

function candidates(state::SelectorState, rows::Int)
    gathcount = clamp(-state.scroll, 0, length(state.selection.gathered))
    actcount = rows - gathcount - sign(gathcount)
    offset = max(0, length(state.candidates) - actcount - max(0, state.scroll))
    candend = offset + actcount
    actcands = @view state.candidates[max(begin, begin+offset):min(end, candend)]
    actempty = actcount - length(actcands)
    actsel = Int[idx - offset for idx in state.selection.active]
    if !isempty(state.selection.gathered)
        append!(actsel, filter!(!isnothing, indexin(state.selection.gathered, actcands)))
    end
    active = CandsState(
        actcands,
        actsel,
        rows + state.scroll - state.hover - actempty + (state.scroll >= 0),
        actcount,
        state.area.width)
    gathcands = @view state.selection.gathered[begin:min(end, gathcount)]
    gathered = CandsState(
        gathcands,
        collect(axes(gathcands, 1)),
        -state.hover,
        gathcount,
        state.area.width)
    (; active, gathered)
end

function redisplay_candidates(io::IO, oldstate::SelectorState, oldrows::Int, newstate::SelectorState, newrows::Int)
    danglingdivider = false
    if oldstate.scroll < 0 && newstate.scroll == 0
        newrows -= 1
        danglingdivider = true
    end
    oldcands = candidates(oldstate, oldrows)
    newcands = candidates(newstate, newrows)
    # Redisplay active candidates
    update_candidates(io, oldcands.active, newcands.active,
                      oldstate.scroll == 0 && !isempty(oldstate.selection.gathered))
    # Redisplay gathered candidates
    gathshift = (oldrows - length(oldcands.gathered.entries)) - (newrows - length(newcands.gathered.entries))
    if isempty(newcands.gathered.entries) && !danglingdivider
    elseif gathshift != 0 || danglingdivider || oldstate.area != newstate.area
        netlines = newstate.area.width - textwidth(LABELS.gatherdivider) - 6
        leftlines = netlines ÷ 2
        rightlines = netlines - leftlines
        println(io, S" {shadow:╶$('─' ^ leftlines)╴$(LABELS.gatherdivider)╶$('─' ^ rightlines)╴} ")
    else
        println(io)
    end
    update_candidates(io, oldcands.gathered, newcands.gathered, gathshift != 0)
end

"""
    update_candidates(io::IO, oldcands::CandsState, newcands::CandsState)

Write an update to `io` that changes the display from `oldcands` to `newcands`.

Only changes are printed, and exactly `length(newcands.entries)` lines are printed.
"""
function update_candidates(io::IO, oldcands::CandsState, newcands::CandsState, force::Bool = false)
    thisline = 1
    for (i, (old, new)) in enumerate(zip(oldcands.entries, newcands.entries))
        oldsel, newsel = i ∈ oldcands.selected, i ∈ newcands.selected
        oldhov, newhov = i == oldcands.hover, i == newcands.hover
        if !force && old == new && oldsel == newsel && oldhov == newhov && oldcands.width == newcands.width
            println(io)
        else
            print_candidate(io, new, newcands.width;
                            selected = newsel, hover = newhov)
        end
        thisline = i + 1
    end
    for (i, new) in enumerate(newcands.entries)
        i <= length(oldcands.entries) && continue
        print_candidate(io, new, newcands.width;
                        selected = i ∈ newcands.selected,
                        hover = i == newcands.hover)
        thisline = i + 1
    end
    for _ in thisline:newcands.rows
        print(io, "\e[K ", LIST_MARKERS.pending, '\n')
    end
end

const DURATIONS = (
    m = 60,
    h = 60 * 60,
    d = 24 * 60 * 60,
    w = 7 * 24 * 60 * 60,
    y = 365 * 24 * 60 * 60,
)

function humanage(seconds::Integer)
    unit, count = :s, seconds
    for (dunit, dsecs) in pairs(DURATIONS)
        n = seconds ÷ dsecs
        n == 0 && break
        unit, count = dunit, n
    end
    "$count$unit"
end

function print_candidate(io::IO, cand::HistEntry, width::Int; selected::Bool, hover::Bool)
    print(io, ' ', if selected
              LIST_MARKERS.selected
          elseif hover
              LIST_MARKERS.hover
          else
              LIST_MARKERS.unselected
          end, ' ')
    age = humanage(floor(Int, ((now() - cand.date)::Millisecond).value ÷ 1000))
    agedec = S" {shadow,light,italic:$age}"
    candstr = highlightcand(cand)
    modehint = if cand.mode ==BASE_MODE
        S""
    else
        modeface = get(MODE_FACES, cand.mode, :grey)
        if hover
            S"{region: {bold,inverse,$modeface: $(cand.mode) }}"
        elseif ncodeunits(age) == 2
            S" {$modeface:◼}  "
        else
            S" {$modeface:◼} "
        end
    end
    decorationlen = 4 + textwidth(modehint) + textwidth(agedec)
    candflat = rtruncate(ann_replace(candstr, r"\r?\n\s*" => NEWLINE_MARKER), width - decorationlen, LINE_ELLIPSIS)
    if hover
        candflat = rpad(candflat, width - decorationlen)
        face!(candflat, :region)
        face!(agedec, :region)
        println(io, candflat, modehint, agedec, ' ')
    else
        println(io, rpad(candflat, width - decorationlen), modehint, agedec, ' ')
    end
end

function highlightcand(cand::HistEntry)
    if cand.mode === :julia
        highlight(cand.content)
    else
        S"$(cand.content)"
    end
end

const NEWLINE_MARKER = S"{shadow:↩ }"
const LINE_ELLIPSIS = S"{shadow:…}"

# TODO: It would be nice to 'upstream' a more general version of this
function ann_replace(base::AnnotatedString{String}, (pattern, replacement)::Pair{<:Union{<:AbstractChar, <:AbstractString, Regex}, AnnotatedString{String}})
    # Modelled after `Base.annotated_chartransform`
    flatstr = IOBuffer()
    annots = @NamedTuple{region::UnitRange{Int}, label::Symbol, value::Any}[]
    matchannots = empty(annots)
    bytepos = firstindex(base)
    replacements = [(pos = bytepos - 1, offset = 0, bytes = 0)]
    while true
        matchpos, matchbytes = if pattern isa AbstractString || pattern isa Char
            pos = findnext(pattern, base, bytepos)
            isnothing(pos) && break
            pos, ncodeunits(pattern)
        elseif pattern isa Regex
            m = match(pattern, base, bytepos)
            isnothing(m) && break
            m.offset, m.match.ncodeunits
        else
            error("Unreachable!?")
        end
        write(flatstr, @view base[bytepos:thisind(base, matchpos-1)])
        write(flatstr, String(replacement))
        destpos = matchpos + last(replacements).offset
        for ann in annotations(replacement)
            shift = destpos - first(ann.region)
            shiftann = (region = (first(ann.region) + shift):(last(ann.region) + shift),
                        label = ann.label, value = ann.value)
            push!(matchannots, shiftann)
        end
        push!(replacements,
              (pos = matchpos,
               offset = last(replacements).offset + ncodeunits(replacement) - matchbytes,
               bytes = ncodeunits(replacement)))
        bytepos = matchpos + matchbytes
    end
    bytepos == firstindex(base) && return base
    if bytepos < ncodeunits(base)
        write(flatstr, @view base[bytepos:end])
        bytepos = ncodeunits(base) + 1
    end
    push!(replacements, (pos = bytepos, offset = 0, bytes = 0))
    for annot in annotations(base)
        # FIXME: This isn't /quite/ right yet
        start, stop = first(annot.region), last(annot.region)
        prioridx = searchsortedlast(replacements, (pos = start, offset = 0, bytes = 0), by = x -> x.pos, lt = <=)
        postidx = searchsortedlast(replacements, (pos = stop, offset = 0, bytes = 0), by = x -> x.pos, lt = <=)
        priorrep, postrep = replacements[prioridx], replacements[postidx]
        if prioridx == postidx && start >= priorrep.pos && stop <= (priorrep.pos + priorrep.bytes)
            continue
        elseif true # start > (priorrep.pos + priorrep.bytes) && stop < postrep.pos
            shiftregion = (start + priorrep.offset):(stop + postrep.offset)
            shiftann = (region = shiftregion, label = annot.label, value = annot.value)
            push!(annots, shiftann)
        else
            # Bah humbug, we need to split up the annotation
            # allowing for any number of overlapping replacements.
            # @show (start:stop, priorrep, postrep)
        end
    end
    append!(annots, matchannots)
    AnnotatedString(String(take!(flatstr)), annots)
end


function redisplay_preview(io::IO, oldstate::SelectorState, oldrows::Int, newstate::SelectorState, newrows::Int)
    newrows == 0 && return
    function getcand(state::SelectorState, idx::Int)
        if idx ∈ axes(state.candidates, 1)
            state.candidates[idx]
        elseif -idx ∈ axes(state.selection.gathered, 1)
            state.selection.gathered[-idx]
        else
            throw(ArgumentError("Invalid candidate index: $idx")) # Should never happen
        end
    end
    function getselidxs(state::SelectorState)
        idxs = collect(-1:-1:-length(state.selection.gathered))
        append!(idxs, state.selection.active)
        sort!(idxs, by = i -> getcand(state, i).index)
    end
    rtruncpad(s::AbstractString, width::Int) =
        rpad(rtruncate(s, width, LINE_ELLIPSIS), width)
    bar = S"{shadow:│}"
    innerwidth = newstate.area.width - 2
    if oldstate.area.width != newstate.area.width || (oldstate.area.height - oldrows) != (newstate.area.height - newrows)
        println(io, S"{shadow:╭$('─' ^ innerwidth)╮}")
    else
        println(io)
    end
    if newrows - 2 < 1
        # Well, this is awkward.
    elseif isempty(newstate.selection.active) &&
        isempty(newstate.selection.gathered) &&
        (gethover(newstate) != gethover(oldstate) ||
         oldstate.area != newstate.area)
        hovcand = gethover(newstate)
        linesprinted = if !isnothing(hovcand)
            hovcontent = highlightcand(hovcand)
            face!(hovcontent, :light)
            boxedcontent(io, hovcontent, newstate.area.width, newrows - 2)
        else
            0
        end
        for _ in (linesprinted + 1):(newrows - 2)
            println(io, bar, ' '^innerwidth, bar)
        end
    else
        linesprinted = 0
        seltexts = AnnotatedString{String}[]
        for idx in getselidxs(newstate)
            entry = getcand(newstate, idx)
            content = highlightcand(entry)
            ishover(newstate, idx) && face!(content, :region)
            push!(seltexts, content)
        end
        linecount = sum(t -> 1 + count('\n', String(t)), seltexts, init=0)
        for (i, content) in enumerate(seltexts)
            clines = 1 + count('\n', String(content))
            if linesprinted + clines < newrows - 2 || (i == length(seltexts) && linesprinted + clines == newrows - 2)
                for line in eachsplit(content, '\n')
                    println(io, bar, ' ', rtruncpad(line, innerwidth - 2), ' ', bar)
                end
                linesprinted += clines
            else
                remaininglines = newrows - 2 - linesprinted
                for (i, line) in enumerate(eachsplit(content, '\n'))
                    i == remaininglines && break
                    println(io, bar, ' ', rtruncpad(line, innerwidth - 2), ' ', bar)
                end
                msg = S"{julia_comment:⋮ {italic:$(linecount - newrows + 3) lines hidden}}"
                println(io, bar, ' ', rtruncpad(msg, innerwidth - 2), ' ', bar)
                linesprinted += remaininglines
                break
            end
        end
        for _ in (linesprinted + 1):(newrows - 2)
            println(io, bar, ' ' ^ innerwidth, bar)
        end
    end
    if oldstate.area != newstate.area || length(oldstate.selection.active) != length(newstate.selection.active)
        if textwidth(LABELS.preview_suggestion) < innerwidth
            line = '─' ^ (innerwidth - textwidth(LABELS.preview_suggestion) - 2)
            print(io, S"{shadow:╰$(line)╴$(LABELS.preview_suggestion)╶╯}")
        else
            print(io, S"{shadow:╰$('─' ^ innerwidth)╯}")
        end
    end
end

function boxedcontent(io::IO, content::AnnotatedString{String}, width::Int, maxlines::Int)
    function breaklines(content::AnnotatedString{String}, maxwidth::Int)
        textwidth(content) <= maxwidth && return [content]
        spans = AnnotatedString{String}[]
        basestr = String(content) # Because of expensive char iteration
        start, pos, linewidth = 1, 0, 0
        for char in basestr
            linewidth += textwidth(char)
            pos = nextind(basestr, pos)
            if linewidth > maxwidth
                spans = push!(spans, AnnotatedString(content[start:prevind(basestr, pos)]))
                start = pos
                linewidth = textwidth(char)
            end
        end
        if start <= length(basestr)
            spans = push!(spans, AnnotatedString(content[start:end]))
        end
        spans
    end
    left, right = S"{shadow:│} ", S" {shadow:│}"
    leftcont, rightcont = S"{shadow:┊▸}", S"{shadow:◂┊}"
    if maxlines == 1
        println(io, left,
                rpad(rtruncate(content, width - 4, LINE_ELLIPSIS), width - 4),
                right)
        return 1
    end
    printedlines = 0
    if ncodeunits(content) > (width * maxlines)
        content = AnnotatedString(rtruncate(content, width * maxlines, ' '))
    end
    lines = split(content, '\n')
    innerwidth = width - 4
    for (i, line) in enumerate(lines)
        printedlines >= maxlines && break
        if textwidth(line) <= innerwidth
            println(io, left, rpad(line, innerwidth), right)
            printedlines += 1
            continue
        end
        plainline = String(line)
        indent, ichars = 0, 1
        while isspace(plainline[ichars])
            indent += textwidth(plainline[ichars])
            ichars = nextind(plainline, ichars)
        end
        line = @view line[ichars:end]
        spans = breaklines(AnnotatedString(line), innerwidth - 2 - indent)
        for (i, span) in enumerate(spans)
            prefix, suffix = if i == 1
                S"", S"$LINE_ELLIPSIS "
            elseif i == length(spans)
                S"$LINE_ELLIPSIS", S" "
            else
                LINE_ELLIPSIS, LINE_ELLIPSIS
            end
            printedlines += 1
            println(io, ifelse(i == 1, left, leftcont), ' ' ^ indent,
                    prefix, rpad(span, innerwidth - 2 - indent), suffix,
                    ifelse(i == length(spans) || printedlines == maxlines,
                           right, rightcont))
            printedlines >= maxlines && break
        end
    end
    printedlines
end
