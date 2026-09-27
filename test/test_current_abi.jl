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
