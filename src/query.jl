# ── Query ─────────────────────────────────────────────────────────────────────

"""
    Query

Builder for full-table scans. Chainable methods mutate the query in place
(unlike the C builder pattern, which would consume and return a new pointer).

    result = query(tbl) |> filter_where("year > 2020") |> limit(100) |> execute
"""
mutable struct Query
    handle::Ptr{LanceDBQueryHandle}
    _consumed::Bool

    function Query(tbl::Table)
        _assert_live(tbl)
        handle = GC.@preserve tbl lancedb_query_new(tbl.handle)
        check_ptr(handle, "lancedb_query_new returned NULL")
        q = new(handle, false)
        finalizer(close, q)
        q
    end
end

function _assert_live(q::Query)
    q._consumed && throw(LanceDBException(Int32(LANCEDB_RUNTIME), "Query already executed"))
end

"""
    query(tbl) -> Query

Start a full-table scan on `tbl`. Chain builder methods before calling
`execute` to materialise results:

```julia
using DataFrames

result = query(tbl) |> filter_where("year > 2020") |> limit(100) |> execute
df     = DataFrame(result)
```
"""
query(tbl::Table) = Query(tbl)

"""
    limit(q, n) -> Query
    limit(n)    -> Function

Cap the number of rows returned. The single-argument form returns a curried
function suitable for use with `|>`:

```julia
query(tbl) |> limit(10) |> execute
```
"""
function limit(q::Query, n::Integer)::Query
    _assert_live(q)
    errmsg = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve q check(lancedb_query_limit(q.handle, _nonnegative(Csize_t, n), errmsg), errmsg)
    q
end

limit(n::Integer) = q -> limit(q, n)

"""
    offset(q, n) -> Query
    offset(n)    -> Function

Skip the first `n` rows. Combine with `limit` for pagination:

```julia
query(tbl) |> offset(20) |> limit(10) |> execute
```
"""
function offset(q::Query, n::Integer)::Query
    GC.@preserve q begin
        _assert_live(q)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_query_offset(q.handle, _nonnegative(Csize_t, n), errmsg), errmsg)
        q
    end
end

offset(n::Integer) = q -> offset(q, n)

"""
    select_cols(q, cols) -> Query
    select_cols(cols)    -> Function

Restrict the returned columns to `cols` (a `Vector{String}`). Columns not
listed are omitted from the `QueryResult`. The single-argument form is
curried for use with `|>`:

```julia
query(tbl) |> select_cols(["id", "title"]) |> execute
```
"""
function select_cols(q::Query, cols::Vector{String})::Query
    GC.@preserve q begin
        _assert_live(q)
        foreach(_check_string, cols)
        ptrs   = [pointer(c) for c in cols]
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve cols ptrs begin
            code = lancedb_query_select(q.handle, pointer(ptrs), Csize_t(length(cols)), errmsg)
        end
        check(code, errmsg)
        q
    end
end

select_cols(cols::Vector{String}) = q -> select_cols(q, cols)

"""
    filter_where(q, predicate) -> Query

Set a SQL WHERE predicate. If a DataFusion expression is also set it takes
precedence (see `filter_expr`).
"""
function filter_where(q::Query, predicate::AbstractString)::Query
    _check_string(predicate)
    GC.@preserve q begin
        _assert_live(q)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_query_where_filter(q.handle, predicate, errmsg), errmsg)
        q
    end
end

filter_where(predicate::AbstractString) = q -> filter_where(q, predicate)

"""
    filter_expr(q, expr) -> Query

Set a DataFusion `LanceDBExpr` filter. The expr handle is consumed.
"""
function filter_expr(q::Query, expr::LanceDBExpr)::Query
    GC.@preserve q expr begin
        _assert_live(q)
        expr._consumed && throw(LanceDBException(Int32(LANCEDB_RUNTIME), "LanceDBExpr already consumed"))
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code = lancedb_query_df_filter(q.handle, expr.handle, errmsg)
        expr._consumed = true
        expr.handle = C_NULL
        check(code, errmsg)
        q
    end
end

filter_expr(expr::LanceDBExpr) = q -> filter_expr(q, expr)

"""
    execute(q) -> QueryResult

Run the query. Consumes the query handle.
"""
function execute(q::Query)::QueryResult
    GC.@preserve q begin
        _assert_live(q)
        result = lancedb_query_execute(q.handle)
        q._consumed = true
        q.handle = C_NULL
        check_ptr(result, "lancedb_query_execute returned NULL")
        qr = QueryResult(result)
        finalizer(close, qr)
        qr
    end
end

# ── VectorQuery ───────────────────────────────────────────────────────────────

"""
    VectorQuery

Builder for ANN (approximate nearest-neighbour) search.

    result = vector_search(tbl, query_vec, "embedding") |>
             distance_type(Cosine) |>
             nprobes(20) |>
             limit(10) |>
             execute
"""
mutable struct VectorQuery
    handle::Ptr{LanceDBVectorQueryHandle}
    _consumed::Bool

    function VectorQuery(tbl::Table, vec::Vector{Float32}, column::Union{String,Nothing}=nothing)
        _assert_live(tbl)
        column === nothing || _check_string(column)
        isempty(vec) && throw(ArgumentError("query vector cannot be empty"))
        all(isfinite, vec) || throw(ArgumentError("query vector must contain finite Float32 values"))
        GC.@preserve tbl vec begin
            handle = lancedb_vector_query_new(tbl.handle, pointer(vec), Csize_t(length(vec)))
        end
        check_ptr(handle, "lancedb_vector_query_new returned NULL")
        vq = new(handle, false)
        finalizer(close, vq)
        if !isnothing(column)
            errmsg = Ref{Ptr{UInt8}}(C_NULL)
            try
                GC.@preserve vq check(lancedb_vector_query_column(vq.handle, column, errmsg), errmsg)
            catch
                close(vq)
                rethrow()
            end
        end
        vq
    end
end

function _assert_live(vq::VectorQuery)
    vq._consumed && throw(LanceDBException(Int32(LANCEDB_RUNTIME), "VectorQuery already executed"))
end

"""
    vector_search(tbl, vec, column) -> VectorQuery
    vector_search(tbl, vec)         -> VectorQuery

Query inputs are converted to Float32, as required by the lancedb-c search API,
even when the stored vector column uses Float64.

Start an approximate nearest-neighbour (ANN) search for rows whose
`column` embedding is closest to `vec`. Chain builder methods before
calling `execute`:

```julia
using DataFrames

df = DataFrame(
    vector_search(tbl, Float32[0.1, 0.8, 0.3], "embedding") |>
    distance_type(Cosine) |>
    limit(5) |>
    execute
)
println(df._distance)   # ascending L2/cosine distances
```

The result always includes a `_distance` column with the computed distances.
"""
vector_search(tbl::Table, vec::Vector{Float32}, col::String)  = VectorQuery(tbl, vec, col)
vector_search(tbl::Table, vec::Vector{Float32})               = VectorQuery(tbl, vec)

"""
    limit(vq::VectorQuery, n) -> VectorQuery

Return at most `n` nearest neighbours. The single-argument curried form
also works: `vector_search(tbl, vec, "col") |> limit(10) |> execute`.
"""
function limit(vq::VectorQuery, n::Integer)::VectorQuery
    GC.@preserve vq begin
        _assert_live(vq)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_vector_query_limit(vq.handle, _nonnegative(Csize_t, n), errmsg), errmsg)
        vq
    end
end

"""
    distance_type(vq, dt::DistanceType) -> VectorQuery
    distance_type(dt::DistanceType)     -> Function

Set the distance metric for the search. Defaults to `L2`. Available values:
`L2`, `Cosine`, `Dot`, `Hamming`. The single-argument form is curried for `|>`.
"""
function distance_type(vq::VectorQuery, dt::DistanceType)::VectorQuery
    GC.@preserve vq begin
        _assert_live(vq)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_vector_query_distance_type(vq.handle, Cint(dt), errmsg), errmsg)
        vq
    end
end

distance_type(dt::DistanceType) = vq -> distance_type(vq, dt)

"""
    nprobes(vq, n) -> VectorQuery
    nprobes(n)     -> Function

Set the number of IVF partitions probed during an indexed ANN search.
Higher values improve recall at the cost of speed. Only effective when an
IVF-based vector index exists; ignored for flat (un-indexed) search.
The single-argument form is curried for `|>`.
"""
function nprobes(vq::VectorQuery, n::Integer)::VectorQuery
    GC.@preserve vq begin
        _assert_live(vq)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_vector_query_nprobes(vq.handle, _nonnegative(Csize_t, n), errmsg), errmsg)
        vq
    end
end

nprobes(n::Integer) = vq -> nprobes(vq, n)

"""
    refine_factor(vq, k) -> VectorQuery
    refine_factor(k)     -> Function

After the ANN search returns candidates, fetch `k × limit` raw rows and
re-rank them by exact distance. Increases accuracy at the cost of extra
I/O. A value of `1` (the default) disables re-ranking. The single-argument
form is curried for `|>`.
"""
function refine_factor(vq::VectorQuery, k::Integer)::VectorQuery
    GC.@preserve vq begin
        _assert_live(vq)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_vector_query_refine_factor(vq.handle, _nonnegative(Cuint, k), errmsg), errmsg)
        vq
    end
end

refine_factor(k::Integer) = vq -> refine_factor(vq, k)

"""
    ef(vq, n) -> VectorQuery
    ef(n)     -> Function

Set the HNSW `ef` (size of the dynamic candidate list during search).
Higher values improve recall; lower values are faster. Only relevant when
an HNSW-based index is in use. The single-argument form is curried for `|>`.
"""
function ef(vq::VectorQuery, n::Integer)::VectorQuery
    GC.@preserve vq begin
        _assert_live(vq)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_vector_query_ef(vq.handle, _nonnegative(Csize_t, n), errmsg), errmsg)
        vq
    end
end

ef(n::Integer) = vq -> ef(vq, n)

"""
    filter_where(vq::VectorQuery, predicate) -> VectorQuery

Apply a SQL WHERE predicate to the vector search results. Only rows
matching `predicate` are returned even if they would rank in the top-k.
"""
function filter_where(vq::VectorQuery, predicate::AbstractString)::VectorQuery
    _check_string(predicate)
    GC.@preserve vq begin
        _assert_live(vq)
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        check(lancedb_vector_query_where_filter(vq.handle, predicate, errmsg), errmsg)
        vq
    end
end

"""
    filter_expr(vq::VectorQuery, expr::LanceDBExpr) -> VectorQuery

Apply a DataFusion `LanceDBExpr` filter to the vector search results.
The expression handle is consumed. See also the curried form from `Query`:
`filter_expr(expr)` works with `|>` on both `Query` and `VectorQuery`.
"""
function filter_expr(vq::VectorQuery, expr::LanceDBExpr)::VectorQuery
    GC.@preserve vq expr begin
        _assert_live(vq)
        expr._consumed && throw(LanceDBException(Int32(LANCEDB_RUNTIME), "LanceDBExpr already consumed"))
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        code = lancedb_vector_query_df_filter(vq.handle, expr.handle, errmsg)
        expr._consumed = true
        expr.handle = C_NULL
        check(code, errmsg)
        vq
    end
end

"""
    select_cols(vq::VectorQuery, cols) -> VectorQuery

Restrict the returned columns to `cols`. The `_distance` column is always
included even if not listed. The curried `select_cols(cols)` form works
with `|>` on both `Query` and `VectorQuery`.
"""
function select_cols(vq::VectorQuery, cols::Vector{String})::VectorQuery
    GC.@preserve vq begin
        _assert_live(vq)
        foreach(_check_string, cols)
        ptrs   = [pointer(c) for c in cols]
        errmsg = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve cols ptrs begin
            code = lancedb_vector_query_select(vq.handle, pointer(ptrs), Csize_t(length(cols)), errmsg)
        end
        check(code, errmsg)
        vq
    end
end

"""
    execute(vq::VectorQuery) -> QueryResult

Run the vector search and materialise the result. Consumes the query;
calling `execute` again on the same object will throw `LanceDBException`.
"""
function execute(vq::VectorQuery)::QueryResult
    GC.@preserve vq begin
        _assert_live(vq)
        result = lancedb_vector_query_execute(vq.handle)
        vq._consumed = true
        vq.handle = C_NULL
        check_ptr(result, "lancedb_vector_query_execute returned NULL")
        qr = QueryResult(result)
        finalizer(close, qr)
        qr
    end
end
