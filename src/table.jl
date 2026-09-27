"""
    Table

An open LanceDB table handle. Freed automatically by the GC via finalizer;
call `close(tbl)` for deterministic cleanup.
"""
mutable struct Table
    handle::Ptr{LanceDBTableHandle}
    name::String
end

"""
    close(tbl::Table)

Release the native table handle immediately. Safe to call more than once.
After closing, any further operations on `tbl` will error.
"""
function Base.close(tbl::Table)
    tbl.handle == C_NULL && return
    handle = tbl.handle
    tbl.handle = C_NULL
    lancedb_table_free(handle)
    nothing
end

Base.show(io::IO, tbl::Table) = print(io, "Table(\"$(tbl.name)\")")

"""
    count_rows(tbl) -> Int
"""
function count_rows(tbl::Table)::Int
    _assert_live(tbl)
    GC.@preserve tbl begin
        Int(lancedb_table_count_rows(tbl.handle))
    end
end

"""
    table_version(tbl) -> Int
"""
function table_version(tbl::Table)::Int
    _assert_live(tbl)
    GC.@preserve tbl begin
        Int(lancedb_table_version(tbl.handle))
    end
end

"""
    delete_rows(tbl, predicate)

Delete rows matching the SQL predicate string.
"""
function delete_rows(tbl::Table, predicate::AbstractString)
    _assert_live(tbl)
    _check_string(predicate)
    GC.@preserve tbl begin
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code   = lancedb_table_delete(tbl.handle, predicate, errmsg)
        check(code, errmsg)
    end
end

"""
    add(tbl, reader)

Append data using a raw `LanceDBRecordBatchReaderHandle` (consumed by this call).
"""
function add(tbl::Table, reader::Ptr{LanceDBRecordBatchReaderHandle})
    _assert_live(tbl)
    GC.@preserve tbl begin
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code   = lancedb_table_add(tbl.handle, reader, errmsg)
        check(code, errmsg)
    end
end

"""
    add(tbl, data)

Append rows from any Tables.jl-compatible source (NamedTuple, DataFrame, …).

Supported column element types: Int8/16/32/64, UInt8/16/32/64, Float32/64,
Bool, AbstractString (UTF-8), and fixed-length nested vectors (FixedSizeList).
Nullable columns and nullable list elements are supported, along with explicit
BinaryColumn/ListColumn inputs, nested NamedTuple records and Date/DateTime/Time.
"""
function add(tbl::Table, data)
    _assert_live(tbl)
    GC.@preserve tbl begin
        Tables.istable(data) || throw(ArgumentError("data must satisfy the Tables.jl interface"))
        reader, schema_ptr, arr_hdr, pins = _make_reader(data)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code = try
            GC.@preserve tbl pins lancedb_table_add(tbl.handle, reader, errmsg)
        finally
            _free_array_tree(arr_hdr)
            release_arrow_schema(schema_ptr)
        end
        check(code, errmsg)
        nothing
    end
end

"""
    merge_insert(tbl, reader, on_columns; config=LanceDBMergeInsertConfig())

Upsert rows keyed on `on_columns`. The reader is consumed by this call.
"""
function merge_insert(tbl::Table,
                      reader::Ptr{LanceDBRecordBatchReaderHandle},
                      on_columns::Vector{String};
                      config::LanceDBMergeInsertConfig=LanceDBMergeInsertConfig(),
                      condition=nothing)
    _assert_live(tbl)
    config, condition_owner = _merge_condition(config, condition)
    foreach(_check_string, on_columns)
    isempty(on_columns) && throw(ArgumentError("merge keys cannot be empty"))
    GC.@preserve tbl condition_owner begin
        ptrs = [pointer(c) for c in on_columns]
        GC.@preserve on_columns ptrs begin
            col_ptrs = Ptr{Ptr{UInt8}}(pointer(ptrs))
            errmsg   = Ref{Ptr{UInt8}}(C_NULL)
            code     = lancedb_table_merge_insert(tbl.handle, reader, col_ptrs,
                                                   Csize_t(length(on_columns)),
                                                   Ref(config), errmsg)
            check(code, errmsg)
        end
    end
end

"""
    merge_insert(tbl, data, on_columns; config=LanceDBMergeInsertConfig())

Upsert rows from any Tables.jl-compatible source, keyed on `on_columns`.
Matched rows are updated; unmatched rows are inserted. `condition` optionally
restricts updates using a SQL string or a borrowed `LanceDBExpr`. Refer to
columns with `target.` and `source.` prefixes.
"""
function merge_insert(tbl::Table, data, on_columns::Vector{String};
                      config::LanceDBMergeInsertConfig=LanceDBMergeInsertConfig(),
                      condition=nothing)
    _assert_live(tbl)
    config, condition_owner = _merge_condition(config, condition)
    GC.@preserve tbl condition_owner begin
        Tables.istable(data) || throw(ArgumentError("data must satisfy the Tables.jl interface"))
        foreach(_check_string, on_columns)
        isempty(on_columns) && throw(ArgumentError("merge keys cannot be empty"))
        ptrs = [pointer(c) for c in on_columns]
        reader, schema_ptr, arr_hdr, pins = _make_reader(data)
        GC.@preserve pins on_columns ptrs begin
            col_ptrs = Ptr{Ptr{UInt8}}(pointer(ptrs))
            errmsg   = Ref{Ptr{UInt8}}(C_NULL)
            code = try
                lancedb_table_merge_insert(tbl.handle, reader, col_ptrs,
                                          Csize_t(length(on_columns)), Ref(config), errmsg)
            finally
                _free_array_tree(arr_hdr)
                release_arrow_schema(schema_ptr)
            end
            check(code, errmsg)
        end
        nothing
    end
end

merge_insert(tbl::Table, data, on_column::String; kwargs...) =
    merge_insert(tbl, data, [on_column]; kwargs...)

"""
    Tables.materializer(tbl::Table)

Returns a function that appends any Tables.jl-compatible source to `tbl` and
returns `tbl`. Enables pipe syntax:

```julia
CSV.File("new_rows.csv") |> Tables.materializer(tbl)
Arrow.Table(buf)         |> Tables.materializer(tbl)
```
"""
Tables.materializer(tbl::Table) = data -> (add(tbl, data); tbl)

"""
    optimize(tbl; type=OptimizeAll)

Compact files and/or prune old versions. Use `OptimizeCompact` for compaction
only, `OptimizeIndex` to update indexes, or `OptimizePrune` to clean old versions
according to the native retention policy. `OptimizeAll` includes pruning.
The C API does not expose a custom retention interval or cleanup statistics.
Pruned history may no longer be recoverable by other clients.
"""
function optimize(tbl::Table; type::OptimizeType=OptimizeAll)
    _assert_live(tbl)
    GC.@preserve tbl begin
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code   = lancedb_table_optimize(tbl.handle, Cint(type), errmsg)
        check(code, errmsg)
    end
end
