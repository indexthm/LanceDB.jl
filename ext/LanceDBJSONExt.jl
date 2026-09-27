module LanceDBJSONExt

using LanceDB, JSON

function scalar_values(values, name, hint)
    present = filter(!ismissing, values)
    all(x -> x isa Union{Bool,Integer,AbstractFloat,AbstractString}, present) ||
        throw(ArgumentError("column $name contains nested objects/arrays; transform them before importing"))
    T = if hint !== nothing
        Base.nonmissingtype(hint)
    elseif isempty(present)
        Missing
    elseif all(x -> x isa AbstractString, present)
        String
    elseif all(x -> x isa Bool, present)
        Bool
    elseif all(x -> x isa Real && !(x isa Bool), present)
        foldl(promote_type, (typeof(x) for x in present))
    else
        throw(ArgumentError("column $name mixes incompatible scalar types; supply consistent values"))
    end
    T in (Missing,Bool,Int8,UInt8,Int16,UInt16,Int32,UInt32,Int64,UInt64,Float32,Float64,String) ||
        throw(ArgumentError("unsupported scalar type $T for column $name"))
    if hint === nothing && T <: AbstractFloat
        all(x -> !(x isa Integer) || T(x) == x, present) ||
            throw(ArgumentError("promoting column $name to $T would lose integer precision; specify types explicitly"))
    end
    nullable = any(ismissing,values) || (hint !== nothing && Missing <: hint)
    CT = nullable ? Union{Missing,T} : T
    try
        CT[ismissing(x) ? missing : convert(T,x) for x in values]
    catch error
        error isa Union{InexactError,MethodError,ArgumentError} || rethrow()
        throw(ArgumentError("cannot convert column $name to $T: $(sprint(showerror,error))"))
    end
end

function json_column(values, name, hint, vector)
    present = filter(!ismissing, values)
    hint_type = hint === nothing ? nothing : Base.nonmissingtype(hint)
    list = vector || (hint_type !== nothing && hint_type <: AbstractVector) || any(x -> x isa AbstractVector,present)
    list || return scalar_values(values,name,hint)
    all(x -> x isa AbstractVector,present) || throw(ArgumentError("column $name mixes lists and scalars"))
    hint_type === nothing || hint_type <: AbstractVector ||
        throw(ArgumentError("types[$name] must be a vector type for an array-valued column"))
    element_hint = hint_type === nothing ? (vector ? Float32 : nothing) : eltype(hint_type)
    flat = Any[x for row in present for x in row]
    if vector
        all(x -> x isa Real && !(x isa Bool) && isfinite(x),flat) ||
            throw(ArgumentError("vector column $name must contain finite, non-missing numbers"))
    end
    isempty(flat) && element_hint === nothing && throw(ArgumentError("cannot infer list elements in $name; specify types"))
    typed = scalar_values(flat,"$name[]",element_hint)
    T = Vector{eltype(typed)}
    CT = any(ismissing,values) || (hint !== nothing && Missing <: hint) ? Union{Missing,T} : T
    out = Vector{CT}(undef,length(values))
    offset = 0
    width = nothing
    for (i,row) in enumerate(values)
        if ismissing(row)
            out[i] = missing
            continue
        end
        n = length(row)
        out[i] = typed[offset+1:offset+n]
        offset += n
        if vector
            n > 0 || throw(ArgumentError("vector column $name has an empty vector"))
            width === nothing && (width=n)
            n == width || throw(ArgumentError("vector dimensions differ in column $name"))
            all(x -> x isa Real && !(x isa Bool) && isfinite(x),out[i]) ||
                throw(ArgumentError("vector column $name must contain finite, non-missing numbers"))
        end
    end
    vector && width === nothing && throw(ArgumentError("cannot infer vector dimension in column $name"))
    vector ? out : ListColumn(out)
end

function json_table(source; jsonlines::Union{Nothing,Bool}=nothing, types::AbstractDict=Dict(), vector_columns=[])
    parsed = source isa AbstractString ? JSON.parsefile(source;null=missing,jsonlines) :
        JSON.parse(source;null=missing,jsonlines=something(jsonlines,false))
    hints = Dict(Symbol(k)=>v for (k,v) in types)
    all(v -> v isa Type,values(hints)) || throw(ArgumentError("types must map column names to Julia types"))
    columns = if parsed isa AbstractVector
        all(row -> row isa AbstractDict, parsed) || throw(ArgumentError("JSON rows must be objects"))
        # Keep raw values until our type checks: eager table promotion can round
        # large integer IDs when the same column also contains floating values.
        names = isempty(parsed) ? collect(keys(hints)) : unique(Symbol(k) for row in parsed for k in keys(row))
        NamedTuple{Tuple(names)}(Tuple(Any[get(row,String(k),missing) for row in parsed] for k in names))
    elseif parsed isa AbstractDict
        all(v -> v isa AbstractVector, values(parsed)) ||
            throw(ArgumentError("a column-oriented JSON object must contain arrays"))
        Dict(Symbol(k)=>v for (k,v) in parsed)
    else
        throw(ArgumentError("expected an array of row objects or an object of column arrays"))
    end
    names = collect(keys(columns))
    isempty(names) && throw(ArgumentError("JSON contains no columns; specify types for an empty row array"))
    all(k -> k in names,keys(hints)) || throw(ArgumentError("types contains an unknown column"))
    vectors = Set(Symbol.(vector_columns))
    issubset(vectors,Set(names)) || throw(ArgumentError("vector_columns contains an unknown column"))
    lengths = [length(columns[k]) for k in names]
    all(==(first(lengths)),lengths) || throw(ArgumentError("JSON columns must have equal lengths"))
    data = Tuple(json_column(columns[k],k,get(hints,k,nothing),k in vectors) for k in names)
    NamedTuple{Tuple(names)}(data)
end

function LanceDB.import_json(conn::Connection, name::AbstractString,
                             source::Union{AbstractString,IO}; kwargs...)
    LanceDB._assert_live(conn)
    LanceDB._check_string(name)
    create_table(conn,name,json_table(source;kwargs...))
end

function LanceDB.import_json(table::Table, source::Union{AbstractString,IO}; kwargs...)
    LanceDB._assert_live(table)
    add(table,json_table(source;kwargs...))
    table
end

end
