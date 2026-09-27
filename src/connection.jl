"""
    Connection

Manages a LanceDB connection. Freed automatically by the GC via finalizer;
use the do-block form for deterministic cleanup.

    open(Connection, "./mydb") do conn
        ...
    end
"""
mutable struct Connection
    handle::Ptr{LanceDBConnectionHandle}
    _uri::String
    _storage_options::Union{Nothing,Vector{Pair{String,String}}}
    _session          # nothing or a Session object

    function Connection(uri::AbstractString; storage_options=nothing, session=nothing)
        # Capture once: callers may mutate a dictionary or supply a one-shot iterator.
        storage_options = storage_options === nothing ? nothing :
            Pair{String,String}[String(k) => String(v) for (k,v) in storage_options]
        handle = _build_handle(uri, storage_options, session)
        conn   = new(handle, String(uri), storage_options, session)
        finalizer(close, conn)
        conn
    end
end

function _build_handle(uri, storage_options, session)
    _check_string(uri)
    if storage_options !== nothing
        foreach(kv -> (_check_string(first(kv)); _check_string(last(kv))), storage_options)
    end
    session === nothing || _assert_live(session)
    builder = lancedb_connect(uri)
    check_ptr(builder, "lancedb_connect returned NULL for uri: $uri")

    try
        if !isnothing(storage_options)
            for (k, v) in storage_options
                builder = lancedb_connect_builder_storage_option(builder, k, v)
                check_ptr(builder, "lancedb_connect_builder_storage_option failed for key: $k")
            end
        end
        if !isnothing(session)
            builder = GC.@preserve session lancedb_connect_builder_session(builder, session.handle)
            check_ptr(builder, "lancedb_connect_builder_session returned NULL")
        end
        connection = Ref{Ptr{LanceDBConnectionHandle}}(C_NULL)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        owned = builder
        builder = C_NULL # execute consumes the builder, including on error
        check(lancedb_connect_builder_execute(owned, connection, errmsg), errmsg)
        check_ptr(connection[], "lancedb_connect_builder_execute returned NULL for uri: $uri")
    finally
        builder == C_NULL || lancedb_connect_builder_free(builder)
    end
end

"""
    open(Connection, uri; kwargs...) do conn ... end

Do-block form of `Connection`. Guarantees `close(conn)` is called even if
the block throws. Accepts the same keyword arguments as `Connection(uri; ...)`.

```julia
open(Connection, "/tmp/mydb") do conn
    tbl = open_table(conn, "items")
    println(count_rows(tbl))
    close(tbl)
end
```
"""
function Base.open(f::Function, ::Type{Connection}, uri::AbstractString; kwargs...)
    conn = Connection(uri; kwargs...)
    try
        f(conn)
    finally
        close(conn)
    end
end

"""
    close(conn::Connection)

Release the native connection handle immediately. Safe to call more than once.
"""
function Base.close(conn::Connection)
    conn.handle == C_NULL && return
    handle = conn.handle
    conn.handle = C_NULL
    lancedb_connection_free(handle)
    nothing
end

"""
    isopen(conn::Connection) -> Bool

Return `true` if the connection handle is live (not yet closed).
"""
Base.isopen(conn::Connection) = conn.handle != C_NULL

"""
    reopen!(conn::Connection) -> Connection

Re-establish a connection that was previously closed with `close`. Uses the
URI and options captured at construction time. Returns `conn` unchanged if it
is already open.
"""
function reopen!(conn::Connection)
    GC.@preserve conn begin
        Base.isopen(conn) && return conn
        conn.handle = _build_handle(conn._uri, conn._storage_options, conn._session)
        conn
    end
end

"""
    uri(conn) -> String

Return the URI this connection points to. Works even after the connection has
been closed.
"""
uri(conn::Connection) = conn._uri

"""
    table_names(conn) -> Vector{String}

List all table names in the database.
"""
function table_names(conn::Connection; limit::Union{Nothing,Integer}=nothing, start_after::Union{Nothing,AbstractString}=nothing)::Vector{String}
    _assert_live(conn)
    GC.@preserve conn begin
        names_out = Ref{Ptr{Ptr{UInt8}}}(C_NULL)
        count_out = Ref{Csize_t}(0)
        errmsg    = Ref{Ptr{UInt8}}(C_NULL)
        limit === nothing || _nonnegative(Cuint, limit)
        start_after === nothing || _check_string(start_after)
        code = if limit === nothing && start_after === nothing
            lancedb_connection_table_names(conn.handle, names_out, count_out, errmsg)
        else
            builder = ccall((:lancedb_connection_table_names_builder, liblancedb), Ptr{Cvoid},
                            (Ptr{LanceDBConnectionHandle},), conn.handle)
            check_ptr(builder, "could not create table names builder")
            try
                if limit !== nothing
                    builder = ccall((:lancedb_table_names_builder_limit, liblancedb), Ptr{Cvoid},
                                    (Ptr{Cvoid}, Cuint), builder, limit)
                    check_ptr(builder, "could not set table names limit")
                end
                if start_after !== nothing
                    builder = ccall((:lancedb_table_names_builder_start_after, liblancedb), Ptr{Cvoid},
                                    (Ptr{Cvoid}, Cstring), builder, start_after)
                    check_ptr(builder, "could not set table names start_after")
                end
                owned = builder
                builder = C_NULL
                ccall((:lancedb_table_names_builder_execute, liblancedb), Cint,
                    (Ptr{Cvoid}, Ref{Ptr{Ptr{UInt8}}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
                    owned, names_out, count_out, errmsg)
            finally
                builder == C_NULL || ccall((:lancedb_table_names_builder_free, liblancedb), Cvoid, (Ptr{Cvoid},), builder)
            end
        end
        check(code, errmsg)
        n   = count_out[]
        ptr = names_out[]
        try
            [unsafe_string(unsafe_load(ptr, i)) for i in 1:n]
        finally
            lancedb_free_table_names(ptr, n)
        end
    end
end

"""
    open_table(conn, name) -> Table

Open an existing table. Throws `LanceDBException` if the table does not exist.
"""
function open_table(conn::Connection, name::AbstractString)::Table
    _assert_live(conn)
    _check_string(name)
    GC.@preserve conn begin
        table_out = Ref{Ptr{LanceDBTableHandle}}(C_NULL)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_connection_open_table(conn.handle, name, table_out, errmsg), errmsg)
        handle = table_out[]
        check_ptr(handle, "table not found: $name")
        tbl = Table(handle, String(name))
        finalizer(close, tbl)
        tbl
    end
end

"""
    TableSink(conn, name)

A write target for the Tables.jl sink protocol. Pipe any Tables.jl-compatible
source into `Tables.materializer(TableSink(conn, name))` to create a new table:

```julia
CSV.File("data.csv")  |> Tables.materializer(TableSink(conn, "mytable"))
Arrow.Table(buf)      |> Tables.materializer(TableSink(conn, "embeddings"))
```
"""
struct TableSink
    conn::Connection
    name::String
end

"""
    Tables.materializer(sink::TableSink)

Returns a function that creates a new table from any Tables.jl-compatible
source and returns the resulting `Table`.
"""
Tables.materializer(sink::TableSink) = data -> create_table(sink.conn, sink.name, data)

"""
    create_table(conn, name, schema; reader=C_NULL) -> Table

Create a new table with the given Arrow C ABI schema pointer.
Pass a `LanceDBRecordBatchReaderHandle` pointer in `reader` to populate with
initial data; leave as `C_NULL` to create an empty table.
"""
function create_table(conn::Connection, name::AbstractString,
                      schema::Ptr{ArrowSchema};
                      reader::Ptr{LanceDBRecordBatchReaderHandle}=Ptr{LanceDBRecordBatchReaderHandle}(C_NULL))::Table
    _assert_live(conn)
    _check_string(name)
    GC.@preserve conn begin
        table_out = Ref{Ptr{LanceDBTableHandle}}(C_NULL)
        errmsg    = Ref{Ptr{UInt8}}(C_NULL)
        code = lancedb_table_create(conn.handle, name, Ptr{Cvoid}(schema), reader, table_out, errmsg)
        check(code, errmsg)
        tbl = Table(table_out[], String(name))
        finalizer(close, tbl)
        tbl
    end
end

"""
    create_table(conn, name, data)

Create a table and populate it from any Tables.jl-compatible source.
The schema is inferred from the data column types.
"""
function create_table(conn::Connection, name::AbstractString, data)
    _assert_live(conn)
    _check_string(name)
    GC.@preserve conn begin
        Tables.istable(data) || throw(ArgumentError("data must satisfy the Tables.jl interface"))
        reader, schema_ptr, arr_hdr, pins = _make_reader(data)
        table_out = Ref{Ptr{LanceDBTableHandle}}(C_NULL)
        errmsg    = Ref{Ptr{UInt8}}(C_NULL)
        code = try
            GC.@preserve conn pins lancedb_table_create(conn.handle, name, Ptr{Cvoid}(schema_ptr),
                                                       reader, table_out, errmsg)
        finally
            _free_array_tree(arr_hdr)
            release_arrow_schema(schema_ptr)
        end
        check(code, errmsg)
        tbl = Table(table_out[], String(name))
        finalizer(close, tbl)
        tbl
    end
end

"""
    drop_table(conn, name)

Drop a table. Throws `LanceDBException` on failure.
"""
function drop_table(conn::Connection, name::AbstractString)
    _assert_live(conn)
    _check_string(name)
    GC.@preserve conn begin
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code   = lancedb_connection_drop_table(conn.handle, name, Ptr{UInt8}(C_NULL), errmsg)
        check(code, errmsg)
    end
end
