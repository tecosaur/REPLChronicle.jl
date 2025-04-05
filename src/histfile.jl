using Mmap

const REPL_DATE_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

struct HistEntry
    mode::Symbol
    date::DateTime
    # session::UInt32
    # id::UInt16
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
    eof(io) && return hist
    lock(hist.io)
    bytes = if iszero(position(io))
        mmap(io)
    else
        read(io)
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
    pos = firstindex(bytes)
    while true
        pos >= length(bytes) && break
        if bytes[pos] != UInt8('#')
            pos = findnext(bytes, pos, UInt8('\n')) + 1
            continue
        end
        entrystart = pos
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
                seek(io, position(io) + entrystart)
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
        entry = HistEntry(mode, time, String(content))
        push!(records, entry)
    end
    seek(io, position(io) + pos)
    unlock(hist.io)
    hist
end
