@testset "lancedb-c 0.33 ABI regressions" begin
    mktempdir() do root
        conn = Connection(joinpath(root, "database"))
        try
            # The native error code/message must survive the new out-parameter ABI.
            err = try
                open_table(conn, "missing_table")
                nothing
            catch e
                e
            end
            @test err isa LanceDBException
            if err isa LanceDBException
                @test err.code == Int32(LanceDB.LANCEDB_TABLE_NOT_FOUND)
                @test occursin("missing_table", err.message)
            end
            @test isempty(table_names(conn))

            tbl = create_table(conn, "items", (id=Int32[1, 2], value=Int32[10, 20]))
            try
                # Exercise the new tail fields, not just zero-initialized defaults.
                cfg = LanceDBMergeInsertConfig()
                condition = "source.value > target.value"
                GC.@preserve condition begin
                    cfg.when_matched_update_all_condition = pointer(condition)
                    merge_insert(tbl, (id=Int32[1, 2, 3], value=Int32[5, 25, 30]),
                                 "id"; config=cfg)
                end
                cols = Tables.columns(query(tbl) |> execute)
                @test Dict(zip(cols[:id], cols[:value])) == Dict(1=>10, 2=>25, 3=>30)
            finally
                close(tbl)
            end
        finally
            close(conn)
        end
    end
end
@testset "Table" begin
    @test LanceDBVectorIndexConfig() isa LanceDBVectorIndexConfig
    @test LanceDBScalarIndexConfig() isa LanceDBScalarIndexConfig
    @test LanceDBFtsIndexConfig() isa LanceDBFtsIndexConfig
    @test LanceDBMergeInsertConfig() isa LanceDBMergeInsertConfig

    # Verify default config values from the spec
    cfg = LanceDBVectorIndexConfig()
    @test cfg.num_partitions  == -1
    @test cfg.num_sub_vectors == -1
    @test cfg.distance_type   == Int32(L2)
end

@testset "VectorSearch" begin
    @testset "DistanceType enum" begin
        @test L2     == DistanceType(0)
        @test Cosine == DistanceType(1)
        @test Dot    == DistanceType(2)
        @test Hamming == DistanceType(3)
    end

    @testset "IndexType enum" begin
        @test Auto      == IndexType(0)
        @test BTree     == IndexType(1)
        @test IVFFlat   == IndexType(5)
        @test IVFHNSWsq == IndexType(8)
    end

    @testset "make_vector_schema" begin
        schema = make_vector_schema("key", "data", 8)
        @test schema != C_NULL
        release_arrow_schema(schema)
    end

    @testset "make_schema" begin
        schema = make_schema(["id" => "l", "text" => "u"])
        @test schema != C_NULL
        release_arrow_schema(schema)
    end
end

