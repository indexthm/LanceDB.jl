# Supported features and usage notes

The native library is supplied by `LanceDB_C_jll` (lancedb-c 0.33). The available operations are summarized below; see the examples in the [user guide](guide.md) and [multimodal guide](multimodal.md).

| Task | Functions |
|---|---|
| Open a database | `Connection`, `open(Connection, ...) do` |
| Manage tables | `create_table`, `open_table`, `table_names`, `drop_table` |
| Write and update rows | `add`, `merge_insert`, `delete_rows` |
| Filter and select | `query`, `filter_where`, `filter_expr`, `select_cols`, `limit`, `offset` |
| Search embeddings | `vector_search`, `embedding_search` |
| Manage indexes | `create_scalar_index`, `create_vector_index`, `list_indices`, `index_stats`, `optimize` |
| Read results | `Tables.columns`, `Tables.rows`, `DataFrame(result)` |
| Store media and metadata | `BinaryColumn`, `ListColumn`, nested NamedTuples |
| Build training batches | `take_ids`, `IDDataset`, `batches`, `sample_rows`, `with_embeddings` |
| Inspect a table | `table_schema`, `table_version`, `get_metadata`, `list_versions` |
| Reuse caches | `Session`, `cache_stats` |

## Closing resources

Use `open` blocks for databases and existing tables:

```julia
open(Connection, "./my-database") do db
    open(Table, db, "items") do table
        result = execute(query(table) |> limit(10))
        try
            rows = Tables.columns(result)
        finally
            close(result)
        end
    end
end
```

Close newly created tables and unused queries with `close`. Julia result columns remain valid after closing the result. Executing a query consumes it; start another query to run again. Expressions are also consumed, so use `copy(expr)` before reusing one. Avoid operating on the same handle from concurrent tasks.

## Large datasets

Use `append_partitions!` to append input batches and `batches(dataset)` to fetch training samples incrementally. `Tables.partitions(result)` avoids joining result batches, but a single `execute` still collects the full query result internally. Select only needed columns and limit results when memory is constrained.

Each append is a separate commit: an error does not undo earlier batches. A dataset is not a snapshot; keep the source table unchanged while training. On Windows, index optimization can leave native file mappings open until process exit, preventing immediate deletion of the database directory.

## Current limitations

- FTS indexes can be created, but full-text queries and hybrid search are not available yet.
- Version history can be listed, but checkout/restore, schema alteration and general row-update expressions are unavailable.
- Video bytes can be stored and read, but extracting frames requires a decoder. Lazy Blob/range reads are not available.
- Namespaces and table rename depend on the backend. S3 connection examples are in the user guide; real cloud authentication is not covered by the local test suite.
- Supported input types include integers, Float32/Float64, Bool, strings, missing values, binary/list columns, nested records and Date/DateTime/Time. Decimal and other temporal formats are not supported.
- Arrow and DataFrames field metadata are not automatically preserved. Use `set_metadata!` for table metadata you need to keep.
- A completely empty native query result can have no column names; inspect `table_schema(table)` when you need the table's schema separately.
