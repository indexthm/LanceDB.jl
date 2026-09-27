# Additional APIs from LanceDB_C_jll 0.33.0. Native output allocations are
# copied into Julia values and released before returning to the caller.

function _schema_description(ptr::Ptr{ArrowSchema})
    s = unsafe_load(ptr)
    children = [_schema_description(unsafe_load(Ptr{Ptr{ArrowSchema}}(s.children), i))
                for i in 1:Int(s.n_children)]
    (; name=s.name == C_NULL ? "" : unsafe_string(s.name),
       format=unsafe_string(s.format), nullable=(s.flags & 2) != 0, children,
       dictionary=s.dictionary == C_NULL ? nothing : _schema_description(Ptr{ArrowSchema}(s.dictionary)))
end

"""
    table_schema(table)

Return the Arrow schema as a Julia tree of named tuples (`name`, `format`,
`nullable`, `children`, `dictionary`). Field metadata and extension metadata
are not included. Physical type descriptions remain available for types not
yet supported by the Julia data converter.
"""
function table_schema(tbl::Table)
    _assert_live(tbl)
    schema, err = Ref{Ptr{Cvoid}}(C_NULL), Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve tbl check(lancedb_table_arrow_schema(tbl.handle, schema, err), err)
    try
        _schema_description(Ptr{ArrowSchema}(schema[]))
    finally
        lancedb_free_arrow_schema(schema[])
    end
end

"""
    Session(; index_cache_bytes=0, metadata_cache_bytes=0)

Share native caches between connections with `Connection(path; session=s)`.
Zero selects the native default. Close the session when no longer needed;
connections retain their own native reference to its caches.
"""
mutable struct Session
    handle::Ptr{LanceDBSessionHandle}
    function Session(; index_cache_bytes::Integer=0, metadata_cache_bytes::Integer=0)
        options = LanceDBSessionOptions(_nonnegative(Csize_t, index_cache_bytes),
                                       _nonnegative(Csize_t, metadata_cache_bytes))
        handle = ccall((:lancedb_session_new, liblancedb), Ptr{LanceDBSessionHandle},
                       (Ref{LanceDBSessionOptions},), options)
        check_ptr(handle, "could not create session")
        obj = new(handle)
        finalizer(close, obj)
        obj
    end
end

Base.isopen(s::Session) = s.handle != C_NULL
_assert_live(s::Session) = isopen(s) ? nothing : throw(ArgumentError("Session is closed"))
function Base.close(s::Session)
    isopen(s) || return nothing
    handle = s.handle
    s.handle = C_NULL
    ccall((:lancedb_session_free, liblancedb), Cvoid, (Ptr{LanceDBSessionHandle},), handle)
    nothing
end

"""`cache_stats(session; cache=:index)` returns cache hits, misses, entries and bytes.
Use `cache=:metadata` for the metadata cache."""
function cache_stats(s::Session; cache::Symbol=:index)
    _assert_live(s)
    cache in (:index, :metadata) || throw(ArgumentError("cache must be :index or :metadata"))
    stats = Ref(LanceDBSessionCacheStats(0, 0, 0, 0))
    err = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve s begin
        code = if cache === :index
            ccall((:lancedb_session_index_cache_stats, liblancedb), Cint,
                  (Ptr{LanceDBSessionHandle}, Ref{LanceDBSessionCacheStats}, Ref{Ptr{UInt8}}), s.handle, stats, err)
        else
            ccall((:lancedb_session_metadata_cache_stats, liblancedb), Cint,
                  (Ptr{LanceDBSessionHandle}, Ref{LanceDBSessionCacheStats}, Ref{Ptr{UInt8}}), s.handle, stats, err)
        end
        check(code, err)
    end
    v = stats[]
    (; hits=v.hits, misses=v.misses, num_entries=v.num_entries, size_bytes=v.size_bytes)
end

_strings(xs) = [_check_string(String(x)) for x in xs]
_cstring_ptrs(xs) = Ptr{UInt8}[pointer(x) for x in xs]
_string_dict(keys, vals, n) = Dict(unsafe_string(unsafe_load(keys, i)) =>
                                 unsafe_string(unsafe_load(vals, i)) for i in 1:Int(n))

"""`get_metadata(table; keys=nothing)` returns table metadata as a `Dict{String,String}`."""
function get_metadata(tbl::Table; keys=nothing)
    _assert_live(tbl)
    names = keys === nothing ? String[] : _strings(keys)
    keys !== nothing && isempty(names) && return Dict{String,String}()
    ptrs = _cstring_ptrs(names)
    kout, vout = Ref{Ptr{Ptr{UInt8}}}(C_NULL), Ref{Ptr{Ptr{UInt8}}}(C_NULL)
    n, err = Ref{Csize_t}(0), Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve tbl names ptrs begin
        check(ccall((:lancedb_table_get_metadata, liblancedb), Cint,
            (Ptr{LanceDBTableHandle}, Ptr{Ptr{UInt8}}, Csize_t, Ref{Ptr{Ptr{UInt8}}}, Ref{Ptr{Ptr{UInt8}}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
            tbl.handle, isempty(names) ? C_NULL : pointer(ptrs), length(names), kout, vout, n, err), err)
    end
    try
        _string_dict(kout[], vout[], n[])
    finally
        ccall((:lancedb_free_metadata, liblancedb), Cvoid,
              (Ptr{Ptr{UInt8}}, Ptr{Ptr{UInt8}}, Csize_t), kout[], vout[], n[])
    end
end

"""`set_metadata!(table, pairs)` inserts or updates string metadata, returning the table."""
function set_metadata!(tbl::Table, pairs)
    _assert_live(tbl)
    entries = collect(pairs)
    keys, vals = _strings(first.(entries)), _strings(last.(entries))
    isempty(keys) && return tbl
    kp, vp = _cstring_ptrs(keys), _cstring_ptrs(vals)
    err = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve tbl keys vals kp vp begin
        check(ccall((:lancedb_table_set_metadata, liblancedb), Cint,
            (Ptr{LanceDBTableHandle}, Ptr{Ptr{UInt8}}, Ptr{Ptr{UInt8}}, Csize_t, Ref{Ptr{UInt8}}),
            tbl.handle, kp, vp, length(keys), err), err)
    end
    tbl
end

"""`delete_metadata!(table, keys)` removes metadata keys; missing keys are ignored."""
function delete_metadata!(tbl::Table, keys)
    _assert_live(tbl)
    names = _strings(keys)
    isempty(names) && return tbl
    ptrs, err = _cstring_ptrs(names), Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve tbl names ptrs begin
        check(ccall((:lancedb_table_delete_metadata, liblancedb), Cint,
            (Ptr{LanceDBTableHandle}, Ptr{Ptr{UInt8}}, Csize_t, Ref{Ptr{UInt8}}),
            tbl.handle, ptrs, length(names), err), err)
    end
    tbl
end

"""
    list_versions(table)

Return a vector of named tuples (a Tables.jl row table), ordered by version.
`timestamp` is a UTC `DateTime` truncated to milliseconds for display.
`timestamp_seconds` and `timestamp_nanos` retain the exact native timestamp.
Listing history does not switch the table to an earlier version.
"""
function list_versions(tbl::Table)
    _assert_live(tbl)
    versions = Ref{Ptr{LanceDBVersion}}(C_NULL)
    metadata = Ref{Ptr{LanceDBVersionMetadata}}(C_NULL)
    n, err = Ref{Csize_t}(0), Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve tbl check(ccall((:lancedb_table_list_versions, liblancedb), Cint,
        (Ptr{LanceDBTableHandle}, Ref{Ptr{LanceDBVersion}}, Ref{Ptr{LanceDBVersionMetadata}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
        tbl.handle, versions, metadata, n, err), err)
    try
        history = map(1:Int(n[])) do i
            v, m = unsafe_load(versions[], i), unsafe_load(metadata[], i)
            timestamp = DateTime(1970) + Second(v.timestamp_seconds) + Millisecond(v.timestamp_nanos ÷ 1_000_000)
            (; version=v.version, timestamp, timestamp_seconds=v.timestamp_seconds,
               timestamp_nanos=v.timestamp_nanos, metadata=_string_dict(m.keys, m.values, m.count))
        end
        sort!(history; by=v -> v.version)
    finally
        ccall((:lancedb_free_versions, liblancedb), Cvoid, (Ptr{LanceDBVersion}, Csize_t), versions[], n[])
        ccall((:lancedb_free_version_metadata, liblancedb), Cvoid, (Ptr{LanceDBVersionMetadata}, Csize_t), metadata[], n[])
    end
end

"""`explain_plan(query; verbose=false)` returns a plan without consuming the query."""
function explain_plan(q::Union{Query,VectorQuery}; verbose::Bool=false)
    _assert_live(q)
    plan, err = Ref{Ptr{UInt8}}(C_NULL), Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve q begin
        code = if q isa Query
            ccall((:lancedb_query_explain_plan, liblancedb), Cint,
                  (Ptr{LanceDBQueryHandle}, Bool, Ref{Ptr{UInt8}}, Ref{Ptr{UInt8}}), q.handle, verbose, plan, err)
        else
            ccall((:lancedb_vector_query_explain_plan, liblancedb), Cint,
                  (Ptr{LanceDBVectorQueryHandle}, Bool, Ref{Ptr{UInt8}}, Ref{Ptr{UInt8}}), q.handle, verbose, plan, err)
        end
        check(code, err)
    end
    try
        check_ptr(plan[], "explain_plan returned NULL")
        unsafe_string(plan[])
    finally
        lancedb_free_string(plan[])
    end
end

"""`rename_table(conn, old, new; current_namespace=nothing, new_namespace=nothing)`.
Currently supported by the upstream Cloud backend only."""
function rename_table(conn::Connection, old::AbstractString, new::AbstractString;
                      current_namespace=nothing, new_namespace=nothing)
    _assert_live(conn)
    _check_string(old); _check_string(new)
    cur = current_namespace === nothing ? C_NULL : _check_string(String(current_namespace))
    dst = new_namespace === nothing ? C_NULL : _check_string(String(new_namespace))
    err = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve conn check(ccall((:lancedb_connection_rename_table, liblancedb), Cint,
        (Ptr{LanceDBConnectionHandle}, Cstring, Cstring, Cstring, Cstring, Ref{Ptr{UInt8}}),
        conn.handle, old, new, cur, dst, err), err)
    nothing
end

"""`drop_all_tables(conn; namespace=nothing)` deletes all tables in the specified namespace."""
function drop_all_tables(conn::Connection; namespace=nothing)
    _assert_live(conn)
    ns = namespace === nothing ? C_NULL : _check_string(String(namespace))
    err = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve conn check(ccall((:lancedb_connection_drop_all_tables, liblancedb), Cint,
        (Ptr{LanceDBConnectionHandle}, Cstring, Ref{Ptr{UInt8}}), conn.handle, ns, err), err)
    nothing
end

for (fn, native) in ((:create_namespace, :lancedb_connection_create_namespace),
                     (:drop_namespace, :lancedb_connection_drop_namespace))
    @eval function $fn(conn::Connection, name::AbstractString)
        _assert_live(conn)
        _check_string(name)
        err = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve conn check(ccall(($(QuoteNode(native)), liblancedb), Cint,
            (Ptr{LanceDBConnectionHandle}, Cstring, Ref{Ptr{UInt8}}), conn.handle, name, err), err)
        nothing
    end
end

"""`list_namespaces(conn; parent=nothing)` lists namespaces supported by the backend."""
function list_namespaces(conn::Connection; parent=nothing)
    _assert_live(conn)
    ns = parent === nothing ? C_NULL : _check_string(String(parent))
    names = Ref{Ptr{Ptr{UInt8}}}(C_NULL)
    n, err = Ref{Csize_t}(0), Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve conn check(ccall((:lancedb_connection_list_namespaces, liblancedb), Cint,
        (Ptr{LanceDBConnectionHandle}, Cstring, Ref{Ptr{Ptr{UInt8}}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
        conn.handle, ns, names, n, err), err)
    try
        [unsafe_string(unsafe_load(names[], i)) for i in 1:Int(n[])]
    finally
        ccall((:lancedb_free_namespace_list, liblancedb), Cvoid, (Ptr{Ptr{UInt8}}, Csize_t), names[], n[])
    end
end
