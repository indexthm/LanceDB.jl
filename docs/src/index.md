# LanceDB.jl

LanceDB.jl wraps the LanceDB C API through `LanceDB_C_jll`, with Tables.jl integration, vector queries, binary media columns and ID-based training batches. Julia 1.10 or later is required. No Python or native build toolchain is needed. The API is experimental and targets the lancedb-c 0.33 ABI.

- [Tables, queries and object storage](guide.md)
- [Multimodal data and training batches](multimodal.md)
- [Capabilities and ownership](capabilities.md)
- [API reference](api.md)

## Install a local checkout

From the repository root, use your existing Julia installation:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

To use the checkout from another project, run `Pkg.develop(path="/path/to/LanceDB.jl")` in that project's Julia environment. Install `DataFrames` in that environment with `Pkg.add("DataFrames")` to run the examples below.

## Create and search a table

This example is executed during the documentation build. It creates a fresh temporary database, uses the published JLL and closes its handles explicitly.

```@example quickstart
using LanceDB, DataFrames

mktempdir() do path
    open(Connection, path) do db
        table = create_table(db, "items", DataFrame(
            id = [1, 2, 3],
            text = ["cat", "dog", "bird"],
            embedding = [Float32[1, 0], Float32[0, 1], Float32[0.5, 0.5]],
        ))
        try
            result = vector_search(table, Float32[1, 0], :embedding) |>
                     limit(1) |> execute
            try
                rows = DataFrame(result)
                @assert rows.id == [1]
                println("Nearest item: ", only(rows.text))
            finally
                close(result)
            end
        finally
            close(table)
        end
    end
end
```

Small tables can be searched without a vector index. Index training requirements depend on the selected index and configuration.

## Work with an existing database

```julia
open(Connection, "./my-database") do db
    println(table_names(db))
    open(Table, db, "items") do table
        println(count_rows(table))
    end
end
```

Creating a table with an existing name raises an error. `add(table, data)` appends rows; `merge_insert` performs keyed upserts. See [Tables and queries](guide.md).

## Resource lifetime

Close tables, connections, unused query builders and results when finished. Finalizers are a fallback. Executing a query consumes its builder; create a new query for another execution. Consumed expressions must be copied **before** reuse. See [Capabilities and ownership](capabilities.md) for details.
