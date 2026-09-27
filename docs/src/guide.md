# Tables and queries

## Write DataFrames

`create_table` and `add` accept Tables.jl-compatible column and row tables. The package does not require DataFrames.jl, CSV.jl or Arrow.jl at runtime; install them in your own environment when using their table implementations.

```@example writes
using LanceDB, DataFrames

mktempdir() do path
    open(Connection, path) do db
        table = create_table(db, "items", DataFrame(id=[1, 2], text=["cat", "dog"]))
        try
            add(table, DataFrame(id=[3], text=["bird"]))
            merge_insert(table, DataFrame(id=[2, 4], text=["updated dog", "fish"]), :id)
            delete_rows(table, col(:id) == 4)
            set_metadata!(table, Dict("source" => "example"))
            println(DataFrame(take_ids(table, [2, 1])))
        finally
            close(table)
        end
    end
end
```

Use `df = DataFrame(result)` to obtain a DataFrame, `df.id` to access a column, and `eachrow(df)` to iterate rows. NamedTuples and other Tables.jl-compatible inputs are also accepted.

`append_partitions!(table, source)` converts and commits each `Tables.partitions(source)` partition separately. It is not an atomic multi-batch transaction. `Tables.partitions(result)` avoids an extra concatenation of result batches, but the native C API has already collected the complete query result.

## Filters and projection

The following independent example also runs during documentation builds.

```@example filters
using LanceDB, DataFrames

mktempdir() do path
    open(Connection, path) do db
        table = create_table(db, "items", DataFrame(id=[1, 2, 3], score=[10, 20, 30]))
        try
            q = query(table) |>
                filter_expr(col(:score) >= 20) |>
                select_cols([:id, :score]) |>
                limit(10)
            result = execute(q)
            try
                rows = DataFrame(result)
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

Use `list_indices`, `index_stats`, `drop_index` and `optimize` to manage indexes.

### Full-text indexes

For an existing string column, configure tokenization with keywords:

```julia
create_fts_index(table, :text;
    base_tokenizer="simple", language="English",
    lowercase=true, stem=true, remove_stop_words=true,
    ascii_folding=true, max_token_length=40)
println(list_indices(table))
println(index_stats(table, "text_idx"))

# Replace an existing index explicitly.
create_fts_index(table, :text; replace=true)
# After appending rows, update indexes to include them.
optimize(table; type=OptimizeIndex)
```

`replace` defaults to `false`. `max_token_length=-1` removes the token-length limit. Other omitted keywords retain the supplied `LanceDBFtsIndexConfig` values; the configuration object is not modified. When replacing an index, specify the desired tokenization options again: options are not inherited from the old index.

These operations build and maintain native FTS indexes. Full-text queries, relevance scores and full-text/vector hybrid queries remain unavailable through lancedb-c. A SQL string filter is not a substitute for indexed full-text search.

## Metadata and versions

```@example versions
using LanceDB, DataFrames

mktempdir() do path
    open(Connection, path) do db
        table = create_table(db, "items", DataFrame(id=[1], text=["cat"]))
        try
            initial_version = table_version(table)
            add(table, DataFrame(id=[2], text=["dog"]))
            set_metadata!(table, Dict("source" => "training-set"))
            println(get_metadata(table))
            history = DataFrame(list_versions(table))
            println(select(history, :version, :timestamp))
            @assert table_version(table) > initial_version
        finally
            close(table)
        end
    end
end
```

`list_versions` returns history ordered by version, including metadata. `timestamp` is a UTC `DateTime` at millisecond precision; `timestamp_seconds` and `timestamp_nanos` preserve the original timestamp without rounding. Listing history does not change the table's current version.

Use `optimize(table; type=OptimizeCompact)` for compaction without requesting version pruning. `OptimizePrune` cleans old versions according to the native retention policy; the default `OptimizeAll` includes pruning. The current interface cannot customize the retention interval or return cleanup statistics. Pruning can make historical data unavailable to other clients.

Python's `checkout`, `checkout_latest`, `restore`, and version tags are not exposed by the current C interface. They are not implemented here; reopening a table is not a substitute for restoring or pinning a version.

## Object storage

`Connection` passes the database URI and `storage_options` to the Rust backend. No Python process is involved. The URI must point to a LanceDB database layout, not an arbitrary folder of images or Parquet files.

### S3

This example requires your own existing bucket, table and credentials. It is not executed during documentation builds.

```julia
using LanceDB, DataFrames

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
        rows = DataFrame(take_ids(table, [42, 7]; id_column=:id))
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

See the upstream [storage guide](https://docs.lancedb.com/storage) and [Lance Blob guide](https://lance.org/guide/blob/). Their latest examples may require a newer lancedb-c version than the one supported here.

## Optional integrations

### CSV files

Install CSV.jl in your application with `Pkg.add("CSV")`. Loading it enables `import_csv` for creating or appending to a table. CSV parsing options such as `delim`, `types` and `missingstring` can be passed directly.

```@example csv
using LanceDB, CSV, DataFrames

mktempdir() do path
    open(Connection, path) do db
        input = IOBuffer("id,text,score\n1,cat,0.8\n2,dog,0.9\n")
        table = import_csv(db, "items", input)
        try
            import_csv(table, IOBuffer("id,text,score\n3,bird,0.7\n"))
            println(DataFrame(take_ids(table, [1, 3])))
        finally
            close(table)
        end
    end
end
```

Pass a file path, such as `import_csv(db, "items", "items.csv")`, to read from disk. Invalid values in explicitly typed columns raise an error by default; `strict=false` selects CSV.jl's more permissive behavior. Ordinary imports parse the input before writing. For larger files, use `append_partitions!(table, CSV.Chunks("items.csv"; types=...))` with consistent column types; each chunk is committed separately.

### JSON files

Install JSON.jl with `Pkg.add("JSON")`, then load it to enable `import_json`. It accepts an array of row objects, an object whose values are column arrays, or JSON Lines. Pass a file path to read a file; wrap JSON text in `IOBuffer`.

```@example json
using LanceDB, JSON, DataFrames

mktempdir() do path
    open(Connection, path) do db
        rows = IOBuffer("""[{"id":1,"text":"cat","embedding":[1,0]}]""")
        table = import_json(db, "items", rows; vector_columns=[:embedding])
        try
            columns = IOBuffer("""{"id":[2],"text":["dog"],"embedding":[[0,1]]}""")
            import_json(table, columns; vector_columns=[:embedding])
            lines = IOBuffer("""{"id":3,"text":"bird","embedding":[1,1]}""")
            import_json(table, lines; jsonlines=true, vector_columns=[:embedding])
            println(DataFrame(take_ids(table, [1, 3])))
        finally
            close(table)
        end
    end
end
```

Files ending in `.jsonl` or `.ndjson` select JSON Lines automatically: `import_json(db, "items", "items.jsonl")`. For IO, pass `jsonlines=true`. All three formats are parsed in memory before writing; JSON Lines is not a streaming import.

JSON nulls and absent fields become `missing`. Ordinary floating columns use Float64. Array-valued fields are variable-length lists by default; mark embedding columns with `vector_columns=[:embedding]` to require equal-length numeric vectors. These vectors default to Float32. To preserve Float64 vector values, also pass `types=Dict(:embedding=>Vector{Float64})`. Search query inputs still convert to Float32 because that is what the lancedb-c search interface accepts.

Use `types` to set other column types, such as `Dict(:score=>Float64, :tags=>Vector{String})`. Explicit types are needed for empty lists with no inferable elements or an empty row array. Flatten nested objects and nested arrays before importing. When appending, use types and vector-column selections consistent with the existing table.

### SQLite databases

Install SQLite.jl with `Pkg.add("SQLite")`, then load it to enable `import_sqlite`. Choose `source_table` to copy a whole table or `sql` to select rows and columns. Query parameters are passed separately through `params`.

```@example sqlite
using LanceDB, SQLite, DataFrames

source = SQLite.DB() # Use SQLite.DB("input.sqlite") for an existing file.
try
    SQLite.load!(DataFrame(id=[1, 2], text=["cat", "dog"], score=[0.8, 0.9]), source, "items")
    mktempdir() do path
        open(Connection, path) do db
            table = import_sqlite(db, "items", source; source_table="items")
            try
                import_sqlite(table, source;
                    sql="SELECT id + 2 AS id, text, score FROM items WHERE score > ?",
                    params=(0.85,))
                println(DataFrame(take_ids(table, [1, 4])))
            finally
                close(table)
            end
        end
    end
finally
    SQLite.close(source)
end
```

The source connection remains open after import. Results are collected in memory before writing; use bounded queries for large sources. SQLite NULL becomes `missing`, REAL values remain Float64, and BLOB values are imported as binary columns. SQLite has no native embedding type: decode embeddings stored as JSON text or BLOBs before passing them to `create_table` or `add`. If a SQLite column mixes incompatible storage types, normalize it in your SELECT with `CAST`. Give joined columns unique aliases.

Existing SQLite query results also work with the ordinary Tables interface, without this convenience function. See the [SQLite.jl documentation](https://juliadatabases.org/SQLite.jl/stable/) for query and parameter syntax.

### Arrow and DataFrames

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
