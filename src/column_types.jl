"""
    BinaryColumn(values; large=false)

Mark a column of byte vectors (optionally `missing`) as Arrow Binary rather
than a numeric list. Use `large=true` for 64-bit offsets (LargeBinary).
Values are borrowed during synchronous ingestion; do not mutate them then.
"""
struct BinaryColumn{T,V<:AbstractVector{T},O} <: AbstractVector{T}
    values::V
end
function BinaryColumn(values::AbstractVector{T}; large::Bool=false) where T
    Base.nonmissingtype(T) !== Union{} && Base.nonmissingtype(T) <: AbstractVector{UInt8} ||
        throw(ArgumentError("BinaryColumn requires byte vectors, optionally missing"))
    BinaryColumn{T,typeof(values),large ? Int64 : Int32}(values)
end

"""
    ListColumn(values; large=false)

Mark a column of vectors as variable-length Arrow lists, including empty lists.
Unwrapped vectors retain fixed-size embedding semantics. Element types must be
concrete enough to infer the child schema, even for an empty column.
"""
struct ListColumn{T,V<:AbstractVector{T},O} <: AbstractVector{T}
    values::V
end
function ListColumn(values::AbstractVector{T}; large::Bool=false) where T
    Base.nonmissingtype(T) !== Union{} && Base.nonmissingtype(T) <: AbstractVector || throw(ArgumentError("ListColumn requires vectors"))
    ListColumn{T,typeof(values),large ? Int64 : Int32}(values)
end

for C in (:BinaryColumn, :ListColumn)
    @eval begin
        Base.size(c::$C) = size(c.values)
        Base.getindex(c::$C, i::Int) = c.values[i]
        Base.IndexStyle(::Type{<:$C}) = IndexLinear()
        _large(::$(C){T,V,O}) where {T,V,O} = O === Int64
        Base.getindex(c::$C, inds::AbstractVector{<:Integer}) = $C(c.values[inds]; large=_large(c))
        Base.getindex(c::$C, ::Colon) = copy(c)
        Base.copy(c::$C) = $C(copy(c.values); large=_large(c))
        Base.push!(c::$C, value) = (push!(c.values,value); c)
        Base.vcat(a::$C, b::$C, rest::$C...) =
            $C(vcat(a.values,b.values,(x.values for x in rest)...); large=any(_large,(a,b,rest...)))
    end
end

# Takes ownership of children and their schemas, including on failure.
function _nested_arrow(col, name, fmt, pins, arrays, schemas, buffer_values)
    schema = Ptr{ArrowSchema}(C_NULL)
    arr = Ptr{ArrowArray}(C_NULL)
    ap = Ptr{Ptr{ArrowArray}}(C_NULL)
    bp = Ptr{Ptr{Cvoid}}(C_NULL)
    attached = false
    try
        validity, nulls = _validity(col, pins)
        schema = _alloc_leaf_schema(fmt, name)
        sp = isempty(schemas) ? Ptr{Ptr{ArrowSchema}}(C_NULL) :
             Ptr{Ptr{ArrowSchema}}(_checked_malloc(sizeof(Ptr{Cvoid})*length(schemas)))
        for (i,s) in enumerate(schemas)
            unsafe_store!(sp,s,i)
        end
        s = unsafe_load(schema)
        unsafe_store!(schema, ArrowSchema(s.format,s.name,C_NULL,Missing <: eltype(col) ? 2 : 0,
            length(schemas),sp,C_NULL,C_NULL,C_NULL))
        attached = true
        ap = _alloc_child_ptrs(arrays)
        bp = _alloc_buf_ptrs(Ptr{Cvoid}[validity; buffer_values])
        arr = _heap_array(ArrowArray(length(col),nulls,0,1+length(buffer_values),length(arrays),
            bp,ap,C_NULL,C_NULL,C_NULL))
        return arr,schema
    catch
        schema == C_NULL || release_arrow_schema(schema)
        attached || foreach(release_arrow_schema,schemas)
        if arr == C_NULL
            foreach(_free_array_tree,arrays)
            ap == C_NULL || Libc.free(ap)
            bp == C_NULL || Libc.free(bp)
        else
            _free_array_tree(arr)
        end
        rethrow()
    end
end

function _column_to_arrow(col::BinaryColumn{T,V,O}, name, pins) where {T,V,O}
    offsets = O[0]
    for v in col
        push!(offsets,Base.checked_add(last(offsets), O(ismissing(v) ? 0 : length(v))))
    end
    bytes = Vector{UInt8}(undef,Int(last(offsets)))
    for (i,v) in enumerate(col)
        ismissing(v) || copyto!(bytes,Int(offsets[i])+1,v,1,length(v))
    end
    push!(pins,bytes,offsets)
    _nested_arrow(col,name,O === Int64 ? "Z" : "z",pins,
        Ptr{ArrowArray}[],Ptr{ArrowSchema}[],Ptr{Cvoid}[pointer(offsets),pointer(bytes)])
end

function _column_to_arrow(col::ListColumn{T,V,O}, name, pins) where {T,V,O}
    ET = eltype(Base.nonmissingtype(T))
    flat = Vector{ET}()
    offsets = O[0]
    for v in col
        ismissing(v) || append!(flat,v)
        push!(offsets,O(length(flat)))
    end
    push!(pins,flat,offsets)
    child,cs = _column_to_arrow(flat,"item",pins)
    _nested_arrow(col,name,O === Int64 ? "+L" : "+l",pins,[child],[cs],Ptr{Cvoid}[pointer(offsets)])
end

function _struct_column_to_arrow(col, name, pins, ::Type{T}) where T<:NamedTuple
    isconcretetype(T) || throw(ArgumentError("nested records require a concrete NamedTuple type"))
    arrays, schemas = Ptr{ArrowArray}[], Ptr{ArrowSchema}[]
    sizehint!(arrays,fieldcount(T)); sizehint!(schemas,fieldcount(T))
    try
        for (i,nm) in enumerate(fieldnames(T))
            FT = fieldtype(T,i)
            CT = Missing <: eltype(col) ? Union{Missing,FT} : FT
            values = CT[ismissing(row) ? missing : getfield(row,i) for row in col]
            push!(pins,values)
            a,s = _column_to_arrow(values,String(nm),pins)
            push!(arrays,a); push!(schemas,s)
        end
    catch
        foreach(_free_array_tree,arrays); foreach(release_arrow_schema,schemas)
        rethrow()
    end
    _nested_arrow(col,name,"+s",pins,arrays,schemas,Ptr{Cvoid}[])
end

_temporal_format(::Type{Date}) = "tdD"
_temporal_format(::Type{DateTime}) = "tsm:"
_temporal_format(::Type{Time}) = "ttn"
_temporal_storage(x::Date) = Int32(Dates.value(x-Date(1970,1,1)))
_temporal_storage(x::DateTime) = Int64(Dates.value(x-DateTime(1970,1,1)))
_temporal_storage(x::Time) = Int64(Dates.value(x))
_temporal_value(x,::Type{Date}) = Date(1970,1,1)+Day(x)
_temporal_value(x,::Type{DateTime}) = DateTime(1970,1,1)+Millisecond(x)
_temporal_value(x,::Type{Time}) = Time(Nanosecond(x))
function _temporal_column_to_arrow(col,name,pins,::Type{T}) where T
    ST = T === Date ? Int32 : Int64
    CT = Missing <: eltype(col) ? Union{Missing,ST} : ST
    values = CT[ismissing(x) ? missing : _temporal_storage(x) for x in col]
    push!(pins,values)
    array,schema = _column_to_arrow(values,name,pins)
    try
        fmt = _malloc_cstr(_temporal_format(T))
        s = unsafe_load(schema)
        Libc.free(s.format)
        unsafe_store!(schema,ArrowSchema(fmt,s.name,s.metadata,s.flags,s.n_children,
            s.children,s.dictionary,s.release,s.private_data))
        array,schema
    catch
        _free_array_tree(array); release_arrow_schema(schema)
        rethrow()
    end
end
