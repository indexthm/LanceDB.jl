@testset "Ownership and validation" begin
    a, b = col(:id), lit(1)
    @test_throws ArgumentError a & a
    @test isopen(a)
    close(b)
    @test_throws LanceDBException a == b
    @test isopen(a)
    close(a)
    @test_throws LanceDBException copy(a)
    @test_throws LanceDBException isin(a, lit(1))
    @test_throws ArgumentError col("id\0bad")
    @test_throws ArgumentError Connection("path\0bad")
    @test_throws ArgumentError LanceDB._to_arrow_c_abi((x=[1,2], y=[1]))
    @test_throws ArgumentError LanceDB._to_arrow_c_abi((x=[1], v=[[1,2],[1]]))
    @test_throws Exception LanceDB._to_arrow_c_abi((x=[1], unsupported=[1+2im]))
    mktempdir() do path
        open(Connection, path) do db
            t = create_table(db, "t", (id=[1,2], label=["bad", "also bad"]))
            q = query(t)
            @test_throws ArgumentError limit(q, -1)
            @test_throws ArgumentError select_cols(q, ["id\0bad"])
            @test isopen(q)
            close(q); close(q)
            @test_throws LanceDBException execute(q)
            q = query(t) |> filter_where("CAST(label AS INT) > 0")
            r = execute(q)
            @test_throws LanceDBException Tables.columns(r)
            @test !isopen(r)
            close(r); close(r)
            GC.gc()
            @test count_rows(t) == 2
            close(t)
            @test_throws LanceDBException count_rows(t)
            @test_throws LanceDBException query(t)
            @test_throws LanceDBException add(t, (id=[3],label=["x"]))
            open(Table, db, "t") do table
                @test count_rows(table) == 2
            end
        end
    end
end

@testset "Julia table inputs and conditional merges" begin
    mktempdir() do path
        open(Connection, path) do db
            # Nullable type must survive even when the first batch has no nulls.
            t = create_table(db, "append", (id=[1], value=Union{Missing,Int64}[10]))
            try
                @test table_schema(t).children[2].nullable
                add(t, [(id=2, value=missing)])
                @test ismissing(Tables.columns(execute(query(t))).value[2])
                parts = Tables.partitioner([(id=[3],value=Union{Missing,Int64}[30]),
                                            (id=[4],value=Union{Missing,Int64}[40])])
                @test append_partitions!(t, parts) === t
                @test count_rows(t) == 4
                merge_insert(t, (id=[1,3],value=[5,35]), :id;
                             condition="target.value < source.value")
                @test isequal(sort(Tables.columns(execute(query(t))).value; by=x->ismissing(x) ? 100 : x), [10,35,40,missing])
                condition = col("target.value") < col("source.value")
                merge_insert(t, (id=[1],value=[11]), [:id]; condition)
                @test isopen(condition) # the C API borrows this expression
                close(condition)
                @test Tables.columns(query(t) |> filter_where("id=1") |> execute).value == [11]
                @test_throws ArgumentError merge_insert(t, (id=[1],value=[12]), :id; condition=123)
                @test LanceDBVectorIndexConfig(num_partitions=4, replace=true).replace == 1
                create_scalar_index(t, :id; config=LanceDBScalarIndexConfig(replace=true))
                @test !isempty(list_indices(t))
            finally
                close(t)
            end
            strings = create_table(db, "text", (text=["hello world", "more words"],))
            try
                create_fts_index(strings, :text; base_tokenizer="simple", language="English")
                @test !isempty(list_indices(strings))
            finally
                close(strings)
            end
            data = collect(Int32, 1:10)
            views = create_table(db, "views", (x=@view(data[1:2:9]),))
            @test Tables.columns(execute(query(views))).x == Int32[1,3,5,7,9]
            close(views)
        end
    end
end

@testset "Multiple result batches" begin
    mktempdir() do path
        open(Connection, path) do db
            t = create_table(db, "batches", (id=collect(Int32,1:20000),))
            try
                r = execute(query(t))
                parts = Tables.partitions(r)
                @test length(parts) > 1
                @test sum(length(p.id) for p in parts) == 20000
                @test Tables.columns(r).id == collect(Int32,1:20000)
                @test Tables.columns(r) === Tables.columns(r)
                @test parts[1].id[1] == 1 # remains valid after concatenation
            finally
                close(t)
            end
        end
    end
end

@testset "Typed nullable Arrow roundtrip" begin
    data = (id=Int32[1,2,3],
            flag=Union{Missing,Bool}[true,missing,false],
            text=Union{Missing,String}["中文",missing,""],
            number=Union{Missing,Float64}[1.25,missing,3.5],
            doubles=[[1.25,2.5],[3.0,4.0],[5.0,6.0]],
            integers=[Int16[1,2],Int16[3,4],Int16[5,6]],
            nested=[Union{Missing,Int32}[1,missing],Union{Missing,Int32}[missing,4],Union{Missing,Int32}[5,6]])
    mktempdir() do path
        open(Connection, path) do db
            t = create_table(db, "typed", data)
            try
                schema = table_schema(t)
                @test schema.children[2].nullable
                @test schema.children[5].children[1].format == "g"
                r = execute(query(t))
                parts = collect(Tables.partitions(r))
                @test sum(length(p.id) for p in parts) == 3
                cols = Tables.columntable(r)
                for nm in keys(data)
                    @test isequal(cols[nm], data[nm])
                end
                @test eltype(cols.doubles) == Vector{Float64}
                @test eltype(cols.integers) == Vector{Int16}
                rows = Tables.rows(r)
                @test first(rows).id == 1
                @test first(rows)[:text] == "中文"
                @test collect(Tables.partitions(r))[1].id == cols.id
                close(r)
                @test Tables.columns(r) === cols
                add(t, data)
                @test count_rows(t) == 6
                selected = query(t) |> select_cols([:id,:flag]) |> execute |> Tables.columntable
                @test keys(selected) == (:id,:flag)
            finally
                close(t)
            end
        end
    end
end

@testset "Metadata, history, session and plans" begin
    session = Session(index_cache_bytes=1024^2, metadata_cache_bytes=1024^2)
    @test cache_stats(session).hits == 0
    @test cache_stats(session; cache=:metadata).size_bytes == 0
    @test_throws ArgumentError cache_stats(session; cache=:invalid)
    mktempdir() do path
        open(Connection, path; session) do db
            t = create_table(db, "meta", (id=[1,2,3], embedding=[Float32[1,0],Float32[0,1],Float32[1,1]]))
            try
                @test set_metadata!(t, Dict("author"=>"测试", "unit"=>"m")) === t
                @test get_metadata(t; keys=["author"]) == Dict("author"=>"测试")
                @test isempty(get_metadata(t; keys=String[]))
                @test delete_metadata!(t, ["unit", "absent"]) === t
                @test !haskey(get_metadata(t), "unit")
                versions = list_versions(t)
                @test length(versions) >= 3
                @test last(versions).version == table_version(t)
                @test Tables.istable(typeof(versions))
                q = query(t) |> filter_expr(0 < col(:id)) |> limit(2)
                @test !isempty(explain_plan(q))
                @test isopen(q)
                @test length(Tables.columns(execute(q)).id) == 2
                q = vector_search(t, [1.0,0.0], :embedding) |> limit(1)
                @test !isempty(explain_plan(q; verbose=true))
                @test Tables.columns(execute(q)).id == [1]
                delete_rows(t, col(:id) == lit(2))
                @test count_rows(t) == 2
                @test_throws ArgumentError set_metadata!(t, Dict("bad\0key"=>"x"))
            finally
                close(t)
            end
            @test table_names(db; limit=1) == ["meta"]
            @test isempty(table_names(db; start_after="meta"))
            @test_throws ArgumentError table_names(db; limit=-1)
            drop_all_tables(db)
            @test isempty(table_names(db))
        end
    end
    close(session); close(session)
    @test !isopen(session)
    @test_throws ArgumentError cache_stats(session)
end

@testset "JSON and list expressions" begin
    mktempdir() do path
        open(Connection, path) do db
            t = create_table(db, "json", (id=[1,2],
                metadata=["{\"name\":\"a\",\"n\":2,\"flag\":true,\"xs\":[\"x\",\"y\"]}",
                          "{\"name\":\"b\",\"n\":3,\"flag\":false,\"xs\":[\"z\"]}"],
                tags=[Int64[1,2],Int64[3,4]]))
            try
                expressions = [json_get_str(col(:metadata), "name") == lit("a"),
                    json_get_int(col(:metadata), "n") == 2,
                    json_get_float(col(:metadata), "n") == lit(2.0),
                    json_get_bool(col(:metadata), "flag") == lit(true),
                    json_array_has(col(:metadata), ["xs"], lit("x")),
                    array_has(col(:tags), lit(1))]
                for expr in expressions
                    @test Tables.columns(query(t) |> filter_expr(expr) |> execute).id == [1]
                end
                @test length(Tables.columns(query(t) |> filter_expr(json_contains(col(:metadata),"n")) |> execute).id) == 2
            finally
                close(t)
            end
        end
    end
end
