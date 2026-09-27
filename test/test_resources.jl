@testset "Handle ownership" begin
    expr = col("id")
    @test_throws ArgumentError expr & expr
    @test isopen(expr)
    close(expr)
    @test_throws LanceDBException copy(expr)
    @test_throws ArgumentError Connection("invalid\0path")
    mktempdir() do path
        options = Dict("aws_region" => "us-east-1")
        db = Connection(path; storage_options=options)
        options["aws_region"] = "invalid\0region"
        try
            close(db)
            @test reopen!(db) === db
            table = create_table(db,"items",(id=[1,2],))
            @test_throws ArgumentError vector_search(table,Float32[NaN])
            @test_throws ArgumentError vector_search(table,[1e100])
            q = query(table)
            @test_throws ArgumentError limit(q,-1)
            close(q)
            @test_throws LanceDBException execute(q)
            close(table)
            @test_throws LanceDBException count_rows(table)
            @test_throws LanceDBException add(table,(id=[3],))
        finally
            close(db)
        end
    end
end
