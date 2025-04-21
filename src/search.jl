function runsearch!()
    histfile = update!(HISTORY)
    events = Channel{Symbol}(Inf)
    pspec = create_prompt(events)
    ptask = @spawn runprompt!(pspec, events)
    dtask = @spawn run_display!(pspec, events, histfile.records)
    wait(ptask)
    fetch(dtask)
end

function fullselection(state::SelectorState)
    text = IOBuffer()
    entries = copy(state.selection.gathered)
    for act in state.selection.active
        push!(entries, state.candidates[act])
    end
    if isempty(entries) && state.hover ∈ axes(state.candidates, 1)
        push!(entries, state.candidates[end-state.hover+1])
    end
    sort!(entries, by = e -> e.index)
    mainmode = if !isempty(entries) first(entries).mode end
    join(text, Iterators.map(e -> e.content, entries), '\n')
    (mode = mainmode, text = String(take!(text)))
end

# const THROTTLE_TIME = 0.05
# const DEBOUNCE_TIME = 0.1

function run_display!((; term, pstate), events::Channel{Symbol}, hist::Vector{HistEntry})
    # Output-related variables
    out = term.out_stream
    outsize = displaysize(out)
    buf = IOContext(IOBuffer(), out)
    # Main state variables
    state = SelectorState(outsize, "", FilterSpec(), hist)
    redisplay_all(out, EMPTY_STATE, state, pstate; buf)
    # Candidate cache
    cands_cache = Pair{ConditionSet{String}, Vector{HistEntry}}[]
    cands_cachestate = zero(UInt8)
    cands_current = HistEntry[]
    cands_cond = ConditionSet{String}()
    cands_temp = HistEntry[]
    # Filter state
    filter_idx = 0
    # Event loop
    while true
        event = @lock events if !isempty(events) take!(events) end
        if isnothing(event)
        elseif event === :abort
            print(out, "\e[1G\e[J")
            return EMPTY_STATE
        elseif event === :confirm
            print(out, "\e[1G\e[J")
            return state
        elseif event === :clear
            print(out, "\e[H\e[2J")
            redisplay_all(out, EMPTY_STATE, state, pstate; buf)
            continue
        elseif event ∈ (:uparrow, :downarrow, :pageup, :pagedown)
            prevstate, state = state, movehover(state, event ∈ (:uparrow, :pageup), event ∈ (:pageup, :pagedown))
            @lock events begin
                nextevent = if !isempty(events) first(events.data) end
                while nextevent ∈ (:uparrow, :downarrow, :pageup, :pagedown)
                    take!(events)
                    state = movehover(state, nextevent ∈ (:uparrow, :pageup), event ∈ (:pageup, :pagedown))
                    nextevent = if !isempty(events) first(events.data) end
                end
            end
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :jumpfirst
            prevstate = state
            state = SelectorState(
                state.area, state.query, state.filter, state.candidates,
                length(state.candidates) - componentrows(state).candidates,
                state.selection, length(state.candidates))
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :jumplast
            prevstate = state
            state = SelectorState(
                state.area, state.query, state.filter, state.candidates,
                0, state.selection, 1)
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :tab
            prevstate, state = state, toggleselection(state)
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :edit
            @lock events begin
                while !isempty(events) && first(events.data) === :edit
                    take!(events)
                end
            end
            query = REPL.LineEdit.input_string(pstate)
            if query === state.query
                redisplay_all(out, state, state, pstate; buf)
                continue
            end
            # Determine the conditions/filter spec
            cands_cond = ConditionSet(query)
            filter_spec = FilterSpec(cands_cond)
            # Construct a provisional new state
            prevstate, state = state, SelectorState(
                outsize, query, filter_spec, HistEntry[], state.selection.gathered)
            # Gather selected candidates
            if !isempty(prevstate.selection.active)
                for act in prevstate.selection.active
                    push!(state.selection.gathered, prevstate.candidates[act])
                end
                sort!(state.selection.gathered, by = e -> e.index)
                state = SelectorState(
                    state.area, state.query, state.filter, state.candidates,
                    -min(length(state.selection.gathered), state.area.height ÷ 8),
                    state.selection, 1)
            end
            # Show help?
            if query == FILTER_HELP_QUERY
                redisplay_all(out, prevstate, state, pstate; buf)
                continue
            end
            # Parse the conditions and find a good candidate list
            cands_current = hist
            for (cond, cands) in Iterators.reverse(cands_cache)
                if ismorestrict(cands_cond, cond)
                    cands_current = cands
                    break
                end
            end
            # Start filtering candidates
            filter_idx = filterchunkrev!(
                state.candidates, cands_current, state.filter;
                maxtime = time() + 0.01,
                maxresults = outsize[1] ÷ 2)
            if filter_idx == 0
                cands_cachestate = addcache!(
                    cands_cache, cands_cachestate, cands_cond => state.candidates)
            end
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :save
            print(out, "\e[1G\e[J")
            content = fullselection(state).text
            isempty(content) && return EMPTY_STATE
            print(out, S"{bold,emphasis:File: }")
            filename = readline()
            write(filename, "# Julia REPL history excerpt\n\n", content)
            nlines = 1 + count('\n', content)
            println(out, S"\e[F\e[2K{shadow:{bold:history>} Wrote $nlines selected \
                           $(ifelse(nlines == 1, \"line\", \"lines\")) to {underline:$(abspath(filename))}}\n")
            return EMPTY_STATE
        else
            error("Unknown event: $event")
        end
        if displaysize(out) != outsize
            outsize = displaysize(out)
            prevstate, state = state, SelectorState(
                outsize, state.query, state.filter, state.candidates,
                state.scroll, state.selection, state.hover)
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        end
        if filter_idx != 0
            maxtime = time() + 0.01
            append!(empty!(cands_temp), state.candidates)
            prevstate = SelectorState(
                state.area, state.query, state.filter, cands_temp,
                state.scroll, state.selection, state.hover)
            filter_idx = filterchunkrev!(
                state.candidates, cands_current, state.filter, filter_idx;
                maxtime = time() + 0.01)
            if filter_idx == 0
                cands_cachestate = addcache!(
                    cands_cache, cands_cachestate, cands_cond => state.candidates)
            end
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        end
        if isnothing(event)
            yield()
            sleep(0.01)
        end
    end
end

"""
    movehover(state::SelectorState, backwards::Bool, page::Bool)

Move the hover cursor in `state` by one row or one page.

The direction and size of the move is determined by `backwards` and `page`.
"""
function movehover(state::SelectorState, backwards::Bool, page::Bool)
    candrows = componentrows(state).candidates
    shift = ifelse(backwards, 1, -1) * ifelse(page, max(1, candrows - 1), 1)
    # We need to adjust for the existence of the gathered selection,
    # and the division line depending on whether it will still be
    # visible after the move.
    if !isempty(state.selection.gathered) && state.scroll < 0 &&
        state.hover + shift + state.scroll <= candrows
        candrows -= 1
        shift -= page
    end
    if page && state.scroll < 0 && state.hover < shift
        shift -= min(-state.scroll, length(state.selection.gathered)) - 2 * (state.hover == -1)
    end
    ngathered = length(state.selection.gathered)
    newhover = state.hover + shift
    # This looks a little funky because we want to produce a particular
    # behaviour when crossing between the active and gathered selection, namely
    # we want to ensure it always takes an explicit step to go from one section
    # to another and skip over 0 as an invalid position.
    newhover = if sign(newhover) == sign(state.hover) || (abs(state.hover) == 1 && newhover != 0)
        clamp(newhover, -ngathered + iszero(ngathered), length(state.candidates))
    elseif ngathered == 0
        1
    elseif newhover == 0
        -sign(state.hover)
    else
        sign(state.hover)
    end
    newscroll = clamp(state.scroll,
                      max(-ngathered, newhover - candrows),
                      newhover - (newhover >= 0))
    SelectorState(
        state.area, state.query, state.filter, state.candidates,
        newscroll, state.selection, newhover)
end

"""
    toggleselection(state::SelectorState)

Vary the selection of the current candidate (selected by hover) in `state`.
"""
function toggleselection(state::SelectorState)
    newselection = if state.hover > 0
        hoveridx = length(state.candidates) - state.hover + 1
        hoveridx ∈ axes(state.candidates, 1) || return state
        activecopy = copy(state.selection.active)
        selsearch = searchsorted(activecopy, hoveridx)
        if isempty(selsearch)
            insert!(activecopy, first(selsearch), hoveridx)
        else
            elt = activecopy[selsearch]
            gidx = findfirst(==(elt), state.selection.gathered)
            isnothing(gidx) || deleteat!(state.selection.gathered, gidx)
            deleteat!(activecopy, first(selsearch))
        end
        (active = activecopy, gathered = state.selection.gathered)
    elseif state.hover < 0
        -state.hover ∈ axes(state.selection.gathered, 1) || return state
        gatheredcopy = copy(state.selection.gathered)
        deleteat!(gatheredcopy, -state.hover)
        (active = state.selection.active, gathered = gatheredcopy)
    else
        return state
    end
    newstate = SelectorState(
        state.area, state.query, state.filter, state.candidates,
        state.scroll, newselection, state.hover)
    movehover(newstate, false, false)
end

"""
    addcache!(cache::Vector{T}, state::Unsigned, new::T)

Add `new` to the log-structured `cache` according to `state`.

The lifetime of `new` is exponentially decaying, it has a `1` in `2^(k-1)`
chance of reaching the `k`-th position in the cache.

The cache can hold as many items as the number of bits in `state` (e.g. 8 for `UInt8`).
"""
function addcache!(cache::Vector{T}, state::Unsigned, new::T) where {T}
    maxsize = sizeof(state) * 8
    nextstate = state + one(state)
    shift = state ⊻ nextstate
    uninitialised = maxsize - length(cache)
    if Base.leading_zeros(nextstate) < uninitialised
        push!(cache, new)
        return nextstate
    end
    for b in 1:(maxsize - 1)
        iszero(shift & (0x1 << (maxsize - b))) && continue
        cache[b - uninitialised] = cache[b - uninitialised + 1]
    end
    cache[end] = new
    nextstate
end
