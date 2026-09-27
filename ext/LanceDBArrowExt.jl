module LanceDBArrowExt

using LanceDB, Arrow

const Primitive = Union{Int8,UInt8,Int16,UInt16,Int32,UInt32,Int64,UInt64,Float32,Float64}

# Borrow physical buffers only when their type also describes the logical values.
# Keeping the Arrow column alive retains its IPC buffer, including mmap owners.
function LanceDB._column_to_arrow(col::Arrow.Primitive{T}, name, pins) where T
    if T <: Primitive && col.data isa Vector{T} && length(col.data) == length(col)
        push!(pins, col)
        return LanceDB._column_to_arrow(col.data, name, pins)
    end
    invoke(LanceDB._column_to_arrow, Tuple{Any,Any,Any}, col, name, pins)
end

function LanceDB._column_to_arrow(col::Arrow.List{T,O}, name, pins) where {T,O}
    S = Base.nonmissingtype(T)
    push!(pins, col)
    offsets = Ptr{Cvoid}(pointer(col.offsets.offsets))
    if S <: AbstractString || S <: Base.CodeUnits
        fmt = S <: AbstractString ? (O === Int64 ? "U" : "u") : (O === Int64 ? "Z" : "z")
        return LanceDB._nested_arrow(col, name, fmt, pins,
            Ptr{LanceDB.ArrowArray}[], Ptr{LanceDB.ArrowSchema}[],
            Ptr{Cvoid}[offsets, pointer(col.data)])
    elseif S <: AbstractVector
        child, schema = LanceDB._column_to_arrow(col.data, "item", pins)
        return LanceDB._nested_arrow(col, name, O === Int64 ? "+L" : "+l", pins,
            [child], [schema], Ptr{Cvoid}[offsets])
    end
    invoke(LanceDB._column_to_arrow, Tuple{Any,Any,Any}, col, name, pins)
end

function LanceDB._column_to_arrow(col::Arrow.FixedSizeList{T}, name, pins) where T
    S = Base.nonmissingtype(T)
    # Custom Arrow extension types need their own logical conversion.
    S <: Tuple || return invoke(LanceDB._column_to_arrow, Tuple{Any,Any,Any}, col, name, pins)
    width = fieldcount(S)
    width > 0 || throw(ArgumentError("fixed-size lists must have positive dimension"))
    push!(pins, col)
    # Arrow.jl uses a raw byte vector for FixedSizeBinary and an ArrowVector for lists.
    if col.data isa Vector{UInt8}
        return LanceDB._nested_arrow(col, name, "w:$width", pins,
            Ptr{LanceDB.ArrowArray}[], Ptr{LanceDB.ArrowSchema}[],
            Ptr{Cvoid}[pointer(col.data)])
    end
    child, schema = LanceDB._column_to_arrow(col.data, "item", pins)
    LanceDB._nested_arrow(col, name, "+w:$width", pins, [child], [schema], Ptr{Cvoid}[])
end

function LanceDB._column_to_arrow(col::Arrow.Struct{T}, name, pins) where T
    S = Base.nonmissingtype(T)
    S <: NamedTuple || return invoke(LanceDB._column_to_arrow, Tuple{Any,Any,Any}, col, name, pins)
    push!(pins, col)
    arrays, schemas = Ptr{LanceDB.ArrowArray}[], Ptr{LanceDB.ArrowSchema}[]
    try
        for (field, values) in zip(fieldnames(S), col.data)
            array, schema = LanceDB._column_to_arrow(values, String(field), pins)
            push!(arrays, array)
            push!(schemas, schema)
        end
    catch
        foreach(LanceDB._free_array_tree, arrays)
        foreach(LanceDB.release_arrow_schema, schemas)
        rethrow()
    end
    LanceDB._nested_arrow(col, name, "+s", pins, arrays, schemas, Ptr{Cvoid}[])
end

end
