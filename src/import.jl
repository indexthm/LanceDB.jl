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
