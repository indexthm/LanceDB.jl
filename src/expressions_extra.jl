col(name::Symbol) = col(String(name))

# Keep the explicit lit API, while allowing Julia scalar syntax in predicates.
const ExprScalar = Union{AbstractString,Integer,AbstractFloat}
for op in (:(==), :(!=), :<, :<=, :>, :>=, :+, :-, :*, :/, :%)
    @eval begin
        function Base.$op(a::LanceDBExpr, b::ExprScalar)
            _assert_live(a)
            Base.$op(a, lit(b))
        end
        function Base.$op(a::ExprScalar, b::LanceDBExpr)
            _assert_live(b)
            Base.$op(lit(a), b)
        end
    end
end

"""`delete_rows(table, expr::LanceDBExpr)` deletes matching rows, consuming the expression."""
function delete_rows(tbl::Table, expr::LanceDBExpr)
    _assert_live(tbl)
    _assert_live(expr)
    err = Ref{Ptr{UInt8}}(C_NULL)
    GC.@preserve tbl expr begin
        handle = _consume(expr)
        check(ccall((:lancedb_table_df_delete, liblancedb), Cint,
            (Ptr{LanceDBTableHandle}, Ptr{LanceDBExprHandle}, Ref{Ptr{UInt8}}), tbl.handle, handle, err), err)
    end
    nothing
end

"""`array_has(array_expr, value_expr)` builds an array-membership predicate; both inputs are consumed."""
function array_has(array::LanceDBExpr, value::LanceDBExpr)
    err = Ref{Ptr{UInt8}}(C_NULL)
    handles = _consume_all((array, value))
    result = ccall((:lancedb_expr_array_has, liblancedb), Ptr{LanceDBExprHandle},
        (Ptr{LanceDBExprHandle}, Ptr{LanceDBExprHandle}, Ref{Ptr{UInt8}}), handles[1], handles[2], err)
    result == C_NULL && check(Int32(LANCEDB_RUNTIME), err)
    LanceDBExpr(result)
end

for fn in (:json_get_str, :json_get_int, :json_get_float, :json_get_bool, :json_contains)
    native = Symbol(:lancedb_expr_, fn)
    @eval begin
        function $fn(expr::LanceDBExpr, path::AbstractVector{<:AbstractString})
            _assert_live(expr)
            names = _strings(path)
            ptrs = _cstring_ptrs(names)
            GC.@preserve names ptrs begin
                handle = _consume(expr)
                LanceDBExpr(ccall(($(QuoteNode(native)), liblancedb), Ptr{LanceDBExprHandle},
                    (Ptr{LanceDBExprHandle}, Ptr{Ptr{UInt8}}, Csize_t), handle, ptrs, length(names)))
            end
        end
        $fn(expr::LanceDBExpr, path::AbstractString...) = $fn(expr, collect(path))
    end
end

"""`json_array_has(expr, path, value; quote_value=true)` builds a JSON array membership
predicate. `path` is a vector of string keys. Both expressions are consumed;
set `quote_value=false` for numeric or boolean JSON literals."""
function json_array_has(expr::LanceDBExpr, path::AbstractVector{<:AbstractString},
                        value::LanceDBExpr; quote_value::Bool=true)
    names = _strings(path)
    ptrs = _cstring_ptrs(names)
    GC.@preserve names ptrs begin
        handles = _consume_all((expr, value))
        LanceDBExpr(ccall((:lancedb_expr_json_array_has, liblancedb), Ptr{LanceDBExprHandle},
            (Ptr{LanceDBExprHandle}, Ptr{Ptr{UInt8}}, Csize_t, Ptr{LanceDBExprHandle}, Bool),
            handles[1], ptrs, length(names), handles[2], quote_value))
    end
end

"""Extract a string at a JSON key path. Consumes `expr`."""
json_get_str
"""Extract an Int64 at a JSON key path. Consumes `expr`."""
json_get_int
"""Extract a Float64 at a JSON key path. Consumes `expr`."""
json_get_float
"""Extract a Bool at a JSON key path. Consumes `expr`."""
json_get_bool
"""Test existence of a JSON key path. Consumes `expr`."""
json_contains
