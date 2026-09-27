# Model selection, media decoding and device placement belong to the caller.
# The encoder protocol is deliberately batched so model inference can amortize
# overhead and produce GPU results without a per-row callback contract.
function _encode_batch(encoder, inputs)
    output = encoder(inputs)
    vectors = if output isa AbstractMatrix
        eltype(output) <: Real || throw(ArgumentError("encoder matrix must contain real numbers"))
        size(output,2) == length(inputs) || throw(DimensionMismatch("encoder matrix must have one column per input"))
        [Float32.(collect(@view output[:,i])) for i in axes(output,2)]
    elseif output isa AbstractVector
        length(output) == length(inputs) || throw(DimensionMismatch("encoder must return one vector per input"))
        all(v -> v isa AbstractVector{<:Real},output) || throw(ArgumentError("encoder output must be vectors of real numbers"))
        [Float32.(collect(v)) for v in output]
    else
        throw(ArgumentError("encoder must return vectors or a dimensions × batch matrix"))
    end
    isempty(vectors) && return Vector{Float32}[]
    dim = length(first(vectors))
    dim > 0 || throw(ArgumentError("embeddings cannot be empty"))
    all(v -> length(v) == dim,vectors) || throw(DimensionMismatch("embedding dimensions must agree"))
    all(v -> all(isfinite,v),vectors) || throw(ArgumentError("embeddings must contain finite Float32 values"))
    vectors
end

"""
    with_embeddings(data, source, encoder; column=:embedding, batchsize=64, overwrite=false)

Return a Tables.jl column table with generated Float32 embeddings. `encoder`
accepts a batch of source values and returns a vector of vectors or a matrix
whose columns are embeddings. Existing columns are reused where possible.
Encoding/decoding/model installation is supplied by the caller; nothing is
downloaded automatically. Empty input cannot infer a vector dimension.
For large inputs, apply this function to each Tables.jl partition before append.
"""
function with_embeddings(data,source,encoder; column=:embedding,batchsize::Integer=64,overwrite::Bool=false)
    0 < batchsize <= typemax(Int)-1 || throw(ArgumentError("batchsize must be positive"))
    cols = Tables.columns(data)
    names = Tuple(Symbol.(Tables.columnnames(cols)))
    src,dst = Symbol(source),Symbol(column)
    src in names || throw(ArgumentError("source column does not exist: $src"))
    !overwrite && dst in names && throw(ArgumentError("embedding column already exists: $dst"))
    original = NamedTuple{names}(Tuple(Tables.getcolumn(cols,nm) for nm in names))
    values = original[src]
    all(v -> length(v) == length(values),Base.values(original)) || throw(ArgumentError("columns must have equal lengths"))
    isempty(values) && throw(ArgumentError("cannot infer embedding dimension from empty data"))
    encoded = Vector{Float32}[]
    sizehint!(encoded,length(values))
    dim = nothing
    for start in 1:batchsize:length(values)
        chunk = _encode_batch(encoder,values[start:min(start+batchsize-1,length(values))])
        d = length(first(chunk))
        if dim === nothing
            dim = d
        elseif d != dim
            throw(DimensionMismatch("embedding dimension changed between batches"))
        end
        append!(encoded,chunk)
    end
    merge(original,NamedTuple{(dst,)}((encoded,)))
end

"""
    embedding_search(table, input, encoder; column=:embedding)

Encode one query (text, bytes, image, etc.) with the same batched encoder
protocol as `with_embeddings`, then return a chainable VectorQuery.
"""
function embedding_search(tbl::Table,input,encoder; column=:embedding)
    _assert_live(tbl)
    vector_search(tbl,only(_encode_batch(encoder,[input])),column)
end
