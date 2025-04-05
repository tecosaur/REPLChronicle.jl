struct ConditionSet{S}
    words::Vector{SubString{S}}
    exacts::Vector{SubString{S}}
    negatives::Vector{SubString{S}}
    initialisms::Vector{SubString{S}}
    fuzzy::Vector{SubString{S}}
    regexps::Vector{SubString{S}}
    modes::Vector{SubString{S}}
end

ConditionSet{S}() where {S} = ConditionSet{S}([], [], [], [], [], [], [])

const FILTER_SEPARATOR = ';'
const FILTER_PREFIXES = ('!', '`', '=', '/', '~', '>')

const FILTER_HELPSTRING = S"""
 {bold,magenta:Interactive history search}

 Enter a seach term at the prompt, and see matching candidates.
 A search term that is {italic:just} '{repl_history_search_prefix:?}' brings up this help page.

 Different search modes are availble via prefixes, as follows:
 {emphasis:•} {repl_history_search_prefix:=} looks for exact matches
 {emphasis:•} {repl_history_search_prefix:!} {italic:excludes} exact matches
 {emphasis:•} {repl_history_search_prefix:/} performs a regexp search
 {emphasis:•} {repl_history_search_prefix:~} looks for fuzzy matches
 {emphasis:•} {repl_history_search_prefix:>} looks for a particular REPL mode
 {emphasis:•} {repl_history_search_prefix:`} looks for an initialism

 You can also combine multiple search modes with the \
seperator '{repl_history_search_seperator:$FILTER_SEPARATOR}',
 for example, {region:{repl_history_search_prefix:^}foo{repl_history_search_seperator:$FILTER_SEPARATOR}\
{repl_history_search_prefix:`}bar{repl_history_search_seperator:$FILTER_SEPARATOR}\
{repl_history_search_prefix:>}shell} will look for history entries that start with "{code:foo}",
 contains "{code:b... a... r...}", and is a shell history entry.

 A literal '{code:$FILTER_SEPARATOR}' (or any other character) can be escaped by being prefixed with a backslash, as {code:\\;}.
"""

const FILTER_HELP_QUERY = "?"

function ConditionSet(spec::S) where {S <: AbstractString}
    function addcond!(condset::ConditionSet, cond::SubString)
        if startswith(cond, '!')
            push!(condset.negatives, @view cond[2:end])
        elseif startswith(cond, '=')
            push!(condset.exacts, @view cond[2:end])
        elseif startswith(cond, '`')
            push!(condset.initialisms, @view cond[2:end])
        elseif startswith(cond, '/')
            push!(condset.regexps, @view cond[2:end])
        elseif startswith(cond, '>')
            push!(condset.modes, @view cond[2:end])
        elseif startswith(cond, '~')
            push!(condset.fuzzy, @view cond[2:end])
        else
            if startswith(cond, '\\') && !(length(cond) > 1 && cond[2] == '\\')
                cond = @view cond[2:end]
            end
            push!(condset.words, cond)
        end
    end
    cset = ConditionSet{S}()
    pos = firstindex(spec)
    mark = pos
    lastind = lastindex(spec)
    escaped = false
    while pos <= lastind
        chr = spec[pos]
        if escaped
        elseif chr == '\\'
            escaped = true
        elseif chr == FILTER_SEPARATOR
            addcond!(cset, SubString(spec, mark:pos - 1))
            mark = pos + 1
        end
        pos = nextind(spec, pos)
    end
    if mark <= lastind
        addcond!(cset, SubString(spec, mark:lastind))
    end
    cset
end

function ismorestrict(a::ConditionSet, b::ConditionSet)
    length(a.fuzzy) == length(b.fuzzy) &&
        all(splat(==), zip(a.fuzzy, b.fuzzy)) || return false
    length(a.regexps) == length(b.regexps) &&
        all(splat(==), zip(a.regexps, b.regexps)) || return false
    length(a.modes) == length(b.modes) &&
        all(splat(==), zip(a.modes, b.modes)) || return false
    length(a.exacts) >= length(b.exacts) &&
        all(splat(occursin), zip(b.exacts, a.exacts)) || return false
    length(a.words) >= length(b.words) &&
        all(splat(occursin), zip(b.words, a.words)) || return false
    length(a.negatives) >= length(b.negatives) &&
        all(splat(occursin), zip(a.negatives, b.negatives)) || return false
    length(a.initialisms) >= length(b.initialisms) &&
        all(splat(occursin), zip(b.initialisms, a.initialisms)) || return false
    true
end

struct FilterSpec
    exacts::Vector{String}
    negatives::Vector{String}
    regexps::Vector{Regex}
    modes::Vector{Symbol}
end

function FilterSpec(cset::ConditionSet)
    spec = FilterSpec([], [], [], [])
    for term in cset.exacts
        push!(spec.exacts, String(term))
    end
    for words in cset.words, word in eachsplit(words)
        push!(spec.exacts, String(word))
    end
    for term in cset.negatives
        push!(spec.negatives, String(term))
    end
    for rx in cset.regexps
        push!(spec.regexps, Regex(rx))
    end
    for itlsm in cset.initialisms
        rx = Regex(join((string("\\Q", ltr, "\\E\\w+?") for ltr in itlsm), "\\s+"),
                   ifelse(any(isuppercase, itlsm), "", "i"))
        push!(spec.regexps, rx)
    end
    for fuzz in cset.fuzzy
        for word in eachsplit(fuzz)
            rx = Regex(join((string("\\Q", ltr, "\\E\\w*?") for ltr in word), "\\s+"),
                       ifelse(any(isuppercase, fuzz), "", "i"))
            push!(spec.regexps, rx)
        end
    end
    for mode in cset.modes
        push!(spec.modes, Symbol(mode))
    end
    spec
end

function filterchunkrev!(out::Vector{HistEntry}, candidates::DenseVector{HistEntry},
                         spec::FilterSpec, idx::Int = length(candidates);
                         maxtime::Float64 = Inf, maxresults::Int = length(candidates))
    batchsize = clamp(length(candidates) ÷ 512, 10, 1000)
    for batch in Iterators.partition(idx:-1:1, batchsize)
        time() > maxtime && break
        for outer idx in batch
            entry = candidates[idx]
            if !isempty(spec.modes)
                entry.mode ∈ spec.modes || continue
            end
            matchfail = false
            for text in spec.exacts
                if !occursin(text, entry.content)
                    matchfail = true
                    break
                end
            end
            matchfail && continue
            for text in spec.negatives
                if occursin(text, entry.content) 
                    matchfail = true
                    break
                end
            end
            matchfail && continue
            for rx in spec.regexps
                if !occursin(rx, entry.content)
                    matchfail = true
                    break
                end
            end
            matchfail && continue
            pushfirst!(out, entry)
            # if length(out) == maxresults
            #     break
            # end
        end
    end
    idx - 1
end
