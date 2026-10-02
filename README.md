# LanceDB.jl

[![Build Status](https://github.com/indexthm/LanceDB.jl/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/indexthm/LanceDB.jl/actions/workflows/test.yml?query=branch%3Amain)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://indexthm.github.io/LanceDB.jl/dev/)

Julia bindings for [lancedb-c](https://github.com/lancedb/lancedb-c), the C API for LanceDB. Tables.jl connects ingestion and query results to the Julia data ecosystem. The API is experimental.

## Getting started

Julia 1.10 or later is required. No Rust compiler or Python installation is needed. Install this fork in your Julia environment:

```julia
using Pkg
Pkg.add(url="https://github.com/indexthm/LanceDB.jl")
Pkg.add("DataFrames")
```

```julia
using LanceDB, DataFrames

open(Connection, "./my-database") do db
    table = create_table(db, "items", DataFrame(
        id = [1, 2],
        text = ["cat", "dog"],
        embedding = [Float32[1, 0], Float32[0, 1]],
    ))
    try
        result = vector_search(table, [1.0, 0.0], :embedding) |> limit(1) |> execute
        try
            println(DataFrame(result))
        finally
            close(result)
        end
    finally
        close(table)
    end
end
```

Run the example in a fresh database, or use `open_table` for an existing table. The [multimodal guide](docs/src/multimodal.md) covers binary media, indexed ID lookup, shuffled batches and user-supplied embedding models.

## Optional integrations

Load CSV.jl or JSON.jl to enable `import_csv` or `import_json` for file paths and IO. JSON imports support row objects, column arrays and JSON Lines; both import functions can create a table or append to one. Load SQLite.jl to enable `import_sqlite` for an existing SQLite connection, with a source table or parameterized SQL query. These packages are optional dependencies.

Loading Arrow.jl enables the Arrow extension: supported `Arrow.Table` columns retain their binary/list layouts, and eligible primitive buffers are borrowed during ingestion. Arrow is not required for ordinary Tables.jl sources. DataFrames and SubDataFrames work through Tables.jl without a package-specific extension. See [the guide](docs/src/guide.md#Optional-integrations) for examples and limitations.

## Development

From a checkout, run:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=. benchmark/run.jl
```

The benchmark reports Julia allocations and warmed timings; it excludes native Rust allocations.

### Conversion benchmark

On Windows with Julia 1.13.0, Arrow 2.8.1 and lancedb-c 0.33.0, removing the unused Arrow import left conversion allocations effectively unchanged. Numeric input used 720 bytes before and after; string and vector input used about 221 KB and 321 KB. The conversion implementation was unchanged. Short timings varied between runs and did not establish a regression.

For a 20,000-row `Arrow.Table` with Int64 and Float64 columns, the optional extension produced:

| Julia-to-C conversion | Without extension | With extension |
|---|---:|---:|
| Julia allocation | 321,534 bytes | 2,064 bytes |
| Median time (31 warmed samples) | 0.0947 ms | 0.0361 ms |

Run `benchmark/run.jl --arrow` from an environment containing both LanceDB and Arrow to reproduce the input conversion measurement. These numbers exclude IPC parsing and native ingestion; they are not end-to-end database throughput or a Python comparison.

Build the documentation from the repository root:

```sh
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Documenter writes HTML to `docs/build/`. GitHub Actions builds the same documentation and deploys it to this fork's GitHub Pages. Generated HTML and all `Manifest.toml` files are ignored by Git.

### Updating the C bindings

The bindings are maintained by hand. The separate `gen/` environment uses Clang only for maintenance; it is not a runtime, test or documentation dependency. Generate reference output from the bundled lancedb-c header with:

```sh
julia --project=gen -e 'using Pkg; Pkg.instantiate()'
julia --project=gen gen/generator.jl
```

Compare `gen/bindings.generated.jl` with `src/api.jl`, `src/ctypes.jl` and high-level native calls. Check upstream ownership and error behavior before changing the wrappers. The generator does not overwrite source files. Arrow C ABI layouts in `src/arrow_abi.jl` are maintained manually.

## License

Licensed under the [Apache License 2.0](LICENSE), the same license used by [lancedb-c](https://github.com/lancedb/lancedb-c/blob/main/LICENSE).
