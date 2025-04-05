function runsearch!()
    histfile = update!(HISTORY[])
    events = Channel{Symbol}(Inf)
    pspec = create_prompt(events)
    ptask = @spawn runprompt!(pspec, events)
    dtask = @spawn run_display!(pspec, events, histfile.records)
    wait(ptask)
    fetch(dtask)
end

# const THROTTLE_TIME = 0.05
# const DEBOUNCE_TIME = 0.1

function run_display!((; term, pstate), events::Channel{Symbol}, hist::Vector{HistEntry})
    # Output-related variables
    out = term.out_stream
    outsize = displaysize(out)
    buf = IOContext(IOBuffer(), out)
    # Main state variables
    state = SelectorState(outsize, "", hist, 0, [], 1)
    redisplay_all(out, EMPTY_STATE, state, pstate; buf)
    # Candidate cache
    cands_cache = Pair{ConditionSet{String}, Vector{HistEntry}}[]
    cands_cachestate = zero(UInt8)
    cands_current = HistEntry[]
    cands_cond = ConditionSet{String}()
    cands_temp = HistEntry[]
    # Filter state
    filter_idx = 0
    filter_spec = FilterSpec([], [], [], [])
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
        elseif event ∈ (:uparrow, :downarrow, :pageup, :pagedown)
            prevstate, state = state, movehover(state, event ∈ (:uparrow, :pageup), event ∈ (:pageup, :pagedown))
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :tab
            prevstate, state = state, toggleselection(state)
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        elseif event === :edit
            query = REPL.LineEdit.input_string(pstate)
            if query === state.query
                redisplay_all(out, state, state, pstate; buf)
                continue
            end
            prevstate, state = state, SelectorState(
                outsize, query, [], 0, [], 1)
            if query == FILTER_HELP_QUERY
                redisplay_all(out, prevstate, state, pstate; buf)
                continue
            end
            cands_cond = ConditionSet(query)
            cands_current = hist
            for (cond, cands) in cands_cache
                if ismorestrict(cands_cond, cond)
                    cands_current = cands
                    break
                end
            end
            filter_spec = FilterSpec(cands_cond)
            filter_idx = filterchunkrev!(
                state.candidates, cands_current, filter_spec;
                maxtime = time() + 0.01,
                maxresults = outsize[1] ÷ 2)
            if filter_idx == 0
                cands_cachestate = addcache!(
                    cands_cache, cands_cachestate, cands_cond => state.candidates)
            end
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        else
            error("Unknown event: $event")
        end
        if displaysize(out) != outsize
            outsize = displaysize(out)
            prevstate, state = state, SelectorState(
                outsize, state.query, state.candidates,
                state.scroll, state.selected, state.hover)
            redisplay_all(out, prevstate, state, pstate; buf)
            continue
        end
        if filter_idx != 0
            maxtime = time() + 0.01
            append!(empty!(cands_temp), state.candidates)
            prevstate = SelectorState(
                state.area, state.query, cands_temp, state.scroll,
                state.selected, state.hover)
            filter_idx = filterchunkrev!(
                state.candidates, cands_current, filter_spec, filter_idx;
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
    newhover = clamp(state.hover + shift, 1, length(state.candidates))
    newscroll = clamp(state.scroll, newhover - candrows, newhover - 1)
    SelectorState(
        state.area, state.query, state.candidates,
        newscroll, state.selected, newhover)
end

"""
    toggleselection(state::SelectorState)

Vary the selection of the current candidate (selected by hover) in `state`.
"""
function toggleselection(state::SelectorState)
    hoveridx = length(state.candidates) - state.hover + 1
    hoveridx ∈ axes(state.candidates, 1) || return state
    newselection = copy(state.selected)
    selsearch = searchsorted(newselection, hoveridx)
    if isempty(selsearch)
        insert!(newselection, first(selsearch), hoveridx)
    else
        deleteat!(newselection, first(selsearch))
    end
    newstate = SelectorState(
        state.area, state.query, state.candidates,
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
