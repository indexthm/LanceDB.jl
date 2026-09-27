module LanceDB

using Arrow
using Tables
using Dates
import LanceDB_C_jll

# ── Library path ──────────────────────────────────────────────────────────────
# Override by setting LANCEDB_LIB environment variable before loading the module.
const liblancedb = let
    from_env = get(ENV, "LANCEDB_LIB", "")
    if !isempty(from_env)
        from_env
    else
        LanceDB_C_jll.liblancedb
    end
end

# ── Source includes (order matters) ──────────────────────────────────────────
include("ctypes.jl")      # primitive handle types, enums, C value-type structs
include("api.jl")         # raw ccall wrappers matching the published C ABI
include("error.jl")       # LanceDBException, check(), check_ptr()
include("arrow_abi.jl")   # ArrowSchema / ArrowArray layout + schema builders
include("arrow_data.jl")  # Tables.jl → Arrow C ABI (_to_arrow_c_abi, _make_reader)
include("column_types.jl")
include("connection.jl")  # Connection, open_table, create_table, drop_table
include("table.jl")       # Table, count_rows, add, delete_rows, merge_insert
include("result.jl")      # QueryResult (Tables.jl interface)
include("expr.jl")        # LanceDBExpr DSL (must precede query.jl)
include("query.jl")       # Query, VectorQuery, execute — references LanceDBExpr
include("index.jl")       # create_vector_index, create_scalar_index, etc.
include("resources.jl")
include("management.jl")
include("expressions_extra.jl")

# ── Exports ───────────────────────────────────────────────────────────────────

# Types
export BinaryColumn, ListColumn
export Connection, Table, TableSink, Query, VectorQuery, QueryResult, LanceDBExpr
export LanceDBException

# C config structs (users may need to construct these)
export LanceDBVectorIndexConfig, LanceDBScalarIndexConfig, LanceDBFtsIndexConfig
export LanceDBMergeInsertConfig, LanceDBSessionOptions

# Arrow C ABI helpers (for building schemas to pass to create_table)
export make_schema, make_vector_schema, release_arrow_schema, ArrowSchema

# Enums
export DistanceType, IndexType, OptimizeType
export L2, Cosine, Dot, Hamming
export Auto, BTree, Bitmap, LabelList, FTS, IVFFlat, IVFPQ, IVFHNSWpq, IVFHNSWsq
export OptimizeAll, OptimizeCompact, OptimizePrune, OptimizeIndex

# Connection operations
export uri, table_names, open_table, create_table, drop_table, reopen!

# Table operations
export count_rows, table_version, delete_rows, add, merge_insert, optimize
export append_partitions!
export Session, table_schema, get_metadata, set_metadata!, delete_metadata!, list_versions, cache_stats, explain_plan
export rename_table, drop_all_tables, create_namespace, drop_namespace, list_namespaces
export array_has, json_get_str, json_get_int, json_get_float, json_get_bool, json_contains, json_array_has

# Query building
export query, vector_search, execute
export filter_where, filter_expr, select_cols, limit, offset
export distance_type, nprobes, refine_factor, ef

# Expression DSL
export col, lit, isnull, isnotnull, isin, notiin

# Index management
export create_vector_index, create_scalar_index, create_fts_index
export list_indices, drop_index, index_stats

end # module LanceDB
