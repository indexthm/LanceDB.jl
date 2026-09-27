# Tables and queries

## Tables.jl data

`create_table` and `add` accept Tables.jl-compatible column and row tables. The package does not require DataFrames.jl, CSV.jl or Arrow.jl at runtime; install them in your own environment when using their table implementations.

```@example writes
using LanceDB, Tables

mktempdir() do path
    open(Connection, path) do db
        table = create_table(db, "items", (id=[1, 2], text=["cat", "dog"]))
        try
            add(table, (id=[3], text=["bird"]))
            merge_insert(table, (id=[2, 4], text=["updated dog", "fish"]), :id)
            delete_rows(table, col(:id) == 4)
            set_metadata!(table, Dict("source" => "example"))
            println(take_ids(table, [2, 1]))
        finally
            close(table)
        end
    end
end
```

Use `Tables.columns(result)` for owned Julia columns and `Tables.rows(result)` for row iteration. `Tables.materializer(TableSink(db, "name"))` creates a table; `Tables.materializer(table)` appends to it.

`append_partitions!(table, source)` converts and commits each `Tables.partitions(source)` partition separately. It is not an atomic multi-batch transaction. `Tables.partitions(result)` avoids an extra concatenation of result batches, but the native C API has already collected the complete query result.

## Filters and projection

The following independent example also runs during documentation builds.

```@example filters
using LanceDB, Tables

mktempdir() do path
    open(Connection, path) do db
        table = create_table(db, "items", (id=[1, 2, 3], score=[10, 20, 30]))
        try
            q = query(table) |>
                filter_expr(col(:score) >= 20) |>
                select_cols([:id, :score]) |>
                limit(10)
            result = execute(q)
            try
                rows = Tables.columns(result)
                @assert sort(rows.id) == [2, 3]
                println(sort(rows.id))
            finally
                close(result)
            end
        finally
            close(table)
        end
    end
end
```

SQL filters are also available: `filter_where(q, "score >= 20")`. Do not interpolate untrusted values into SQL; use typed expressions such as `col(:name) == user_input`. Combine expressions with `&`, `|` and `!`, using parentheses around each comparison. Expressions are consumed on use; `copy(expr)` creates an independent handle.

`offset` and `limit` support scan pagination, but scans do not promise a stable row order. Use [application-ID lookups](multimodal.md) when requested ordering matters. `select_cols` selects existing columns, not arbitrary SQL expressions.

## Indexes and vector search

```julia
create_scalar_index(table, :id)  # BTree by default
create_vector_index(table, :embedding; type=IVFFlat,
                    config=LanceDBVectorIndexConfig(num_partitions=4))
q = vector_search(table, Float32[1, 0], :embedding) |>
    nprobes(4) |> limit(10)
println(explain_plan(q))
result = execute(q)
```

This fragment assumes an existing table with an `embedding` column and sufficient training rows. Configure the index and query with the same distance metric. `nprobes`, `refine_factor` and `ef` control the corresponding native search parameters. Close `result` when finished.

Use `list_indices`, `index_stats`, `drop_index` and `optimize` to manage indexes. `create_fts_index` can build a full-text index, but the current C ABI does not expose a full-text query builder or native hybrid search.

## Metadata and versions

```julia
set_metadata!(table, Dict("source" => "training-set"))
metadata = get_metadata(table)
history = list_versions(table)
```

Version listing does not provide checkout, rollback or snapshot pinning. See [Capabilities and ownership](capabilities.md) for the remaining C API gaps.

## Object storage

`Connection` passes the database URI and `storage_options` to the Rust backend. No Python process is involved. The URI must point to a LanceDB database layout, not an arbitrary folder of images or Parquet files.

### S3

This example requires your own existing bucket, table and credentials. It is not executed during documentation builds.

```julia
using LanceDB

options = Dict(
    "aws_region" => "us-east-1",
    "aws_access_key_id" => ENV["AWS_ACCESS_KEY_ID"],
    "aws_secret_access_key" => ENV["AWS_SECRET_ACCESS_KEY"],
)
if haskey(ENV, "AWS_SESSION_TOKEN")
    options["aws_session_token"] = ENV["AWS_SESSION_TOKEN"]
end

open(Connection, "s3://my-bucket/my-database"; storage_options=options) do db
    open(Table, db, "samples") do table
        rows = take_ids(table, [42, 7]; id_column=:id)
        println(rows)
    end
end
```

For an S3-compatible service, set `aws_endpoint`. A local HTTP test endpoint also needs `aws_allow_http => "true"`; path-style addressing can be selected with `aws_virtual_hosted_style_request => "false"`.

The constructor captures a copy of the options. Changing the original dictionary does not change `reopen!`; create a new connection to supply different options. `reopen!` only reconnects a closed connection and leaves an open one unchanged.

### Validation and limits

Use an existing bucket and your own credentials. Cloud authentication and provider-specific behavior are not covered by the local test suite.

`s3://` connections read your object storage directly. LanceDB Cloud uses a different service API and is not fully supported by these bindings.

The current bindings do not expose Python's read-consistency interval or per-table storage-option overrides. Existing handles may not observe external updates immediately. Keep a training dataset unchanged during an epoch.

### Video and large values

Video data is read as complete byte values. Use a video decoder to extract frames, or store pre-extracted frames as individual rows for sampling. Lazy video/Blob range reads are not available yet.

See the upstream [storage guide](https://docs.lancedb.com/storage) and [Lance Blob guide](https://lance.org/guide/blob/). Their latest examples may require newer native versions than the JLL used here.

## Optional integrations

Arrow is a weak dependency. Install it in your application and load both packages to enable `LanceDBArrowExt` automatically:

```julia
using LanceDB, Arrow
source = Arrow.Table("input.arrow")
table = create_table(db, "imported", source)
```

Loading Arrow enables optimized ingestion of supported Arrow columns, including binary values and variable-length lists. Keep input buffers unchanged during the call.

For an IPC stream, use `append_partitions!(table, Arrow.Stream("input.arrow"))` to append batches individually. Arbitrary Arrow metadata are not preserved; see [usage notes](capabilities.md).

DataFrames needs no extension because its table and view types already implement Tables.jl:

```julia
using DataFrames
frame = DataFrame(id=[1, 2], text=["cat", "dog"])
table = create_table(db, "frames", frame)
add(table, DataFrame(id=[3], text=["bird"]))
result = execute(query(table))
try
    output = DataFrame(result)
finally
    close(result)
end
```

Use `Arrow.write("output.arrow", result)` to export query results. The values are preserved, but storage types can change; byte vectors may be written as lists of UInt8. Use `set_metadata!` explicitly for metadata you need in the database.
