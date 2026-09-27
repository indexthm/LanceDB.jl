# Multimodal data and ID-based training batches

Store media as bytes, attach metadata and embeddings, then fetch samples in a chosen order or iterate shuffled training batches.

## Store bytes and typed metadata

```@example media
using LanceDB, DataFrames, Random

data = DataFrame(
    id = [101, 205],
    media = BinaryColumn([UInt8[1, 2, 3], UInt8[4, 5]]), # toy bytes; replace with read("cat.jpg"), etc.
    tags = ListColumn([["cat", "outdoor"], ["dog"]]),
    info = [(width=640, height=480), (width=800, height=600)],
    embedding = [Float32[1, 0], Float32[0, 1]],
)

path = mktempdir()
conn = Connection(path)
tbl = create_table(conn, "images", data)
create_scalar_index(tbl, :id) # ID lookup index, separate from a vector index
```

`BinaryColumn` stores byte vectors, including empty or missing values. Use `read("image.jpg")` to read a file into bytes and `large=true` for 64-bit offsets.

`ListColumn` stores variable-length lists such as tags. Use ordinary vectors for fixed-length embeddings, NamedTuples for nested records, and Julia Date/DateTime/Time for temporal values.

When another package converts your columns, reapply `BinaryColumn` or `ListColumn` if their intended storage type is lost.

## Fetch in requested order

```@example media
selected = DataFrame(take_ids(tbl, [205, 101, 205]; columns=[:id, :media]))
@assert selected.id == [205, 101, 205]

ds = IDDataset(tbl; columns=[:id, :media, :tags])
one_row = ds[1]            # a NamedTuple row, Julia's 1-based position in ds.ids
some_rows = DataFrame(ds[[2, 1, 2]])
sampled = DataFrame(sample_rows(ds, 10; replace=true, rng=MersenneTwister(42)))
nothing # hide
```

Use unique, non-missing string or integer IDs. `take_ids` preserves the requested order and repetitions. Missing IDs raise `KeyError`; pass `on_missing=:skip` to omit them.

`IDDataset` loads the ID list once, not all media. Keep its table open and unchanged during an epoch, and rebuild the dataset after updates. You can pass `ids=[...]` to train on a subset.

Use `batch_size` to limit IDs per query. A large media value is still read in full. Repeated IDs can share nested arrays; copy them before changing each occurrence independently.

## Lazy training batches

```@example media
for batch in batches(ds; batchsize=32, shuffle=true, rng=MersenneTwister(42))
    # batch.media contains bytes; decode with your image/audio library here.
    # Train your model using decoded inputs and batch metadata.
end

# Alternatively, put decoding and collation in a per-batch callback:
loader = batches(ds; batchsize=32, transform=b -> (
    ids=b.id,
    byte_lengths=length.(b.media), # replace with your actual decoder/collator
))
@assert length(first(loader).ids) == 2 # hide
nothing # hide
```

Batches fetch media when iterated. Your `transform` callback can decode images, augment samples or return model-ready arrays. Avoid collecting the iterator when the full dataset will not fit in memory.

Pass `drop_last=true` to omit a final short batch. Construct a new iterator for each shuffled epoch. An explicit RNG makes shuffle and sampling reproducible.

## User-provided embedding models

```@example media
# A deliberately simple deterministic example, not a semantic embedding model.
encoder(inputs) = [Float32[length(x), 1] for x in inputs]
encoded = with_embeddings(DataFrame(id=[1,2], text=["cat","longer text"]), :text, encoder)
text_tbl = create_table(conn, "text", encoded)
result = embedding_search(text_tbl, "cat", encoder) |> limit(1) |> execute
@assert DataFrame(result).id == [1] # hide
nothing # hide
```

An encoder receives a batch and returns one vector per input, or a matrix with one embedding per column. All embeddings must have equal, nonzero dimensions and finite values. Use the same model for stored data and queries; pass `overwrite=true` to replace an existing embedding column.

Choose your own decoder and model packages; LanceDB.jl does not install them automatically.

Close handles when finished, and remove this example's temporary database:

```@example media
close(result)
close(text_tbl)
close(tbl)
close(conn)
rm(path; recursive=true)
```

These examples execute as part of the documentation build.

## Column marker example

```jldoctest
julia> using LanceDB

julia> bytes = BinaryColumn([UInt8[1, 2], UInt8[]]);

julia> length.(bytes)
2-element Vector{Int64}:
 2
 0

julia> bytes[[2, 1]] isa BinaryColumn
true
```
