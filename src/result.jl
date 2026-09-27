"""
    QueryResult

Holds a completed LanceDB query result. Implements the `Tables.jl` interface
so it integrates directly with DataFrames.jl, CSV.jl, etc.

Data is materialised on first access via the Arrow C Data Interface.
"""
mutable struct QueryResult
    handle::Ptr{LanceDBQueryResultHandle}
    _columns::Union{Nothing, NamedTuple}
    _batches::Union{Nothing, Vector{NamedTuple}}
end

QueryResult(handle::Ptr{LanceDBQueryResultHandle}) = QueryResult(handle, nothing, nothing)

function Base.close(qr::QueryResult)
    qr.handle == C_NULL && return
    handle = qr.handle
    qr.handle = C_NULL
    lancedb_query_result_free(handle)
    nothing
end

# ── Tables.jl interface ───────────────────────────────────────────────────────

Tables.istable(::QueryResult)      = true
Tables.columnaccess(::QueryResult) = true
Tables.rowaccess(::QueryResult)    = true

function Tables.columns(qr::QueryResult)
    GC.@preserve qr begin
        isnothing(qr._columns) && _materialize!(qr)
        qr._columns
    end
end

function Tables.schema(qr::QueryResult)
    GC.@preserve qr begin
        isnothing(qr._columns) && _materialize!(qr)
        cols = qr._columns
        isempty(cols) && return Tables.Schema(Symbol[], Type[])
        Tables.Schema(collect(keys(cols)), collect(eltype(v) for v in values(cols)))
    end
end

function Tables.rows(qr::QueryResult)
    GC.@preserve qr begin
        isnothing(qr._columns) && _materialize!(qr)
        cols = qr._columns
        n    = isempty(cols) ? 0 : length(first(values(cols)))
        QueryResultRows(cols, n)
    end
end

# ── Row iterator ──────────────────────────────────────────────────────────────

struct QueryResultRow{C<:NamedTuple} <: Tables.AbstractRow
    _cols::C
    _idx::Int
end

Tables.columnnames(row::QueryResultRow)          = keys(getfield(row, :_cols))
Tables.getcolumn(row::QueryResultRow, nm::Symbol) = getfield(row, :_cols)[nm][getfield(row, :_idx)]
Tables.getcolumn(row::QueryResultRow, i::Int)     = getfield(row, :_cols)[i][getfield(row, :_idx)]

struct QueryResultRows{C<:NamedTuple}
    _cols::C
    _len::Int
end

Base.length(rows::QueryResultRows)              = rows._len
Base.eltype(::Type{QueryResultRows{C}}) where C = QueryResultRow{C}
Base.iterate(rows::QueryResultRows, i::Int = 1) =
    i > rows._len ? nothing : (QueryResultRow(rows._cols, i), i + 1)

# ── Materialisation ───────────────────────────────────────────────────────────

function _load_batches!(qr::QueryResult)
    qr._batches === nothing || return nothing
    GC.@preserve qr begin
        qr.handle == C_NULL && throw(LanceDBException(Int32(LANCEDB_RUNTIME), "QueryResult already closed"))

        arrays_out = Ref{Ptr{Ptr{Cvoid}}}(C_NULL)
        schema_out = Ref{Ptr{Cvoid}}(C_NULL)
        count_out  = Ref{Csize_t}(0)
        errmsg     = Ref{Ptr{UInt8}}(C_NULL)

        code = lancedb_query_result_to_arrow(qr.handle, arrays_out, schema_out, count_out, errmsg)
        qr.handle = C_NULL   # consumed by lancedb_query_result_to_arrow
        check(code, errmsg)

        n_batches  = Int(count_out[])
        schema_ptr = schema_out[]
        arrays_ptr = arrays_out[]

        try
            qr._batches = NamedTuple[_read_batch_columns(unsafe_load(arrays_ptr, i), schema_ptr) for i in 1:n_batches]
        finally
            lancedb_free_arrow_arrays(arrays_ptr, Csize_t(n_batches))
            lancedb_free_arrow_schema(schema_ptr)
        end
        nothing
    end
end

# The current C ABI collects the complete native stream. Partitions avoid an
# additional Julia-side concatenation, but are not bounded-memory streaming.
Tables.istable(::Type{QueryResult}) = true
Tables.columnaccess(::Type{QueryResult}) = true
Tables.rowaccess(::Type{QueryResult}) = true
function Tables.partitions(qr::QueryResult)
    _load_batches!(qr)
    qr._batches
end

function _materialize!(qr::QueryResult)
    _load_batches!(qr)
    batches = qr._batches
    qr._columns = if isempty(batches)
        NamedTuple()
    elseif length(batches) == 1
        first(batches)
    else
        names = keys(first(batches))
        NamedTuple{names}(Tuple(_concat_columns([b[nm] for b in batches]) for nm in names))
    end
    # Retain only the joined columns after column access, to avoid holding
    # both copies. Previously obtained partitions remain valid Julia values.
    qr._batches = NamedTuple[qr._columns]
    nothing
end

# ── Arrow C ABI → Julia ───────────────────────────────────────────────────────

function _fmt_to_type(fmt::String)
    fmt == "c" && return Int8
    fmt == "C" && return UInt8
    fmt == "s" && return Int16
    fmt == "S" && return UInt16
    fmt == "i" && return Int32
    fmt == "I" && return UInt32
    fmt == "l" && return Int64
    fmt == "L" && return UInt64
    fmt == "f" && return Float32
    fmt == "g" && return Float64
    error("Unsupported Arrow format for result import: $fmt")
end

# Test bit `bit_idx` (0-indexed) of an Arrow validity bitmap.
# Returns true if the slot is valid (non-null).
function _is_valid(validity_ptr::Ptr{UInt8}, bit_idx::Int)::Bool
    byte = unsafe_load(validity_ptr, (bit_idx >> 3) + 1)   # 1-indexed byte
    (byte >> (bit_idx & 7)) & 0x01 == 0x01
end

# Read one column from an ArrowArray given its Arrow format string.
# All column data is copied into fresh Julia vectors.
# Returns Vector{T} when null_count == 0, or Vector{Union{T,Missing}} when the
# validity bitmap indicates at least one null slot.
#
# NOTE: Julia Ptr{T} + n advances by n *bytes*, not n elements.
# Use unsafe_load(ptr, i) for element-indexed access (1-indexed, sizeof(T)-aware).
function _read_column(arr::ArrowArray, fmt::String, schema::Union{Nothing,ArrowSchema}=nothing)
    if schema !== nothing && schema.dictionary != C_NULL
        ds = unsafe_load(Ptr{ArrowSchema}(schema.dictionary))
        dictionary = _read_column(unsafe_load(Ptr{ArrowArray}(arr.dictionary)), unsafe_string(ds.format), ds)
        plain = ArrowSchema(schema.format, schema.name, schema.metadata, schema.flags,
                            schema.n_children, schema.children, C_NULL, schema.release, schema.private_data)
        codes = _read_column(arr, fmt, plain)
        T = eltype(dictionary)
        return Union{Missing,T}[ismissing(i) ? missing : dictionary[Int(i)+1] for i in codes]
    end
    if fmt in ("tdD","tsm:","ttn")
        T = fmt == "tdD" ? Date : fmt == "tsm:" ? DateTime : Time
        values = _read_column(arr,fmt == "tdD" ? "i" : "l")
        CT = Missing <: eltype(values) ? Union{Missing,T} : T
        return CT[ismissing(v) ? missing : _temporal_value(v,T) for v in values]
    end
    n, offset = Int(arr.length), Int(arr.offset)
    fmt == "n" && return fill(missing, n)
    bufs = Ptr{Ptr{Cvoid}}(arr.buffers)
    validity = Ptr{UInt8}(unsafe_load(bufs, 1))
    has_nulls = arr.null_count != 0 && validity != C_NULL
    valid(i) = !has_nulls || _is_valid(validity, offset+i-1)

    if fmt in ("u", "U", "z", "Z")
        O = fmt in ("U", "Z") ? Int64 : Int32
        offsets = Ptr{O}(unsafe_load(bufs, 2))
        bytes = Ptr{UInt8}(unsafe_load(bufs, 3))
        T = fmt in ("u", "U") ? String : Vector{UInt8}
        out = Vector{has_nulls ? Union{Missing,T} : T}(undef, n)
        for i in 1:n
            if valid(i)
                lo, hi = Int(unsafe_load(offsets, offset+i)), Int(unsafe_load(offsets, offset+i+1))
                out[i] = T === String ? (hi == lo ? "" : unsafe_string(bytes+lo, hi-lo)) :
                    _copy_bytes(bytes+lo, hi-lo)
            else
                out[i] = missing
            end
        end
        return fmt in ("z","Z") ? BinaryColumn(out;large=fmt == "Z") : out
    elseif startswith(fmt, "w:")
        width = parse(Int, fmt[3:end])
        bytes = Ptr{UInt8}(unsafe_load(bufs, 2))
        T = has_nulls ? Union{Missing,Vector{UInt8}} : Vector{UInt8}
        return BinaryColumn(T[valid(i) ? _copy_bytes(bytes+(offset+i-1)*width,width) : missing for i in 1:n])
    elseif fmt == "+s"
        schema === nothing && throw(ArgumentError("struct import requires a child schema"))
        children = [_read_column(unsafe_load(unsafe_load(Ptr{Ptr{ArrowArray}}(arr.children), i)),
                        unsafe_string(cs.format), cs)
                    for i in 1:Int(schema.n_children)
                    for cs in (unsafe_load(unsafe_load(Ptr{Ptr{ArrowSchema}}(schema.children), i)),)]
        names = Tuple(Symbol(unsafe_string(unsafe_load(unsafe_load(Ptr{Ptr{ArrowSchema}}(schema.children), i)).name))
                      for i in 1:Int(schema.n_children))
        Row = NamedTuple{names,Tuple{eltype.(children)...}}
        T = has_nulls ? Union{Missing,Row} : Row
        return T[valid(i) ? Row(Tuple(c[offset+i] for c in children)) : missing for i in 1:n]
    elseif startswith(fmt, "+w:") || fmt in ("+l", "+L")
        child = unsafe_load(unsafe_load(Ptr{Ptr{ArrowArray}}(arr.children)))
        # Two-argument internal callers historically constructed Float32 lists.
        cs = schema === nothing ? nothing : unsafe_load(unsafe_load(Ptr{Ptr{ArrowSchema}}(schema.children)))
        values = _read_column(child, cs === nothing ? "f" : unsafe_string(cs.format), cs)
        T = Vector{eltype(values)}
        out = Vector{has_nulls ? Union{Missing,T} : T}(undef, n)
        fixed = startswith(fmt, "+w:")
        dim = fixed ? parse(Int, fmt[4:end]) : 0
        offsets = fixed ? nothing : Ptr{fmt == "+L" ? Int64 : Int32}(unsafe_load(bufs, 2))
        for i in 1:n
            if valid(i)
                lo = fixed ? (offset+i-1)*dim : Int(unsafe_load(offsets, offset+i))
                hi = fixed ? lo+dim : Int(unsafe_load(offsets, offset+i+1))
                out[i] = values[lo+1:hi]
            else
                out[i] = missing
            end
        end
        return fixed ? out : ListColumn(out;large=fmt == "+L")
    else
        T = fmt == "b" ? Bool : _fmt_to_type(fmt)
        ptr = Ptr{T}(unsafe_load(bufs, 2))
        out = Vector{has_nulls ? Union{Missing,T} : T}(undef, n)
        if !has_nulls && T !== Bool
            GC.@preserve out unsafe_copyto!(pointer(out), ptr + offset*sizeof(T), n)
            return out
        end
        for i in 1:n
            out[i] = valid(i) ? (T === Bool ? _is_valid(Ptr{UInt8}(ptr), offset+i-1) : unsafe_load(ptr, offset+i)) : missing
        end
        return out
    end
end

# Read one Arrow struct batch into a NamedTuple of column vectors.
function _read_batch_columns(batch_ptr::Ptr{Cvoid}, schema_ptr::Ptr{Cvoid})
    arr    = unsafe_load(Ptr{ArrowArray}(batch_ptr))
    schema = unsafe_load(Ptr{ArrowSchema}(schema_ptr))
    ncols  = Int(schema.n_children)
    child_schemas = Ptr{Ptr{ArrowSchema}}(schema.children)
    child_arrays  = Ptr{Ptr{ArrowArray}}(arr.children)
    names  = Vector{Symbol}(undef, ncols)
    cols   = Vector{Any}(undef, ncols)
    for i in 1:ncols
        cs       = unsafe_load(unsafe_load(child_schemas, i))
        ca       = unsafe_load(unsafe_load(child_arrays, i))
        names[i] = Symbol(unsafe_string(cs.name))
        # A record batch is a struct array; its slice applies to every child.
        # Child offsets are independent and must be retained as well.
        sliced = ArrowArray(arr.length, ca.null_count == 0 ? 0 : -1,
            ca.offset + arr.offset, ca.n_buffers, ca.n_children,
            ca.buffers, ca.children, ca.dictionary, ca.release, ca.private_data)
        cols[i]  = _read_column(sliced, unsafe_string(cs.format), cs)
    end
    NamedTuple{Tuple(names)}(Tuple(cols))
end

function _copy_bytes(ptr::Ptr{UInt8}, n::Int)
    out = Vector{UInt8}(undef,n)
    n == 0 || GC.@preserve out unsafe_copyto!(pointer(out),ptr,n)
    out
end

function _concat_columns(columns)
    # Base.reduce(vcat, vector_of_vectors) uses a specialized concatenation
    # path that bypasses vcat overloads, so retain the Arrow column markers here.
    if first(columns) isa BinaryColumn
        return BinaryColumn(reduce(vcat,[c.values for c in columns]);large=any(_large,columns))
    elseif first(columns) isa ListColumn
        return ListColumn(reduce(vcat,[c.values for c in columns]);large=any(_large,columns))
    end
    reduce(vcat,columns)
end
