# Opaque C handle types — match the typedefs in lancedb.h.
# Each primitive type is a distinct 64-bit word, giving the Julia type system
# visibility into what a pointer refers to without exposing arithmetic.

primitive type LanceDBConnectBuilderHandle 64 end
primitive type LanceDBConnectionHandle     64 end
primitive type LanceDBTableHandle          64 end
primitive type LanceDBTableNamesBuilderHandle 64 end
primitive type LanceDBQueryHandle          64 end
primitive type LanceDBVectorQueryHandle    64 end
primitive type LanceDBQueryResultHandle    64 end
primitive type LanceDBExprHandle           64 end
primitive type LanceDBSessionHandle        64 end
primitive type LanceDBRecordBatchReaderHandle 64 end

# ── Enums ─────────────────────────────────────────────────────────────────────

@enum LanceDBError::Int32 begin
    LANCEDB_SUCCESS                    = 0
    LANCEDB_INVALID_ARGUMENT           = 1
    LANCEDB_INVALID_TABLE_NAME         = 2
    LANCEDB_INVALID_INPUT              = 3
    LANCEDB_TABLE_NOT_FOUND            = 4
    LANCEDB_DATABASE_NOT_FOUND         = 5
    LANCEDB_DATABASE_ALREADY_EXISTS    = 6
    LANCEDB_INDEX_NOT_FOUND            = 7
    LANCEDB_EMBEDDING_FUNCTION_NOT_FOUND = 8
    LANCEDB_TABLE_ALREADY_EXISTS       = 9
    LANCEDB_CREATE_DIR                 = 10
    LANCEDB_SCHEMA                     = 11
    LANCEDB_RUNTIME                    = 12
    LANCEDB_TIMEOUT                    = 13
    LANCEDB_OBJECT_STORE               = 14
    LANCEDB_LANCE                      = 15
    LANCEDB_HTTP                       = 16
    LANCEDB_RETRY                      = 17
    LANCEDB_ARROW                      = 18
    LANCEDB_NOT_SUPPORTED              = 19
    LANCEDB_OTHER                      = 20
    LANCEDB_NAMESPACE                  = 21
    LANCEDB_PERMISSION_DENIED          = 22
    LANCEDB_NOT_FOUND                  = 23
    LANCEDB_UNKNOWN                    = 99
end

"""
    DistanceType

Distance metric used for vector search.

- `L2`      — Euclidean (L2) distance (default)
- `Cosine`  — cosine similarity (good for normalized embeddings)
- `Dot`     — dot-product distance
- `Hamming` — Hamming distance (binary vectors)
"""
@enum DistanceType::Int32 begin
    L2      = 0
    Cosine  = 1
    Dot     = 2
    Hamming = 3
end

"""
    IndexType

Type of index to create.

Vector index types (used with `create_vector_index`):
- `Auto`      — let LanceDB choose (default)
- `IVFFlat`   — inverted file with flat quantization
- `IVFPQ`     — inverted file with product quantization
- `IVFHNSWpq` — IVF + HNSW + product quantization
- `IVFHNSWsq` — IVF + HNSW + scalar quantization

Scalar index types (used with `create_scalar_index`):
- `BTree`     — B-tree index for range/equality queries (default)
- `Bitmap`    — bitmap index for low-cardinality columns
- `LabelList` — index for list-typed columns

Full-text index (used with `create_fts_index`):
- `FTS`       — full-text search index
"""
@enum IndexType::Int32 begin
    Auto      = 0
    BTree     = 1
    Bitmap    = 2
    LabelList = 3
    FTS       = 4
    IVFFlat   = 5
    IVFPQ     = 6
    IVFHNSWpq = 7
    IVFHNSWsq = 8
end

"""
    OptimizeType

Controls which optimization pass `optimize` runs.

- `OptimizeAll`     — run all optimizations (default)
- `OptimizeCompact` — compact small files into larger ones
- `OptimizePrune`   — delete files belonging to old versions
- `OptimizeIndex`   — re-index rows added since the last index build
"""
@enum OptimizeType::Int32 begin
    OptimizeAll     = 0
    OptimizeCompact = 1
    OptimizePrune   = 2
    OptimizeIndex   = 3
end

@enum BinaryOp::Int32 begin
    OpEq       = 0
    OpNotEq    = 1
    OpLt       = 2
    OpLtEq     = 3
    OpGt       = 4
    OpGtEq     = 5
    OpAnd      = 6
    OpOr       = 7
    OpPlus     = 8
    OpMinus    = 9
    OpMultiply = 10
    OpDivide   = 11
    OpModulo   = 12
end

# ── C value-type structs ───────────────────────────────────────────────────────

"""
    LanceDBVectorIndexConfig()

Configuration for `create_vector_index`. Construct with the zero-argument
constructor and mutate the fields you want to override before passing to
`create_vector_index`.

# Fields
- `num_partitions`  — number of IVF partitions; default `-1` (auto, ≈ √n)
- `num_sub_vectors` — number of PQ sub-vectors (PQ/HNSW variants); default `-1` (auto)
- `max_iterations`  — k-means training iterations; default `-1` (auto)
- `sample_rate`     — fraction of rows used for training; `0.0` means auto
- `distance_type`   — `DistanceType` enum value, default `L2`
- `replace`         — `1` to replace an existing index, `0` to error if one exists

```julia
cfg = LanceDBVectorIndexConfig()
cfg.num_partitions = 16
create_vector_index(tbl, "embedding"; type=IVFFlat, config=cfg)
```
"""
mutable struct LanceDBVectorIndexConfig
    num_partitions::Cint
    num_sub_vectors::Cint
    max_iterations::Cint
    sample_rate::Cfloat
    distance_type::Cint   # DistanceType
    replace::Cint
end

LanceDBVectorIndexConfig(; num_partitions=-1, num_sub_vectors=-1, max_iterations=-1,
                        sample_rate=0.0f0, distance_type::DistanceType=L2, replace::Bool=false) =
    LanceDBVectorIndexConfig(num_partitions, num_sub_vectors, max_iterations,
                            sample_rate, Int32(distance_type), Int(replace))

"""
    LanceDBScalarIndexConfig()

Configuration for `create_scalar_index`.

# Fields
- `replace`                  — `1` to replace an existing index
"""
mutable struct LanceDBScalarIndexConfig
    replace::Cint
end

LanceDBScalarIndexConfig(; replace::Bool=false) = LanceDBScalarIndexConfig(Int(replace))

"""
    LanceDBFtsIndexConfig()

Configuration for `create_fts_index`.

# Fields
- `base_tokenizer`   — tokenizer name (C_NULL → `"simple"`)
- `language`         — language for stemming/stop-words (C_NULL → `"English"`)
- `max_token_length` — maximum token length; `-1` means no limit
- `lowercase`        — `1` to lowercase tokens before indexing (default)
- `stem`             — `1` to apply stemming
- `remove_stop_words`— `1` to drop common stop words
- `ascii_folding`    — `1` to normalize accented characters to ASCII
- `replace`          — `1` to replace an existing index
"""
mutable struct LanceDBFtsIndexConfig
    base_tokenizer::Ptr{UInt8}
    language::Ptr{UInt8}
    max_token_length::Cint
    lowercase::Cint
    stem::Cint
    remove_stop_words::Cint
    ascii_folding::Cint
    replace::Cint
end

LanceDBFtsIndexConfig() = LanceDBFtsIndexConfig(C_NULL, C_NULL, -1, 1, 0, 0, 0, 0)

"""
    LanceDBMergeInsertConfig()

Configuration for `merge_insert` (upsert). Both flags default to `1`,
which is the standard upsert behaviour.

# Fields
- `when_matched_update_all`    — `1` to overwrite every column of a matching row
- `when_not_matched_insert_all`— `1` to insert rows whose key is not found
- `when_matched_update_all_condition` — optional C string containing a SQL condition
- `when_matched_update_all_expr` — optional expression handle (alternative to SQL)

Both condition pointers default to NULL. If setting either pointer directly,
keep its owning string or expression alive with `GC.@preserve` for the entire
`merge_insert` call. The expression is borrowed, not consumed.
"""
mutable struct LanceDBMergeInsertConfig
    when_matched_update_all::Cint
    when_not_matched_insert_all::Cint
    when_matched_update_all_condition::Ptr{UInt8}
    when_matched_update_all_expr::Ptr{LanceDBExprHandle}
end

LanceDBMergeInsertConfig(update::Integer, insert::Integer) =
    LanceDBMergeInsertConfig(update, insert, C_NULL, C_NULL)
LanceDBMergeInsertConfig() = LanceDBMergeInsertConfig(1, 1)

"""
    LanceDBSessionOptions()

Session-level cache configuration passed to `Connection`.

# Fields
- `index_cache_bytes`    — maximum bytes for the vector index cache; `0` uses the library default
- `metadata_cache_bytes` — maximum bytes for the metadata cache; `0` uses the library default
"""
mutable struct LanceDBSessionOptions
    index_cache_bytes::Csize_t
    metadata_cache_bytes::Csize_t
end

LanceDBSessionOptions() = LanceDBSessionOptions(0, 0)

mutable struct LanceDBSessionCacheStats
    hits::UInt64
    misses::UInt64
    num_entries::Csize_t
    size_bytes::Csize_t
end

struct LanceDBVersion
    version::UInt64
    timestamp_seconds::Int64
    timestamp_nanos::UInt32
end

struct LanceDBVersionMetadata
    keys::Ptr{Ptr{UInt8}}
    values::Ptr{Ptr{UInt8}}
    count::Csize_t
end

mutable struct LanceDBIndexStats
    num_indexed_rows::Csize_t
    num_unindexed_rows::Csize_t
    num_indices::Cuint
end
