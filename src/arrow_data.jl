import Base.Libc

# Converts Tables.jl data to Arrow C ABI structures for passing to lancedb-c.
#
# Memory model:
#   - Column DATA lives in Julia-heap Vectors pinned by GC.@preserve in the caller.
#   - ArrowArray/buffer-pointer HEADERS are Libc.malloc'd and freed by us after
#     lancedb_table_add/create returns (i.e. after Arrow-rs has read all data).
#   - release = C_NULL: Arrow-rs Drop skips the callback when NULL, so no
#     cross-thread @cfunction invocation is needed. Julia GC owns the data.

# ── Low-level ArrowArray builders ─────────────────────────────────────────────
# release = C_NULL: Arrow-rs FFI_ArrowArray::drop() skips the release call when
# the pointer is None/NULL, so we avoid invoking any callback from a non-Julia
# Tokio thread. Julia data is kept alive by GC.@preserve; GC frees it afterwards.

function _alloc_buf_ptrs(ptrs::Vector{Ptr{Cvoid}})::Ptr{Ptr{Cvoid}}
    n   = length(ptrs)
    buf = Ptr{Ptr{Cvoid}}(_checked_malloc(n * sizeof(Ptr{Cvoid})))
    for (i, p) in enumerate(ptrs)
        unsafe_store!(buf, p, i)
    end
    buf
end

function _alloc_child_ptrs(children::Vector{Ptr{ArrowArray}})::Ptr{Ptr{ArrowArray}}
    n   = length(children)
    n == 0 && return Ptr{Ptr{ArrowArray}}(C_NULL)
    buf = Ptr{Ptr{ArrowArray}}(_checked_malloc(n * sizeof(Ptr{ArrowArray})))
    for (i, c) in enumerate(children)
        unsafe_store!(buf, c, i)
    end
    buf
end

function _heap_array(arr::ArrowArray)::Ptr{ArrowArray}
    ptr = Ptr{ArrowArray}(_checked_malloc(sizeof(ArrowArray)))
    unsafe_store!(ptr, arr)
    ptr
end

# UTF-8 string column.
# Returns (array_ptr, offsets_vec, bytes_vec); caller must GC.@preserve both vecs.
function _string_arr(data::AbstractVector)
    n       = length(data)
    offsets = Vector{Int32}(undef, n + 1)
    offsets[1] = Int32(0)
    for (i, s) in enumerate(data)
        offsets[i+1] = Base.checked_add(offsets[i], Int32(ncodeunits(String(s))))
    end
    bytes = Vector{UInt8}(undef, offsets[end])
    pos   = 1
    for s in data
        cu = codeunits(String(s))
        nb = length(cu)
        copyto!(bytes, pos, cu, 1, nb)
        pos += nb
    end
    arr = GC.@preserve offsets bytes begin
        bufs = _alloc_buf_ptrs([C_NULL,
                                 Ptr{Cvoid}(pointer(offsets)),
                                 Ptr{Cvoid}(pointer(bytes))])
        try
            _heap_array(ArrowArray(Int64(n), 0, 0, 3, 0,
                Ptr{Cvoid}(bufs), C_NULL, C_NULL, C_NULL, C_NULL))
        catch
            Libc.free(bufs)
            rethrow()
        end
    end
    arr, offsets, bytes
end

# Root struct array (record batch).
function _struct_arr(children::Vector{Ptr{ArrowArray}}, n_rows::Int)::Ptr{ArrowArray}
    child_arr = _alloc_child_ptrs(children)
    bufs = Ptr{Ptr{Cvoid}}(C_NULL)
    try
        bufs = _alloc_buf_ptrs([C_NULL])
        _heap_array(ArrowArray(Int64(n_rows), 0, 0, 1, length(children),
            Ptr{Cvoid}(bufs), Ptr{Cvoid}(child_arr), C_NULL, C_NULL, C_NULL))
    catch
        # The caller still owns the children until the root is returned.
        child_arr == C_NULL || Libc.free(child_arr)
        bufs == C_NULL || Libc.free(bufs)
        rethrow()
    end
end

# ── Free ArrowArray header tree (C-allocated only; data is Julia GC'd) ────────

function _free_array_tree(ptr::Ptr{ArrowArray})
    ptr == C_NULL && return
    s = unsafe_load(ptr)
    s.buffers != C_NULL && Libc.free(s.buffers)
    if s.n_children > 0 && s.children != C_NULL
        cptr = Ptr{Ptr{ArrowArray}}(s.children)
        for i in 1:s.n_children
            child = unsafe_load(cptr, i)
            child != C_NULL && _free_array_tree(child)
        end
        Libc.free(s.children)
    end
    Libc.free(ptr)
end

# ── Schema helpers for data-derived schemas ────────────────────────────────────

function _arrow_format(T::Type)
    T === Int8    && return "c"
    T === UInt8   && return "C"
    T === Int16   && return "s"
    T === UInt16  && return "S"
    T === Int32   && return "i"
    T === UInt32  && return "I"
    T === Int64   && return "l"
    T === UInt64  && return "L"
    T === Float32 && return "f"
    T === Float64 && return "g"
    T <: AbstractString && return "u"
    error("Unsupported column type for Arrow export: $T")
end

# ── Main entry: Tables.jl → (array_ptr, schema_ptr, pins) ────────────────────

"""
    _to_arrow_c_abi(data) -> (array_ptr, schema_ptr, pins)

Convert a Tables.jl-compatible object to Arrow C ABI pointers.

- `array_ptr`  — root struct ArrowArray* for the record batch (Libc-allocated header)
- `schema_ptr` — root ArrowSchema* (Libc-allocated; release with `release_arrow_schema`)
- `pins`       — Vector{Any} of Julia objects that MUST be kept alive via
                 `GC.@preserve pins` for as long as the C pointers are in use

Supported column element types: Int8/16/32/64, UInt8/16/32/64, Float32/64,
Bool, AbstractString (→ UTF-8), and fixed-length nested vectors (→ FixedSizeList).
Columns and vector elements may contain missing values. BinaryColumn, ListColumn,
nested NamedTuple records and Dates.Date/DateTime/Time are supported by the
additional exporters in column_types.jl.
"""
function _validity(data, pins)
    nulls = count(ismissing, data)
    nulls == 0 && return Ptr{Cvoid}(C_NULL), 0
    bits = zeros(UInt8, cld(length(data), 8))
    for (i, x) in enumerate(data)
        ismissing(x) || (bits[(i-1) ÷ 8 + 1] |= UInt8(1) << ((i-1) % 8))
    end
    push!(pins, bits)
    Ptr{Cvoid}(pointer(bits)), nulls
end

function _column_to_arrow(col, name, pins)
    T = Base.nonmissingtype(eltype(col))
    T in (Date,DateTime,Time) && return _temporal_column_to_arrow(col,name,pins,T)
    T !== Union{} && T <: NamedTuple && return _struct_column_to_arrow(col, name, pins, T)
    # Validate types before allocating C headers.
    if T === Union{}
        schema = _alloc_leaf_schema("n", name)
        s = unsafe_load(schema)
        unsafe_store!(schema, ArrowSchema(s.format, s.name, C_NULL, 2, 0, C_NULL, C_NULL, C_NULL, C_NULL))
        try
            arr = _heap_array(ArrowArray(length(col), length(col), 0, 0, 0,
                                       C_NULL, C_NULL, C_NULL, C_NULL, C_NULL))
            return arr, schema
        catch
            release_arrow_schema(schema)
            rethrow()
        end
    end
    fmt = T <: AbstractVector ? "" : T === Bool ? "b" : _arrow_format(T)
    validity, nulls = _validity(col, pins)
    schema = Ptr{ArrowSchema}(C_NULL)
    buffers = Ptr{Ptr{Cvoid}}(C_NULL)
    children = Ptr{Ptr{ArrowArray}}(C_NULL)
    child = Ptr{ArrowArray}(C_NULL)
    child_schema = Ptr{ArrowSchema}(C_NULL)
    arr = Ptr{ArrowArray}(C_NULL)
    try
        if T <: AbstractVector
            sample = findfirst(!ismissing, col)
            sample === nothing && throw(ArgumentError("cannot infer dimension of an empty or all-missing list column: $name"))
            dim = length(col[sample])
            dim > 0 || throw(ArgumentError("fixed-size lists must have positive dimension"))
            ET = eltype(T)
            # Schema nullability must not change when a later batch has null rows.
            flat = Vector{Missing <: eltype(col) ? Union{Missing,ET} : ET}()
            sizehint!(flat, length(col) * dim)
            for row in col
                if ismissing(row)
                    append!(flat, fill(missing, dim))
                else
                    length(row) == dim || throw(ArgumentError("inconsistent list dimension in $name"))
                    append!(flat, row)
                end
            end
            # Retain the non-nullable element type on the common embedding path.
            flat_values = flat
            push!(pins, flat_values)
            child, child_schema = _column_to_arrow(flat_values, "item", pins)
            children = _alloc_child_ptrs([child])
            schema = _alloc_leaf_schema("+w:$dim", name)
            schema_children = Ptr{Ptr{ArrowSchema}}(_checked_malloc(sizeof(Ptr{Cvoid})))
            unsafe_store!(schema_children, child_schema)
            leaf = unsafe_load(schema)
            unsafe_store!(schema, ArrowSchema(leaf.format, leaf.name, C_NULL, Missing <: eltype(col) ? 2 : 0,
                                             1, Ptr{Cvoid}(schema_children), C_NULL, C_NULL, C_NULL))
            child_schema = C_NULL # owned by schema
            buffers = _alloc_buf_ptrs([validity])
            arr = _heap_array(ArrowArray(length(col), nulls, 0, 1, 1,
                                        buffers, children, C_NULL, C_NULL, C_NULL))
        else
            if T <: AbstractString
                values = nulls == 0 ? col : [ismissing(x) ? "" : String(x) for x in col]
                arr, offsets, bytes = _string_arr(values)
                push!(pins, offsets, bytes)
                old = unsafe_load(arr)
                unsafe_store!(Ptr{Ptr{Cvoid}}(old.buffers), validity)
                unsafe_store!(arr, ArrowArray(old.length, nulls, 0, old.n_buffers, 0,
                                             old.buffers, C_NULL, C_NULL, C_NULL, C_NULL))
            else
                values = if T === Bool
                    bits = zeros(UInt8, cld(length(col), 8))
                    for (i, x) in enumerate(col)
                        !ismissing(x) && x && (bits[(i-1) ÷ 8 + 1] |= UInt8(1) << ((i-1) % 8))
                    end
                    bits
                else
                    nulls == 0 && col isa Vector{T} ? col : T[ismissing(x) ? zero(T) : x for x in col]
                end
                push!(pins, values)
                buffers = _alloc_buf_ptrs([validity, Ptr{Cvoid}(pointer(values))])
                arr = _heap_array(ArrowArray(length(col), nulls, 0, 2, 0,
                                            buffers, C_NULL, C_NULL, C_NULL, C_NULL))
            end
            schema = _alloc_leaf_schema(fmt, name)
            if Missing <: eltype(col)
                old = unsafe_load(schema)
                unsafe_store!(schema, ArrowSchema(old.format, old.name, C_NULL, 2, 0,
                                                 C_NULL, C_NULL, C_NULL, C_NULL))
            end
        end
        return arr, schema
    catch
        schema != C_NULL && release_arrow_schema(schema)
        child_schema != C_NULL && release_arrow_schema(child_schema)
        if arr != C_NULL
            _free_array_tree(arr)
        else
            child != C_NULL && _free_array_tree(child)
            children != C_NULL && Libc.free(children)
            buffers != C_NULL && Libc.free(buffers)
        end
        rethrow()
    end
end

function _to_arrow_c_abi(data)
    cols = Tables.columns(data)
    names = collect(Tables.columnnames(cols))
    foreach(nm -> _check_string(String(nm)), names)
    isempty(names) && throw(ArgumentError("table must have at least one column"))
    vectors = [Tables.getcolumn(cols, nm) for nm in names]
    n_rows = length(first(vectors))
    all(v -> length(v) == n_rows, vectors) || throw(ArgumentError("columns must have equal lengths"))
    pins = Any[vectors]
    col_arrays = Ptr{ArrowArray}[]
    col_schemas = Ptr{ArrowSchema}[]
    root_arr = Ptr{ArrowArray}(C_NULL)
    root_schema = Ptr{ArrowSchema}(C_NULL)
    GC.@preserve pins begin
        try
            for (nm, col) in zip(names, vectors)
                arr, schema = _column_to_arrow(col, String(nm), pins)
                push!(col_arrays, arr)
                push!(col_schemas, schema)
            end
            root_arr = _struct_arr(col_arrays, n_rows)
            root_schema = _alloc_leaf_schema("+s", "")
            children = Ptr{Ptr{ArrowSchema}}(_checked_malloc(length(names) * sizeof(Ptr{Cvoid})))
            for (i, schema) in enumerate(col_schemas)
                unsafe_store!(children, schema, i)
            end
            leaf = unsafe_load(root_schema)
            unsafe_store!(root_schema, ArrowSchema(leaf.format, leaf.name, C_NULL, 0,
                length(names), children, C_NULL, C_NULL, C_NULL))
            empty!(col_schemas) # root_schema now owns the child schemas
            return root_arr, root_schema, pins
        catch
            if root_arr == C_NULL
                foreach(_free_array_tree, col_arrays)
            else
                _free_array_tree(root_arr)
            end
            root_schema == C_NULL || release_arrow_schema(root_schema)
            foreach(release_arrow_schema, col_schemas)
            rethrow()
        end
    end
end

# ── Shared helper: build reader from a Tables.jl source ───────────────────────
# Returns (reader_ptr, schema_ptr, array_ptr, pins).
# The caller must:
#   1.  Call lancedb_table_add or lancedb_table_create inside GC.@preserve pins
#   2.  After that call, invoke _free_array_tree(array_ptr) and
#       release_arrow_schema(schema_ptr)

function _make_reader(data)
    arr_ptr, schema_ptr, pins = _to_arrow_c_abi(data)
    reader_out = Ref{Ptr{LanceDBRecordBatchReaderHandle}}(C_NULL)
    errmsg     = Ref{Ptr{UInt8}}(C_NULL)
    try
        GC.@preserve pins begin
            code = lancedb_record_batch_reader_from_arrow(
                Ptr{Cvoid}(arr_ptr), Ptr{Cvoid}(schema_ptr), reader_out, errmsg)
            check(code, errmsg)
        end
    catch
        _free_array_tree(arr_ptr)
        release_arrow_schema(schema_ptr)
        rethrow()
    end
    reader_out[], schema_ptr, arr_ptr, pins
end
