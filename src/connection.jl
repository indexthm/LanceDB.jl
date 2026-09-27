"""
    Connection

Manages a LanceDB connection. Freed automatically by the GC via finalizer;
use the do-block form for deterministic cleanup.

    Connection("./mydb") do conn
        ...
    end
"""
mutable struct Connection
    handle::Ptr{LanceDBConnectionHandle}
    _uri::String
    _storage_options  # nothing or iterable of (key => value) pairs
    _session          # nothing or a Session object

    function Connection(uri::AbstractString; storage_options=nothing, session=nothing)
        handle = _build_handle(uri, storage_options, session)
        conn   = new(handle, String(uri), storage_options, session)
        finalizer(c -> c.handle != C_NULL && lancedb_connection_free(c.handle), conn)
        conn
    end
end

function _build_handle(uri, storage_options, session)
    builder = lancedb_connect(uri)
    check_ptr(builder, "lancedb_connect returned NULL for uri: $uri")

    if !isnothing(storage_options)
        for (k, v) in storage_options
            builder = lancedb_connect_builder_storage_option(builder, k, v)
            check_ptr(builder, "lancedb_connect_builder_storage_option failed for key: $k")
        end
    end

    if !isnothing(session)
        builder = lancedb_connect_builder_session(builder, session.handle)
        check_ptr(builder, "lancedb_connect_builder_session returned NULL")
    end

    connection = Ref{Ptr{LanceDBConnectionHandle}}(C_NULL)
    errmsg = Ref{Ptr{UInt8}}(C_NULL)
    check(lancedb_connect_builder_execute(builder, connection, errmsg), errmsg)
    check_ptr(connection[], "lancedb_connect_builder_execute returned NULL for uri: $uri")
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
    lancedb_connection_free(conn.handle)
    conn.handle = C_NULL
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
    Base.isopen(conn) && return conn
    conn.handle = _build_handle(conn._uri, conn._storage_options, conn._session)
    conn
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
function table_names(conn::Connection)::Vector{String}
    names_out = Ref{Ptr{Ptr{UInt8}}}(C_NULL)
    count_out = Ref{Csize_t}(0)
    errmsg    = Ref{Ptr{UInt8}}(C_NULL)
    code = lancedb_connection_table_names(conn.handle, names_out, count_out, errmsg)
    check(code, errmsg)
    n   = count_out[]
    ptr = names_out[]
    result = [unsafe_string(unsafe_load(ptr, i)) for i in 1:n]
    lancedb_free_table_names(ptr, n)
    result
end

"""
    open_table(conn, name) -> Table

Open an existing table. Throws `LanceDBException` if the table does not exist.
"""
function open_table(conn::Connection, name::AbstractString)::Table
    output = Ref{Ptr{LanceDBTableHandle}}(C_NULL)
    errmsg = Ref{Ptr{UInt8}}(C_NULL)
    check(lancedb_connection_open_table(conn.handle, name, output, errmsg), errmsg)
    handle = output[]
    check_ptr(handle, "table not found: $name")
    tbl = Table(handle, String(name))
    finalizer(t -> t.handle != C_NULL && lancedb_table_free(t.handle), tbl)
    tbl
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
    table_out = Ref{Ptr{LanceDBTableHandle}}(C_NULL)
    errmsg    = Ref{Ptr{UInt8}}(C_NULL)
    code = lancedb_table_create(conn.handle, name, Ptr{Cvoid}(schema), reader, table_out, errmsg)
    check(code, errmsg)
    tbl = Table(table_out[], String(name))
    finalizer(t -> t.handle != C_NULL && lancedb_table_free(t.handle), tbl)
    tbl
end

"""
    create_table(conn, name, data)

Create a table and populate it from any Tables.jl-compatible source.
The schema is inferred from the data column types.
"""
function create_table(conn::Connection, name::AbstractString, data)
    Tables.istable(data) || throw(ArgumentError("data must satisfy the Tables.jl interface"))
    reader, schema_ptr, arr_hdr, pins = _make_reader(data)
    table_out = Ref{Ptr{LanceDBTableHandle}}(C_NULL)
    errmsg    = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve pins begin
        code = lancedb_table_create(conn.handle, name, Ptr{Cvoid}(schema_ptr),
                                    reader, table_out, errmsg)
    end
    _free_array_tree(arr_hdr)
    release_arrow_schema(schema_ptr)
    check(code, errmsg)
    tbl = Table(table_out[], String(name))
    finalizer(t -> t.handle != C_NULL && lancedb_table_free(t.handle), tbl)
    tbl
end

"""
    drop_table(conn, name)

Drop a table. Throws `LanceDBException` on failure.
"""
function drop_table(conn::Connection, name::AbstractString)
    errmsg = Ref{Ptr{UInt8}}(C_NULL)
    code   = lancedb_connection_drop_table(conn.handle, name, Ptr{UInt8}(C_NULL), errmsg)
    check(code, errmsg)
end
