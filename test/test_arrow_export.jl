@testset "Typed Arrow ingestion" begin
    @test_throws ArgumentError LanceDB._to_arrow_c_abi((id=[1,2],value=[1]))
    @test_throws ArgumentError LanceDB._to_arrow_c_abi((vec=[[1],[2,3]],))
    mktempdir() do path
        open(Connection,path) do db
            table = create_table(db,"typed",(
                id=[1,2], flag=Union{Missing,Bool}[true,missing],
                bytes=BinaryColumn([UInt8[1,2],UInt8[]]),
                lists=ListColumn([Int32[1],Int32[2,3]]),
                record=[(name="a",),(name="b",)],
                date=[LanceDB.Date(2020),LanceDB.Date(2021)],
            ))
            try
                @test count_rows(table) == 2
            finally
                close(table)
            end
        end
    end
    schema=make_schema(Pair{String,String}[])
    try
        @test unsafe_load(schema).children == C_NULL
    finally
        release_arrow_schema(schema)
    end
end
