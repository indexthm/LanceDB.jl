"""
    create_vector_index(tbl, column; type=Auto, config=LanceDBVectorIndexConfig())
    create_vector_index(tbl, columns::Vector{String}; ...)

Build a vector index on `column` (or a list of columns) to accelerate ANN
search. The default `type=Auto` lets LanceDB pick the algorithm; specify
`IVFFlat`, `IVFPQ`, `IVFHNSWpq`, or `IVFHNSWsq` explicitly when needed.

Training requirements depend on the index type and its configuration. After adding new rows
call `optimize(tbl; type=OptimizeIndex)` to index the delta.

```julia
cfg = LanceDBVectorIndexConfig()
cfg.num_partitions = 16
create_vector_index(tbl, "embedding"; type=IVFFlat, config=cfg)
```
"""
function create_vector_index(tbl::Table, columns::Vector{String};
                              type::IndexType=Auto,
                              config::LanceDBVectorIndexConfig=LanceDBVectorIndexConfig())
    _assert_live(tbl)
    GC.@preserve tbl begin
        foreach(_check_string, columns)
        ptrs   = [pointer(c) for c in columns]
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve columns ptrs begin
            code = lancedb_table_create_vector_index(
                tbl.handle,
                pointer(ptrs), Csize_t(length(columns)),
                Cint(type), Ref(config), errmsg
            )
        end
        check(code, errmsg)
    end
end

create_vector_index(tbl::Table, column::String; kwargs...) =
    create_vector_index(tbl, [column]; kwargs...)

"""
    create_scalar_index(tbl, column; type=BTree, config=LanceDBScalarIndexConfig())
    create_scalar_index(tbl, columns::Vector{String}; ...)

Build a scalar index on `column` to accelerate SQL `WHERE` filters on that
column. `BTree` (default) suits range and equality queries on numeric or
string columns. Use `Bitmap` for low-cardinality columns and `LabelList`
for list-typed columns.

```julia
create_scalar_index(tbl, "year")
create_scalar_index(tbl, "category"; type=Bitmap)
```
"""
function create_scalar_index(tbl::Table, columns::Vector{String};
                              type::IndexType=BTree,
                              config::LanceDBScalarIndexConfig=LanceDBScalarIndexConfig())
    _assert_live(tbl)
    GC.@preserve tbl begin
        foreach(_check_string, columns)
        ptrs   = [pointer(c) for c in columns]
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve columns ptrs begin
            code = lancedb_table_create_scalar_index(
                tbl.handle,
                pointer(ptrs), Csize_t(length(columns)),
                Cint(type), Ref(config), errmsg
            )
        end
        check(code, errmsg)
    end
end

create_scalar_index(tbl::Table, column::String; kwargs...) =
    create_scalar_index(tbl, [column]; kwargs...)

"""
    create_fts_index(tbl, column; config=LanceDBFtsIndexConfig())
    create_fts_index(tbl, columns::Vector{String}; ...)

Build a full-text search (FTS) index on a UTF-8 string `column`. The index
is named `\${column}_idx`. The current C API supports creating the index but
does not expose a full-text query builder. Tokenization
options (language, stemming, stop words, etc.) are set via
`LanceDBFtsIndexConfig`.

```julia
create_fts_index(tbl, "title")

cfg = LanceDBFtsIndexConfig()
cfg.stem = 1
cfg.remove_stop_words = 1
create_fts_index(tbl, "body"; config=cfg)
```
"""
function create_fts_index(tbl::Table, columns::Vector{String};
                           config::LanceDBFtsIndexConfig=LanceDBFtsIndexConfig(),
                           base_tokenizer::Union{Nothing,AbstractString}=nothing,
                           language::Union{Nothing,AbstractString}=nothing)
    _assert_live(tbl)
    tokenizer_owner = base_tokenizer === nothing ? nothing : String(_check_string(base_tokenizer))
    language_owner = language === nothing ? nothing : String(_check_string(language))
    config = deepcopy(config)
    tokenizer_owner === nothing || (config.base_tokenizer = pointer(tokenizer_owner))
    language_owner === nothing || (config.language = pointer(language_owner))
    GC.@preserve tbl tokenizer_owner language_owner begin
        foreach(_check_string, columns)
        ptrs   = [pointer(c) for c in columns]
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve columns ptrs begin
            code = lancedb_table_create_fts_index(
                tbl.handle,
                pointer(ptrs), Csize_t(length(columns)),
                Ref(config), errmsg
            )
        end
        check(code, errmsg)
    end
end

create_fts_index(tbl::Table, column::String; kwargs...) =
    create_fts_index(tbl, [column]; kwargs...)

"""
    list_indices(tbl) -> Vector{String}

Return the names of all indexes on `tbl`. Index names follow the pattern
`\${column}_idx` (e.g. `"embedding_idx"`, `"year_idx"`).
"""
function list_indices(tbl::Table)::Vector{String}
    _assert_live(tbl)
    GC.@preserve tbl begin
        indices_out = Ref{Ptr{Ptr{UInt8}}}(C_NULL)
        count_out   = Ref{Csize_t}(0)
        errmsg      = Ref{Ptr{UInt8}}(C_NULL)
        code = lancedb_table_list_indices(tbl.handle, indices_out, count_out, errmsg)
        check(code, errmsg)
        n   = count_out[]
        ptr = indices_out[]
        try
            [unsafe_string(unsafe_load(ptr, i)) for i in 1:n]
        finally
            lancedb_free_index_list(ptr, n)
        end
    end
end

"""
    drop_index(tbl, name)

Delete the index named `name` from `tbl`. Throws `LanceDBException` if the
index does not exist. Use `list_indices(tbl)` to find valid names.
"""
function drop_index(tbl::Table, name::AbstractString)
    _assert_live(tbl)
    _check_string(name)
    GC.@preserve tbl begin
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_table_drop_index(tbl.handle, name, errmsg), errmsg)
    end
end

"""
    index_stats(tbl, name) -> LanceDBIndexStats

Return statistics for the index named `name`. The returned struct has three
fields:
- `num_indexed_rows`   — rows covered by the index
- `num_unindexed_rows` — rows added since the last index build (the "delta")
- `num_indices`        — number of index fragments

Call `optimize(tbl; type=OptimizeIndex)` to reduce `num_unindexed_rows` to zero.
"""
function index_stats(tbl::Table, name::AbstractString)::LanceDBIndexStats
    _assert_live(tbl)
    _check_string(name)
    GC.@preserve tbl begin
        stats  = Ref(LanceDBIndexStats(0, 0, 0))
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_table_index_stats(tbl.handle, name, stats, errmsg), errmsg)
        stats[]
    end
end
