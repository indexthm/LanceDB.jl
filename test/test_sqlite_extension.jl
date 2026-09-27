using SQLite

@testset "SQLite import" begin
    @test Base.get_extension(LanceDB, :LanceDBSQLiteExt) !== nothing
    source = SQLite.DB()
    try
        SQLite.load!((id=Int64[1,2], text=Union{Missing,String}["猫",missing], score=[1.5,2.5]), source, "source rows")
        mktempdir() do path
            open(Connection, path) do db
                table = import_sqlite(db, "items", source; source_table="source rows")
                try
                    rows = take_ids(table,[1,2])
                    @test isequal(rows.text,["猫",missing])
                    @test Base.nonmissingtype(eltype(rows.score)) === Float64
                    @test import_sqlite(table, source; sql="SELECT id+2 AS id, text, score FROM \"source rows\" WHERE id=?",params=(1,)) === table
                    @test count_rows(table) == 3
                    @test_throws Exception import_sqlite(table, source; sql="SELECT nonexistent FROM missing_table")
                    @test count_rows(table) == 3
                    @test_throws ArgumentError import_sqlite(table, source)
                    @test_throws ArgumentError import_sqlite(table, source; source_table="source rows", sql="SELECT 1")
                finally
                    close(table)
                end
                blobs = import_sqlite(db,"blobs",source;sql="SELECT 1 AS id, x'0102' AS bytes UNION ALL SELECT 2, x'03' UNION ALL SELECT 3, NULL")
                try
                    @test isequal(take_ids(blobs,[1,2,3]).bytes, [UInt8[1,2],UInt8[3],missing])
                finally
                    close(blobs)
                end
            end
        end
        @test only(Tables.columntable(SQLite.DBInterface.execute(source,"SELECT count(*) AS n FROM \"source rows\"")).n) == 2
    finally
        SQLite.close(source)
    end
end
