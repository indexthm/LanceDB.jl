# Indexed application IDs, not physical Lance row IDs. No SQL text is built
# from user values: literals go through the typed expression C API.
function _validated_ids(ids)
    values = collect(ids)
    for id in values
        if id isa AbstractString
            _check_string(id)
        elseif id isa Integer && !(id isa Bool)
            typemin(Int64) <= id <= typemax(Int64) || throw(ArgumentError("integer IDs must fit Int64"))
        else
            throw(ArgumentError("IDs must be non-missing strings or integers"))
        end
    end
    isempty(values) || all(x -> (x isa AbstractString) == (first(values) isa AbstractString), values) ||
        throw(ArgumentError("do not mix string and integer IDs"))
    values
end

function _schema_type(field)
    if field.dictionary !== nothing
        T = _schema_type(field.dictionary)
        return field.nullable ? Union{Missing,T} : T
    end
    fmt = field.format
    T = if fmt == "n"
        Missing
    elseif fmt in ("u","U")
        String
    elseif fmt in ("z","Z") || startswith(fmt,"w:")
        Vector{UInt8}
    elseif fmt == "b"
        Bool
    elseif fmt == "tdD"
        Date
    elseif fmt == "tsm:"
        DateTime
    elseif fmt == "ttn"
        Time
    elseif fmt == "+s"
        NamedTuple{Tuple(Symbol(c.name) for c in field.children),Tuple{(_schema_type(c) for c in field.children)...}}
    elseif startswith(fmt,"+w:") || fmt in ("+l","+L")
        Vector{_schema_type(only(field.children))}
    else
        _fmt_to_type(fmt)
    end
    field.nullable ? Union{Missing,T} : T
end

function _id_projection(tbl, id_column, columns)
    fields = table_schema(tbl).children
    idname = _check_string(String(id_column))
    idfield = findfirst(f -> f.name == idname, fields)
    idfield === nothing && throw(ArgumentError("ID column does not exist: $idname"))
    fields[idfield].format in ("u","U","c","C","s","S","i","I","l","L") ||
        throw(ArgumentError("ID column must contain integers or strings"))
    names = columns === nothing ? [f.name for f in fields] : _strings(columns)
    isempty(names) && throw(ArgumentError("select at least one column"))
    allunique(names) || throw(ArgumentError("selected column names must be unique"))
    vectors = map(names) do name
        idx = findfirst(f -> f.name == name, fields)
        idx === nothing && throw(ArgumentError("column does not exist: $name"))
        field = fields[idx]
        values = Vector{_schema_type(field)}()
        (field.format in ("z","Z") || startswith(field.format,"w:")) && return BinaryColumn(values;large=field.format == "Z")
        field.format in ("+l","+L") && return ListColumn(values;large=field.format == "+L")
        values
    end
    empty_columns = NamedTuple{Tuple(Symbol.(names))}(Tuple(vectors))
    idname, names, empty_columns
end

function _require_version(tbl, expected)
    actual = table_version(tbl)
    actual == expected || throw(ArgumentError("table version changed from $expected to $actual; rebuild the dataset"))
end

function _id_filter(name, ids)
    expressions = LanceDBExpr[]
    try
        # Quoting prevents dots/spaces/keywords in the ID field from being
        # interpreted as a qualified identifier by DataFusion.
        push!(expressions,col("\"" * replace(name,"\""=>"\"\"") * "\""))
        for id in ids
            push!(expressions,lit(id))
        end
        isin(first(expressions),expressions[2:end]...)
    finally
        foreach(close,expressions)
    end
end

"""
    take_ids(table, ids; id_column=:id, columns=nothing, batch_size=256,
             on_missing=:error, check_version=true)

Fetch rows by unique application ID using indexed predicates. Returns a Tables.jl
column table in requested order, including repeated IDs. Create a scalar index on
the ID column for efficient lookup. This is not native `take_offsets`/`take_row_ids`.
Duplicate stored IDs are rejected. `on_missing=:skip` omits missing IDs.
Each native query is limited to a bounded number of distinct IDs. The complete
returned result still occupies memory. Version checks detect changes visible to
this handle; they do not provide snapshot isolation against external writers.
"""
function take_ids(tbl::Table, ids; id_column=:id, columns=nothing, batch_size::Integer=256,
                  on_missing::Symbol=:error, check_version::Bool=true)
    _assert_live(tbl)
    0 < batch_size <= typemax(Int)-1 || throw(ArgumentError("batch_size must be positive"))
    on_missing in (:error,:skip) || throw(ArgumentError("on_missing must be :error or :skip"))
    requested = _validated_ids(ids)
    version = table_version(tbl)
    idname,names,result = _id_projection(tbl,id_column,columns)
    selected = unique([idname; names])
    distinct = unique(requested)
    locations = Dict{Any,Tuple{Int,Int}}()
    chunks = NamedTuple[]
    for start in 1:batch_size:length(distinct)
        chunk = distinct[start:min(start+batch_size-1,length(distinct))]
        check_version && _require_version(tbl,version)
        q = query(tbl)
        predicate = nothing
        try
            predicate = _id_filter(idname,chunk)
            filter_expr(q,predicate)
            select_cols(q,selected)
            # A valid unique-key query cannot return more than length(chunk).
            limit(q,length(chunk)+1)
            r = execute(q)
            cols = try
                Tables.columns(r)
            finally
                close(r)
            end
            push!(chunks,cols)
            if haskey(cols,Symbol(idname))
                for (i,id) in enumerate(cols[Symbol(idname)])
                    haskey(locations,id) && throw(ArgumentError("duplicate stored ID: $id"))
                    locations[id] = (length(chunks),i)
                end
            end
        finally
            close(q)
            predicate === nothing || close(predicate)
        end
    end
    for id in requested
        loc = get(locations,id,nothing)
        if loc === nothing
            on_missing === :skip && continue
            throw(KeyError(id))
        end
        b,i = loc
        for name in keys(result)
            push!(result[name],chunks[b][name][i])
        end
    end
    check_version && _require_version(tbl,version)
    result
end

"""
    IDDataset(table; id_column=:id, ids=nothing, columns=nothing, batch_size=256)

A borrowed table plus an in-memory manifest of unique application IDs. Without
`ids`, scans only the ID column once (not media/embeddings). `ds[i]` returns one
named-tuple row; `ds[indices]` returns a column table. Uses 1-based Julia indices.
Keep the table open and unchanged for the dataset's lifetime. Explicit `ids`
are checked for uniqueness; their existence is checked when fetched.
"""
struct IDDataset{I,C}
    table::Table
    ids::I
    id_column::String
    columns::C
    batch_size::Int
    version::Int
end
function IDDataset(tbl::Table; id_column=:id, ids=nothing, columns=nothing, batch_size::Integer=256)
    _assert_live(tbl)
    0 < batch_size <= typemax(Int)-1 || throw(ArgumentError("batch_size must be positive"))
    version = table_version(tbl)
    idname,names,_ = _id_projection(tbl,id_column,columns)
    manifest = if ids === nothing
        q = query(tbl)
        try
            select_cols(q,[idname])
            r = execute(q)
            try
                cols = Tables.columns(r)
                haskey(cols,Symbol(idname)) ? copy(cols[Symbol(idname)]) : Any[]
            finally
                close(r)
            end
        finally
            close(q)
        end
    else
        collect(ids)
    end
    manifest = _validated_ids(manifest)
    allunique(manifest) || throw(ArgumentError("dataset IDs must be unique"))
    _require_version(tbl,version)
    IDDataset(tbl,manifest,idname,names,Int(batch_size),version)
end
Base.length(ds::IDDataset) = length(ds.ids)
Base.firstindex(ds::IDDataset) = 1
Base.lastindex(ds::IDDataset) = length(ds)
function Base.getindex(ds::IDDataset, indices::AbstractVector{<:Integer})
    any(i -> i isa Bool,indices) && throw(ArgumentError("dataset indices must be integers, not a boolean mask"))
    all(i -> 1 <= i <= length(ds),indices) || throw(BoundsError(ds,indices))
    _require_version(ds.table,ds.version)
    result = take_ids(ds.table,ds.ids[indices]; id_column=ds.id_column,
                      columns=ds.columns,batch_size=ds.batch_size)
    _require_version(ds.table,ds.version)
    result
end
function Base.getindex(ds::IDDataset, i::Integer)
    columns = ds[[i]]
    NamedTuple{keys(columns)}(map(first,values(columns)))
end

struct DatasetBatches{D,F}
    dataset::D
    order::Vector{Int}
    batchsize::Int
    drop_last::Bool
    transform::F
end
Base.IteratorSize(::Type{<:DatasetBatches}) = Base.HasLength()
Base.IteratorEltype(::Type{<:DatasetBatches}) = Base.EltypeUnknown()
Base.length(b::DatasetBatches) = b.drop_last ? fld(length(b.order),b.batchsize) : cld(length(b.order),b.batchsize)
function Base.iterate(b::DatasetBatches, start::Int=1)
    stop = min(start+b.batchsize-1,length(b.order))
    (start > stop || (b.drop_last && stop-start+1 < b.batchsize)) && return nothing
    result = b.dataset[b.order[start:stop]]
    b.transform(result),stop+1
end

"""
    batches(dataset; batchsize=32, shuffle=false, rng=Random.default_rng(),
            drop_last=false, transform=identity)

Lazily fetch one training batch at a time. Shuffle applies to the ID manifest;
construct a new iterator for each shuffled epoch. `transform` receives a column
table and may decode media, augment samples or return model-ready arrays.
No background worker or hidden shared-handle concurrency is started.
"""
function batches(ds::IDDataset; batchsize::Integer=32, shuffle::Bool=false,
                 rng::AbstractRNG=Random.default_rng(),drop_last::Bool=false,transform=identity)
    0 < batchsize <= typemax(Int)-1 || throw(ArgumentError("batchsize must be positive"))
    order = collect(1:length(ds))
    shuffle && Random.shuffle!(rng,order)
    DatasetBatches(ds,order,Int(batchsize),drop_last,transform)
end

"""`sample_rows(dataset, n; replace=false, rng=Random.default_rng())` samples
uniformly over the dataset's ID manifest and returns a column table."""
function sample_rows(ds::IDDataset,n::Integer; replace::Bool=false,rng::AbstractRNG=Random.default_rng())
    0 <= n <= typemax(Int) || throw(ArgumentError("n must be nonnegative"))
    !replace && n > length(ds) && throw(ArgumentError("sample exceeds dataset size; use replace=true"))
    n > 0 && isempty(ds.ids) && throw(ArgumentError("cannot sample an empty dataset"))
    indices = n == 0 ? Int[] : replace ? rand(rng,1:length(ds),n) : randperm(rng,length(ds))[1:n]
    ds[indices]
end
