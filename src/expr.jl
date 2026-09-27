"""
    LanceDBExpr

Wraps a DataFusion expression handle. Expressions are consumed (transferred to
the C side) when passed to binary operators or query filters, so they cannot
be reused after that point.
"""
mutable struct LanceDBExpr
    handle::Ptr{LanceDBExprHandle}
    _consumed::Bool

    function LanceDBExpr(handle::Ptr{LanceDBExprHandle})
        check_ptr(handle, "expression constructor received NULL handle")
        e = new(handle, false)
        finalizer(close, e)
        e
    end
end

function _assert_live(e::LanceDBExpr)
    e._consumed && throw(LanceDBException(Int32(LANCEDB_RUNTIME), "LanceDBExpr already consumed"))
end

function _consume(e::LanceDBExpr)::Ptr{LanceDBExprHandle}
    _assert_live(e)
    e._consumed = true
    handle = e.handle
    e.handle = C_NULL
    handle
end

# ── Constructors ──────────────────────────────────────────────────────────────

"""
    col(name) -> LanceDBExpr

Create a column reference expression. Use this as the left-hand side of
comparisons in the expression DSL:

```julia
col("year") > lit(2020)
```
"""
col(name::AbstractString)::LanceDBExpr    = LanceDBExpr(lancedb_expr_column(_check_string(name)))

"""
    lit(v) -> LanceDBExpr

Wrap a Julia scalar as a literal expression. Supported types: `AbstractString`,
`Integer` (stored as Int64), `AbstractFloat` (stored as Float64), `Bool`.

```julia
lit("Dune")      # string literal
lit(2021)        # integer literal
lit(7.5f0)       # float literal (promoted to Float64)
```
"""
lit(v::AbstractString)::LanceDBExpr       = LanceDBExpr(lancedb_expr_literal_string(_check_string(v)))
lit(v::Integer)::LanceDBExpr              = LanceDBExpr(lancedb_expr_literal_i64(Int64(v)))
lit(v::AbstractFloat)::LanceDBExpr        = LanceDBExpr(lancedb_expr_literal_f64(Float64(v)))
lit(v::Bool)::LanceDBExpr                 = LanceDBExpr(lancedb_expr_literal_bool(v))

"""
    copy(e::LanceDBExpr) -> LanceDBExpr

Clone an expression so it can be used in more than one filter position.
Each `LanceDBExpr` is consumed on first use; `copy` produces an independent
handle that can be passed to a second filter without error.

```julia
base = col("year") > lit(2015)
e1   = copy(base) & (col("rating") > lit(7.8f0))
e2   = copy(base) & (col("rating") < lit(7.0f0))
```
"""
function Base.copy(e::LanceDBExpr)::LanceDBExpr
    GC.@preserve e begin
        _assert_live(e)
        LanceDBExpr(lancedb_expr_clone(e.handle))
    end
end

function _consume_all(expressions)
    seen = IdDict{LanceDBExpr,Nothing}()
    for e in expressions
        _assert_live(e)
        haskey(seen, e) && throw(ArgumentError("an expression cannot be consumed twice; use copy(expr)"))
        seen[e] = nothing
    end
    handles = [e.handle for e in expressions]
    for e in expressions
        e._consumed = true
        e.handle = C_NULL
    end
    handles
end

# ── Unary operators ───────────────────────────────────────────────────────────

Base.:!(e::LanceDBExpr)::LanceDBExpr      = LanceDBExpr(lancedb_expr_not(_consume(e)))

"""
    isnull(e::LanceDBExpr) -> LanceDBExpr

Build an `IS NULL` predicate. `e` is consumed.

```julia
filter_expr(col("title") |> isnull)     # rows where title IS NULL
```
"""
isnull(e::LanceDBExpr)::LanceDBExpr       = LanceDBExpr(lancedb_expr_is_null(_consume(e)))

"""
    isnotnull(e::LanceDBExpr) -> LanceDBExpr

Build an `IS NOT NULL` predicate. `e` is consumed.

```julia
query(tbl) |> filter_expr(isnotnull(col("title"))) |> execute
```
"""
isnotnull(e::LanceDBExpr)::LanceDBExpr    = LanceDBExpr(lancedb_expr_is_not_null(_consume(e)))

# ── Binary operators ──────────────────────────────────────────────────────────

function _binary(a::LanceDBExpr, op::BinaryOp, b::LanceDBExpr)::LanceDBExpr
    GC.@preserve a b begin
        handles = _consume_all((a, b))
        LanceDBExpr(lancedb_expr_binary(handles[1], Cint(op), handles[2]))
    end
end

Base.:(==)(a::LanceDBExpr, b::LanceDBExpr) = _binary(a, OpEq, b)
Base.:!=(a::LanceDBExpr, b::LanceDBExpr)   = _binary(a, OpNotEq, b)
Base.:<(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpLt, b)
Base.:<=(a::LanceDBExpr, b::LanceDBExpr)   = _binary(a, OpLtEq, b)
Base.:>(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpGt, b)
Base.:>=(a::LanceDBExpr, b::LanceDBExpr)   = _binary(a, OpGtEq, b)
Base.:&(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpAnd, b)
Base.:|(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpOr, b)
Base.:+(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpPlus, b)
Base.:-(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpMinus, b)
Base.:*(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpMultiply, b)
Base.:/(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpDivide, b)
Base.:%(a::LanceDBExpr, b::LanceDBExpr)    = _binary(a, OpModulo, b)

# ── In-list operators ─────────────────────────────────────────────────────────

"""
    isin(expr, values...) -> LanceDBExpr

Build an IN-list predicate. `expr` and all `values` are consumed.

    isin(col("label"), lit("cat"), lit("dog"))
"""
function isin(expr::LanceDBExpr, values::LanceDBExpr...)::LanceDBExpr
    GC.@preserve expr values begin
        isempty(values) && throw(ArgumentError("isin requires at least one value"))
        all_handles = _consume_all((expr, values...))
        handles = all_handles[2:end]
        list    = Ptr{Ptr{LanceDBExprHandle}}(pointer(handles))
        errmsg  = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve handles begin
            result = lancedb_expr_in_list(all_handles[1], list, Csize_t(length(handles)), false, errmsg)
        end
        result == C_NULL && check(Int32(LANCEDB_RUNTIME), errmsg)
        LanceDBExpr(result)
    end
end

"""
    notiin(expr, values...) -> LanceDBExpr

Build a NOT IN-list predicate. `expr` and all `values` are consumed.
"""
function notiin(expr::LanceDBExpr, values::LanceDBExpr...)::LanceDBExpr
    GC.@preserve expr values begin
        isempty(values) && throw(ArgumentError("notiin requires at least one value"))
        all_handles = _consume_all((expr, values...))
        handles = all_handles[2:end]
        list    = Ptr{Ptr{LanceDBExprHandle}}(pointer(handles))
        errmsg  = Ref{Ptr{UInt8}}(C_NULL)
        GC.@preserve handles begin
            result = lancedb_expr_in_list(all_handles[1], list, Csize_t(length(handles)), true, errmsg)
        end
        result == C_NULL && check(Int32(LANCEDB_RUNTIME), errmsg)
        LanceDBExpr(result)
    end
end
