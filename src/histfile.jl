using Mmap

const REPL_DATE_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

struct HistEntry
    mode::Symbol
    date::DateTime
    index::UInt32
    # session::UInt32
    # id::UInt16
    # cwd::String
    content::String
    # error::Bool
    # resulttype::String
end

struct HistoryFile
    io::IOStream
    records::Vector{HistEntry}
end

HistoryFile(path::String) = HistoryFile(open(path, "r"), [])

function update!(hist::HistoryFile)
    (; io, records) = hist
    # If the file has grown since the last read,
    # we need to trigger a synchronisation of the
    # stream state. This can be done with `fseek`,
    # but that can't easily be called from Julia.
    # Instead, we can use `filesize` to detect when
    # we need to do this, and then use `peek` to
    # trigger the synchronisation. This relies on
    # undocumented implementation details, but
    # there's not much to be done about that.
    if filesize(io) > position(io)
        try peek(io) catch _ end
    end
    eof(io) && return hist
    lock(hist.io)
    offset, bytes = if iszero(position(io))
        0, mmap(io)
    else
        position(io), read(io)
    end
    function findnext(data::Vector{UInt8}, index::Int, byte::UInt8, limit::Int = length(data))
        for i in index:limit
            data[i] == byte && return i
        end
        limit
    end
    function isstrmatch(data::Vector{UInt8}, at::Int, str::String)
        at + ncodeunits(str) <= length(data) || return false
        for (i, byte) in enumerate(codeunits(str))
            data[at + i - 1] == byte || return false
        end
        true
    end
    histindex = if isempty(hist.records)
        0
    else
        hist.records[end].index
    end
    pos = firstindex(bytes)
    while true
        pos >= length(bytes) && break
        entrystart = pos
        if bytes[pos] != UInt8('#')
            pos = findnext(bytes, pos, UInt8('\n')) + 1
            continue
        end
        time, mode = zero(DateTime), :julia
        while pos < length(bytes) && bytes[pos] == UInt8('#')
            pos += 1
            while pos < length(bytes) && bytes[pos] == UInt8(' ')
                pos += 1
            end
            metastart = pos
            metaend = findnext(bytes, pos, UInt8(':'))
            pos = metaend + 1
            while pos < length(bytes) && bytes[pos] == UInt8(' ')
                pos += 1
            end
            valstart = pos
            valend = findnext(bytes, pos, UInt8('\n'))
            pos = valend + 1
            if isstrmatch(bytes, metastart, "mode:")
                mode = if isstrmatch(bytes, valstart, "julia") && bytes[valstart + ncodeunits("julia")] ∈ (UInt8('\n'), UInt8('\r'))
                    :julia
                elseif isstrmatch(bytes, valstart, "help") && bytes[valstart + ncodeunits("help")] ∈ (UInt8('\n'), UInt8('\r'))
                    :help
                else
                    Symbol(bytes[valstart:valend-1])
                end
            elseif isstrmatch(bytes, metastart, "time:")
                valend = min(valend, valstart + ncodeunits("0000-00-00 00:00:00"))
                timestr = String(bytes[valstart:valend-1]) # It would be nice to avoid the string, but oh well
                timeval = tryparse(DateTime, timestr, REPL_DATE_FORMAT)
                if !isnothing(timeval)
                    time = timeval
                end
            end
        end
        if bytes[pos] != UInt8('\t')
            if pos == length(bytes)
                seek(io, offset + entrystart - 1)
                break
            else
                continue
            end
        end
        contentstart = pos
        nlines = 0
        while true
            pos = findnext(bytes, pos, UInt8('\n'))
            nlines += 1
            if pos < length(bytes) && bytes[pos+1] == UInt8('\t')
                pos += 1
            else
                break
            end
        end
        contentend, pos = pos, contentstart
        content = Vector{UInt8}(undef, contentend - contentstart - nlines)
        bytescopied = 0
        while pos < contentend
            lineend = findnext(bytes, pos, UInt8('\n'))
            nbytes = lineend - pos - (lineend == contentend)
            copyto!(content, bytescopied + 1, bytes, pos + 1, nbytes)
            bytescopied += nbytes
            pos = lineend + 1
        end
        entry = HistEntry(mode, time, histindex += 1, String(content))
        push!(records, entry)
    end
    seek(io, offset + pos - 1)
    unlock(hist.io)
    hist
end
