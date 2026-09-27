Base.isopen(tbl::Table) = tbl.handle != C_NULL
Base.isopen(qr::QueryResult) = qr.handle != C_NULL
Base.isopen(q::Union{Query,VectorQuery,LanceDBExpr}) = !q._consumed && q.handle != C_NULL

function _assert_live(obj::Union{Connection,Table})
    isopen(obj) || throw(LanceDBException(Int32(LANCEDB_RUNTIME), "$(nameof(typeof(obj))) is closed"))
    nothing
end

for (T, free) in ((Query, :lancedb_query_free), (VectorQuery, :lancedb_vector_query_free),
                  (LanceDBExpr, :lancedb_expr_free))
    @eval function Base.close(obj::$T)
        isopen(obj) || return nothing
        handle = obj.handle
        obj.handle = C_NULL
        obj._consumed = true
        $free(handle)
        nothing
    end
end

function Base.open(f::Function, ::Type{Table}, conn::Connection, name::AbstractString)
    table = open_table(conn, name)
    try
        f(table)
    finally
        close(table)
    end
end

function _check_string(s::AbstractString)
    occursin('\0', s) && throw(ArgumentError("C strings cannot contain NUL"))
    s
end

# Conversion to a C integer should not be the user-visible validation error.
function _nonnegative(::Type{T}, n::Integer) where T<:Unsigned
    0 <= n <= typemax(T) || throw(ArgumentError("value must be between 0 and $(typemax(T))"))
    T(n)
end

select_cols(q::Union{Query,VectorQuery}, cols::AbstractVector{Symbol}) = select_cols(q, string.(cols))
select_cols(cols::AbstractVector{Symbol}) = q -> select_cols(q, cols)
vector_search(tbl::Table, vec::AbstractVector{<:Real}, column::Union{AbstractString,Symbol}) =
    VectorQuery(tbl, vec isa Vector{Float32} ? vec : Float32.(vec), String(column))
vector_search(tbl::Table, vec::AbstractVector{<:Real}) = VectorQuery(tbl, Float32.(vec))

# The native merge condition is borrowed. Keep a Julia owner alive instead of
# requiring callers to install raw pointers in a mutable C configuration.
function _merge_condition(config::LanceDBMergeInsertConfig, condition)
    condition === nothing && return config, nothing
    config.when_matched_update_all_condition == C_NULL && config.when_matched_update_all_expr == C_NULL ||
        throw(ArgumentError("use either condition or raw config condition pointers"))
    config = deepcopy(config)
    if condition isa AbstractString
        owner = String(_check_string(condition))
        config.when_matched_update_all_condition = pointer(owner)
    elseif condition isa LanceDBExpr
        _assert_live(condition)
        owner = condition
        config.when_matched_update_all_expr = condition.handle
    else
        throw(ArgumentError("condition must be a SQL string or LanceDBExpr"))
    end
    config, owner
end

for fn in (:create_vector_index, :create_scalar_index, :create_fts_index)
    @eval begin
        $fn(tbl::Table, column::Symbol; kwargs...) = $fn(tbl, String(column); kwargs...)
        $fn(tbl::Table, columns::AbstractVector{Symbol}; kwargs...) = $fn(tbl, string.(columns); kwargs...)
    end
end
merge_insert(tbl::Table, data, columns::AbstractVector{Symbol}; kwargs...) =
    merge_insert(tbl, data, string.(columns); kwargs...)
merge_insert(tbl::Table, data, column::Symbol; kwargs...) =
    merge_insert(tbl, data, String(column); kwargs...)

"""
    append_partitions!(table, source)

Append each `Tables.partitions(source)` batch separately and return `table`.
Only one input partition is converted at a time. Each append commits its own
version: a failure leaves earlier partitions committed (not an atomic transaction).
"""
function append_partitions!(tbl::Table, source)
    _assert_live(tbl)
    for part in Tables.partitions(source)
        add(tbl, part)
    end
    tbl
end

select_cols(q::Union{Query,VectorQuery}, cols::AbstractVector{<:AbstractString}) = select_cols(q, String.(cols))
select_cols(cols::AbstractVector{<:AbstractString}) = q -> select_cols(q, cols)
select_cols(q::Union{Query,VectorQuery}, first::Symbol, rest::Symbol...) = select_cols(q, [first, rest...])
select_cols(first::Symbol, rest::Symbol...) = q -> select_cols(q, first, rest...)
