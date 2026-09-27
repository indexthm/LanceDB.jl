"""
    import_csv(conn, name, source; strict=true, kwargs...) -> Table
    import_csv(table, source; strict=true, kwargs...) -> Table

Create a table from a CSV file path or IO, or append to an existing table.
Load CSV.jl with `using CSV` first. Remaining keywords are passed to `CSV.File`,
including `delim`, `types`, `dateformat` and `missingstring`. Invalid typed
values raise errors by default. Input is parsed before writing to the database.

For chunked input, use `append_partitions!(table, CSV.Chunks(path; types=...))`.
Each chunk is committed separately; specify types consistently across chunks.
"""
import_csv(args...; kwargs...) = throw(ArgumentError("load CSV.jl with `using CSV` before calling import_csv"))

"""
    import_json(conn, name, source; jsonlines=nothing, types=Dict(), vector_columns=[]) -> Table
    import_json(table, source; jsonlines=nothing, types=Dict(), vector_columns=[]) -> Table

Create a table or append JSON data from a file path or IO. Load JSON.jl with
`using JSON` first. Accepts an array of row objects, an object of column arrays,
or JSON Lines. File extensions `.jsonl`/`.ndjson` select JSON Lines automatically;
pass `jsonlines=true` for an IO containing JSON Lines.

Nulls and missing fields become `missing`. `types` maps column names to Julia
element types, e.g. `Dict(:score=>Float64, :tags=>Vector{String})`. Array-valued
fields are variable-length lists unless named in `vector_columns`; those must
contain equal-length, finite numeric vectors and default to Float32 elements.
Use `types=Dict(:embedding=>Vector{Float64})` to preserve Float64 vector storage.
Search query vectors still convert to Float32 because the C search API accepts
only Float32 inputs. Ordinary JSON floating columns default to Float64.
Nested objects and nested arrays must be flattened or transformed before import.

The complete input is parsed and validated in memory before a single write.
An empty row array needs explicit `types` to describe its columns.
"""
import_json(args...; kwargs...) = throw(ArgumentError("load JSON.jl with `using JSON` before calling import_json"))
