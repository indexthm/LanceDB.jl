# Hand-written wrappers matching the header shipped with LanceDB_C_jll 0.33.0+0.
# Recheck signatures and ctypes.jl layouts together when updating the JLL.
#
# Signatures are derived directly from lancedb-c/include/lancedb.h.
# All C enums are passed/returned as Cint.
# FFI_ArrowSchema / FFI_ArrowArray are treated as Ptr{Cvoid} in ccall
# because the header forward-declares them as opaque structs.

# ── Connection builder ────────────────────────────────────────────────────────

function lancedb_connect(uri::AbstractString)
    ccall((:lancedb_connect, liblancedb),
          Ptr{LanceDBConnectBuilderHandle}, (Cstring,), uri)
end

function lancedb_connect_builder_execute(builder::Ptr{LanceDBConnectBuilderHandle},
                                         connection::Ref{Ptr{LanceDBConnectionHandle}},
                                         errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_connect_builder_execute, liblancedb),
          Cint, (Ptr{LanceDBConnectBuilderHandle}, Ref{Ptr{LanceDBConnectionHandle}}, Ref{Ptr{UInt8}}),
          builder, connection, errmsg)
end

function lancedb_connect_builder_storage_option(builder::Ptr{LanceDBConnectBuilderHandle},
                                                 key::AbstractString, value::AbstractString)
    ccall((:lancedb_connect_builder_storage_option, liblancedb),
          Ptr{LanceDBConnectBuilderHandle},
          (Ptr{LanceDBConnectBuilderHandle}, Cstring, Cstring),
          builder, key, value)
end

function lancedb_connect_builder_session(builder::Ptr{LanceDBConnectBuilderHandle},
                                          session::Ptr{LanceDBSessionHandle})
    ccall((:lancedb_connect_builder_session, liblancedb),
          Ptr{LanceDBConnectBuilderHandle},
          (Ptr{LanceDBConnectBuilderHandle}, Ptr{LanceDBSessionHandle}),
          builder, session)
end

function lancedb_connect_builder_free(builder::Ptr{LanceDBConnectBuilderHandle})
    ccall((:lancedb_connect_builder_free, liblancedb),
          Cvoid, (Ptr{LanceDBConnectBuilderHandle},), builder)
end

# ── Connection ────────────────────────────────────────────────────────────────

function lancedb_connection_uri(conn::Ptr{LanceDBConnectionHandle})
    ccall((:lancedb_connection_uri, liblancedb),
          Ptr{UInt8}, (Ptr{LanceDBConnectionHandle},), conn)
end

function lancedb_connection_table_names(conn::Ptr{LanceDBConnectionHandle},
                                         names_out::Ref{Ptr{Ptr{UInt8}}},
                                         count_out::Ref{Csize_t},
                                         errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_connection_table_names, liblancedb), Cint,
          (Ptr{LanceDBConnectionHandle}, Ref{Ptr{Ptr{UInt8}}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
          conn, names_out, count_out, errmsg)
end

function lancedb_free_table_names(names::Ptr{Ptr{UInt8}}, count::Csize_t)
    ccall((:lancedb_free_table_names, liblancedb),
          Cvoid, (Ptr{Ptr{UInt8}}, Csize_t), names, count)
end

function lancedb_connection_open_table(conn::Ptr{LanceDBConnectionHandle}, name::AbstractString,
                                       table_out::Ref{Ptr{LanceDBTableHandle}},
                                       errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_connection_open_table, liblancedb),
          Cint, (Ptr{LanceDBConnectionHandle}, Cstring, Ref{Ptr{LanceDBTableHandle}}, Ref{Ptr{UInt8}}),
          conn, name, table_out, errmsg)
end

function lancedb_connection_drop_table(conn::Ptr{LanceDBConnectionHandle},
                                        name::AbstractString,
                                        namespace_::Ptr{UInt8},
                                        errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_connection_drop_table, liblancedb), Cint,
          (Ptr{LanceDBConnectionHandle}, Cstring, Ptr{UInt8}, Ref{Ptr{UInt8}}),
          conn, name, namespace_, errmsg)
end

function lancedb_connection_drop_all_tables(conn::Ptr{LanceDBConnectionHandle},
                                             namespace_::Ptr{UInt8},
                                             errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_connection_drop_all_tables, liblancedb), Cint,
          (Ptr{LanceDBConnectionHandle}, Ptr{UInt8}, Ref{Ptr{UInt8}}),
          conn, namespace_, errmsg)
end

function lancedb_connection_free(conn::Ptr{LanceDBConnectionHandle})
    ccall((:lancedb_connection_free, liblancedb),
          Cvoid, (Ptr{LanceDBConnectionHandle},), conn)
end

# ── Session ───────────────────────────────────────────────────────────────────

function lancedb_session_new(options::Ref{LanceDBSessionOptions})
    ccall((:lancedb_session_new, liblancedb),
          Ptr{LanceDBSessionHandle}, (Ref{LanceDBSessionOptions},), options)
end

function lancedb_session_free(session::Ptr{LanceDBSessionHandle})
    ccall((:lancedb_session_free, liblancedb),
          Cvoid, (Ptr{LanceDBSessionHandle},), session)
end

# ── Table ─────────────────────────────────────────────────────────────────────

function lancedb_table_free(tbl::Ptr{LanceDBTableHandle})
    ccall((:lancedb_table_free, liblancedb),
          Cvoid, (Ptr{LanceDBTableHandle},), tbl)
end

# schema_ptr is Ptr{Cvoid} (opaque FFI_ArrowSchema*); reader may be C_NULL.
function lancedb_table_create(conn::Ptr{LanceDBConnectionHandle},
                               name::AbstractString,
                               schema_ptr::Ptr{Cvoid},
                               reader::Ptr{LanceDBRecordBatchReaderHandle},
                               table_out::Ref{Ptr{LanceDBTableHandle}},
                               errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_create, liblancedb), Cint,
          (Ptr{LanceDBConnectionHandle}, Cstring, Ptr{Cvoid},
           Ptr{LanceDBRecordBatchReaderHandle}, Ref{Ptr{LanceDBTableHandle}}, Ref{Ptr{UInt8}}),
          conn, name, schema_ptr, reader, table_out, errmsg)
end

function lancedb_table_arrow_schema(tbl::Ptr{LanceDBTableHandle},
                                     schema_out::Ref{Ptr{Cvoid}},
                                     errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_arrow_schema, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ref{Ptr{Cvoid}}, Ref{Ptr{UInt8}}),
          tbl, schema_out, errmsg)
end

function lancedb_table_version(tbl::Ptr{LanceDBTableHandle})
    ccall((:lancedb_table_version, liblancedb), UInt64, (Ptr{LanceDBTableHandle},), tbl)
end

function lancedb_table_count_rows(tbl::Ptr{LanceDBTableHandle})
    ccall((:lancedb_table_count_rows, liblancedb), UInt64, (Ptr{LanceDBTableHandle},), tbl)
end

function lancedb_table_add(tbl::Ptr{LanceDBTableHandle},
                            reader::Ptr{LanceDBRecordBatchReaderHandle},
                            errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_add, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ptr{LanceDBRecordBatchReaderHandle}, Ref{Ptr{UInt8}}),
          tbl, reader, errmsg)
end

function lancedb_table_merge_insert(tbl::Ptr{LanceDBTableHandle},
                                     data::Ptr{LanceDBRecordBatchReaderHandle},
                                     on_columns::Ptr{Ptr{UInt8}},
                                     num_columns::Csize_t,
                                     config::Ref{LanceDBMergeInsertConfig},
                                     errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_merge_insert, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ptr{LanceDBRecordBatchReaderHandle},
           Ptr{Ptr{UInt8}}, Csize_t, Ref{LanceDBMergeInsertConfig}, Ref{Ptr{UInt8}}),
          tbl, data, on_columns, num_columns, config, errmsg)
end

function lancedb_table_delete(tbl::Ptr{LanceDBTableHandle},
                               predicate::AbstractString,
                               errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_delete, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Cstring, Ref{Ptr{UInt8}}),
          tbl, predicate, errmsg)
end

# ── Record batch reader ────────────────────────────────────────────────────────

# Both array and schema are Ptr{Cvoid} (opaque FFI_ArrowArray* / FFI_ArrowSchema*).
function lancedb_record_batch_reader_from_arrow(array::Ptr{Cvoid},
                                                 schema::Ptr{Cvoid},
                                                 reader_out::Ref{Ptr{LanceDBRecordBatchReaderHandle}},
                                                 errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_record_batch_reader_from_arrow, liblancedb), Cint,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ref{Ptr{LanceDBRecordBatchReaderHandle}}, Ref{Ptr{UInt8}}),
          array, schema, reader_out, errmsg)
end

function lancedb_record_batch_reader_free(reader::Ptr{LanceDBRecordBatchReaderHandle})
    ccall((:lancedb_record_batch_reader_free, liblancedb),
          Cvoid, (Ptr{LanceDBRecordBatchReaderHandle},), reader)
end

function lancedb_free_arrow_schema(schema::Ptr{Cvoid})
    ccall((:lancedb_free_arrow_schema, liblancedb), Cvoid, (Ptr{Cvoid},), schema)
end

# ── Query ─────────────────────────────────────────────────────────────────────

function lancedb_query_new(tbl::Ptr{LanceDBTableHandle})
    ccall((:lancedb_query_new, liblancedb),
          Ptr{LanceDBQueryHandle}, (Ptr{LanceDBTableHandle},), tbl)
end

function lancedb_query_limit(q::Ptr{LanceDBQueryHandle}, limit::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_query_limit, liblancedb), Cint,
          (Ptr{LanceDBQueryHandle}, Csize_t, Ref{Ptr{UInt8}}), q, limit, errmsg)
end

function lancedb_query_offset(q::Ptr{LanceDBQueryHandle}, offset::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_query_offset, liblancedb), Cint,
          (Ptr{LanceDBQueryHandle}, Csize_t, Ref{Ptr{UInt8}}), q, offset, errmsg)
end

function lancedb_query_select(q::Ptr{LanceDBQueryHandle},
                               cols::Ptr{Ptr{UInt8}}, n::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_query_select, liblancedb), Cint,
          (Ptr{LanceDBQueryHandle}, Ptr{Ptr{UInt8}}, Csize_t, Ref{Ptr{UInt8}}),
          q, cols, n, errmsg)
end

function lancedb_query_where_filter(q::Ptr{LanceDBQueryHandle}, filter::AbstractString, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_query_where_filter, liblancedb), Cint,
          (Ptr{LanceDBQueryHandle}, Cstring, Ref{Ptr{UInt8}}), q, filter, errmsg)
end

function lancedb_query_df_filter(q::Ptr{LanceDBQueryHandle},
                                  expr::Ptr{LanceDBExprHandle}, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_query_df_filter, liblancedb), Cint,
          (Ptr{LanceDBQueryHandle}, Ptr{LanceDBExprHandle}, Ref{Ptr{UInt8}}),
          q, expr, errmsg)
end

function lancedb_query_execute(q::Ptr{LanceDBQueryHandle})
    ccall((:lancedb_query_execute, liblancedb),
          Ptr{LanceDBQueryResultHandle}, (Ptr{LanceDBQueryHandle},), q)
end

function lancedb_query_free(q::Ptr{LanceDBQueryHandle})
    ccall((:lancedb_query_free, liblancedb), Cvoid, (Ptr{LanceDBQueryHandle},), q)
end

# ── Vector query ──────────────────────────────────────────────────────────────

function lancedb_vector_query_new(tbl::Ptr{LanceDBTableHandle},
                                   vector::Ptr{Cfloat}, dimension::Csize_t)
    ccall((:lancedb_vector_query_new, liblancedb),
          Ptr{LanceDBVectorQueryHandle},
          (Ptr{LanceDBTableHandle}, Ptr{Cfloat}, Csize_t),
          tbl, vector, dimension)
end

function lancedb_vector_query_limit(q::Ptr{LanceDBVectorQueryHandle}, limit::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_limit, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Csize_t, Ref{Ptr{UInt8}}), q, limit, errmsg)
end

function lancedb_vector_query_offset(q::Ptr{LanceDBVectorQueryHandle}, offset::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_offset, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Csize_t, Ref{Ptr{UInt8}}), q, offset, errmsg)
end

function lancedb_vector_query_column(q::Ptr{LanceDBVectorQueryHandle}, col::AbstractString, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_column, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Cstring, Ref{Ptr{UInt8}}), q, col, errmsg)
end

function lancedb_vector_query_select(q::Ptr{LanceDBVectorQueryHandle},
                                      cols::Ptr{Ptr{UInt8}}, n::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_select, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Ptr{Ptr{UInt8}}, Csize_t, Ref{Ptr{UInt8}}),
          q, cols, n, errmsg)
end

function lancedb_vector_query_where_filter(q::Ptr{LanceDBVectorQueryHandle}, filter::AbstractString, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_where_filter, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Cstring, Ref{Ptr{UInt8}}), q, filter, errmsg)
end

function lancedb_vector_query_df_filter(q::Ptr{LanceDBVectorQueryHandle},
                                         expr::Ptr{LanceDBExprHandle}, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_df_filter, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Ptr{LanceDBExprHandle}, Ref{Ptr{UInt8}}),
          q, expr, errmsg)
end

function lancedb_vector_query_distance_type(q::Ptr{LanceDBVectorQueryHandle},
                                             dt::Cint, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_distance_type, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Cint, Ref{Ptr{UInt8}}), q, dt, errmsg)
end

function lancedb_vector_query_nprobes(q::Ptr{LanceDBVectorQueryHandle}, n::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_nprobes, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Csize_t, Ref{Ptr{UInt8}}), q, n, errmsg)
end

function lancedb_vector_query_refine_factor(q::Ptr{LanceDBVectorQueryHandle}, k::Cuint, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_refine_factor, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Cuint, Ref{Ptr{UInt8}}), q, k, errmsg)
end

function lancedb_vector_query_ef(q::Ptr{LanceDBVectorQueryHandle}, ef::Csize_t, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_vector_query_ef, liblancedb), Cint,
          (Ptr{LanceDBVectorQueryHandle}, Csize_t, Ref{Ptr{UInt8}}), q, ef, errmsg)
end

function lancedb_vector_query_execute(q::Ptr{LanceDBVectorQueryHandle})
    ccall((:lancedb_vector_query_execute, liblancedb),
          Ptr{LanceDBQueryResultHandle}, (Ptr{LanceDBVectorQueryHandle},), q)
end

function lancedb_vector_query_free(q::Ptr{LanceDBVectorQueryHandle})
    ccall((:lancedb_vector_query_free, liblancedb), Cvoid, (Ptr{LanceDBVectorQueryHandle},), q)
end

# ── Query result ──────────────────────────────────────────────────────────────

# result_arrays_out → Ptr{Ptr{Cvoid}} (receives FFI_ArrowArray**)
# result_schema_out → Ref{Ptr{Cvoid}} (receives FFI_ArrowSchema*)
function lancedb_query_result_to_arrow(result::Ptr{LanceDBQueryResultHandle},
                                        result_arrays_out::Ref{Ptr{Ptr{Cvoid}}},
                                        result_schema_out::Ref{Ptr{Cvoid}},
                                        count_out::Ref{Csize_t},
                                        errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_query_result_to_arrow, liblancedb), Cint,
          (Ptr{LanceDBQueryResultHandle},
           Ref{Ptr{Ptr{Cvoid}}}, Ref{Ptr{Cvoid}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
          result, result_arrays_out, result_schema_out, count_out, errmsg)
end

function lancedb_query_result_free(result::Ptr{LanceDBQueryResultHandle})
    ccall((:lancedb_query_result_free, liblancedb),
          Cvoid, (Ptr{LanceDBQueryResultHandle},), result)
end

function lancedb_free_arrow_arrays(arrays::Ptr{Ptr{Cvoid}}, count::Csize_t)
    ccall((:lancedb_free_arrow_arrays, liblancedb),
          Cvoid, (Ptr{Ptr{Cvoid}}, Csize_t), arrays, count)
end

function lancedb_table_nearest_to(tbl::Ptr{LanceDBTableHandle},
                                   vector::Ptr{Cfloat}, dimension::Csize_t, limit::Csize_t,
                                   column::Ptr{UInt8},
                                   result_arrays_out::Ref{Ptr{Ptr{Cvoid}}},
                                   result_schema_out::Ref{Ptr{Cvoid}},
                                   count_out::Ref{Csize_t},
                                   errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_nearest_to, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ptr{Cfloat}, Csize_t, Csize_t, Ptr{UInt8},
           Ref{Ptr{Ptr{Cvoid}}}, Ref{Ptr{Cvoid}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
          tbl, vector, dimension, limit, column,
          result_arrays_out, result_schema_out, count_out, errmsg)
end

# ── Index ─────────────────────────────────────────────────────────────────────

function lancedb_table_create_vector_index(tbl::Ptr{LanceDBTableHandle},
                                            cols::Ptr{Ptr{UInt8}}, n::Csize_t,
                                            itype::Cint,
                                            cfg::Ref{LanceDBVectorIndexConfig},
                                            errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_create_vector_index, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ptr{Ptr{UInt8}}, Csize_t, Cint,
           Ref{LanceDBVectorIndexConfig}, Ref{Ptr{UInt8}}),
          tbl, cols, n, itype, cfg, errmsg)
end

function lancedb_table_create_scalar_index(tbl::Ptr{LanceDBTableHandle},
                                            cols::Ptr{Ptr{UInt8}}, n::Csize_t,
                                            itype::Cint,
                                            cfg::Ref{LanceDBScalarIndexConfig},
                                            errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_create_scalar_index, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ptr{Ptr{UInt8}}, Csize_t, Cint,
           Ref{LanceDBScalarIndexConfig}, Ref{Ptr{UInt8}}),
          tbl, cols, n, itype, cfg, errmsg)
end

function lancedb_table_create_fts_index(tbl::Ptr{LanceDBTableHandle},
                                         cols::Ptr{Ptr{UInt8}}, n::Csize_t,
                                         cfg::Ref{LanceDBFtsIndexConfig},
                                         errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_create_fts_index, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ptr{Ptr{UInt8}}, Csize_t,
           Ref{LanceDBFtsIndexConfig}, Ref{Ptr{UInt8}}),
          tbl, cols, n, cfg, errmsg)
end

function lancedb_table_list_indices(tbl::Ptr{LanceDBTableHandle},
                                     indices_out::Ref{Ptr{Ptr{UInt8}}},
                                     count_out::Ref{Csize_t},
                                     errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_list_indices, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Ref{Ptr{Ptr{UInt8}}}, Ref{Csize_t}, Ref{Ptr{UInt8}}),
          tbl, indices_out, count_out, errmsg)
end

function lancedb_free_index_list(indices::Ptr{Ptr{UInt8}}, count::Csize_t)
    ccall((:lancedb_free_index_list, liblancedb),
          Cvoid, (Ptr{Ptr{UInt8}}, Csize_t), indices, count)
end

function lancedb_table_drop_index(tbl::Ptr{LanceDBTableHandle},
                                   name::AbstractString, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_drop_index, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Cstring, Ref{Ptr{UInt8}}), tbl, name, errmsg)
end

function lancedb_table_optimize(tbl::Ptr{LanceDBTableHandle},
                                 otype::Cint, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_optimize, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Cint, Ref{Ptr{UInt8}}), tbl, otype, errmsg)
end

function lancedb_table_index_stats(tbl::Ptr{LanceDBTableHandle},
                                    name::AbstractString,
                                    stats_out::Ref{LanceDBIndexStats},
                                    errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_table_index_stats, liblancedb), Cint,
          (Ptr{LanceDBTableHandle}, Cstring, Ref{LanceDBIndexStats}, Ref{Ptr{UInt8}}),
          tbl, name, stats_out, errmsg)
end

# ── DataFusion expression builder ─────────────────────────────────────────────

function lancedb_expr_column(name::AbstractString)
    ccall((:lancedb_expr_column, liblancedb),
          Ptr{LanceDBExprHandle}, (Cstring,), name)
end

function lancedb_expr_literal_string(value::AbstractString)
    ccall((:lancedb_expr_literal_string, liblancedb),
          Ptr{LanceDBExprHandle}, (Cstring,), value)
end

function lancedb_expr_literal_i64(value::Int64)
    ccall((:lancedb_expr_literal_i64, liblancedb),
          Ptr{LanceDBExprHandle}, (Int64,), value)
end

function lancedb_expr_literal_f64(value::Float64)
    ccall((:lancedb_expr_literal_f64, liblancedb),
          Ptr{LanceDBExprHandle}, (Float64,), value)
end

function lancedb_expr_literal_bool(value::Bool)
    ccall((:lancedb_expr_literal_bool, liblancedb),
          Ptr{LanceDBExprHandle}, (Bool,), value)
end

function lancedb_expr_binary(left::Ptr{LanceDBExprHandle}, op::Cint, right::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_binary, liblancedb),
          Ptr{LanceDBExprHandle},
          (Ptr{LanceDBExprHandle}, Cint, Ptr{LanceDBExprHandle}),
          left, op, right)
end

function lancedb_expr_not(expr::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_not, liblancedb),
          Ptr{LanceDBExprHandle}, (Ptr{LanceDBExprHandle},), expr)
end

function lancedb_expr_is_null(expr::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_is_null, liblancedb),
          Ptr{LanceDBExprHandle}, (Ptr{LanceDBExprHandle},), expr)
end

function lancedb_expr_is_not_null(expr::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_is_not_null, liblancedb),
          Ptr{LanceDBExprHandle}, (Ptr{LanceDBExprHandle},), expr)
end

function lancedb_expr_and(left::Ptr{LanceDBExprHandle}, right::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_and, liblancedb),
          Ptr{LanceDBExprHandle},
          (Ptr{LanceDBExprHandle}, Ptr{LanceDBExprHandle}),
          left, right)
end

function lancedb_expr_or(left::Ptr{LanceDBExprHandle}, right::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_or, liblancedb),
          Ptr{LanceDBExprHandle},
          (Ptr{LanceDBExprHandle}, Ptr{LanceDBExprHandle}),
          left, right)
end

function lancedb_expr_in_list(expr::Ptr{LanceDBExprHandle},
                               list::Ptr{Ptr{LanceDBExprHandle}}, list_len::Csize_t,
                               negated::Bool, errmsg::Ref{Ptr{UInt8}})
    ccall((:lancedb_expr_in_list, liblancedb),
          Ptr{LanceDBExprHandle},
          (Ptr{LanceDBExprHandle}, Ptr{Ptr{LanceDBExprHandle}}, Csize_t, Bool, Ref{Ptr{UInt8}}),
          expr, list, list_len, negated, errmsg)
end

function lancedb_expr_clone(expr::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_clone, liblancedb),
          Ptr{LanceDBExprHandle}, (Ptr{LanceDBExprHandle},), expr)
end

function lancedb_expr_free(expr::Ptr{LanceDBExprHandle})
    ccall((:lancedb_expr_free, liblancedb),
          Cvoid, (Ptr{LanceDBExprHandle},), expr)
end

# ── Utilities ─────────────────────────────────────────────────────────────────

function lancedb_free_string(ptr::Ptr{UInt8})
    ccall((:lancedb_free_string, liblancedb), Cvoid, (Ptr{UInt8},), ptr)
end
