using JSON

@testset "JSON import" begin
    @test Base.get_extension(LanceDB,:LanceDBJSONExt) !== nothing
    mktempdir() do path
        open(Connection,path) do db
            json_rows = """[{"id":1,"text":"你好","score":1.5},{"id":2,"text":null}]"""
            table=import_json(db,"rows",IOBuffer(json_rows))
            try
                result=take_ids(table,[2,1])
                @test isequal(result.text,[missing,"你好"])
                @test isequal(result.score,[missing,1.5])
                @test Base.nonmissingtype(eltype(result.score)) === Float64
                columns=IOBuffer("""{"id":[3],"text":["bird"],"score":[2.5]}""")
                @test import_json(table,columns) === table
                @test isopen(columns)
                @test count_rows(table) == 3
            finally
                close(table)
            end
            file=joinpath(path,"rows.jsonl")
            write(file,"{\"id\":1,\"text\":\"cat\"}\n{\"id\":2,\"text\":\"dog\"}\n")
            table=import_json(db,"lines",file)
            try
                @test count_rows(table) == 2
                import_json(table,IOBuffer("{\"id\":3,\"text\":\"bird\"}\n");jsonlines=true)
                @test take_ids(table,[3]).text == ["bird"]
                @test_throws Exception import_json(table,IOBuffer("{\"id\":4}\ninvalid");jsonlines=true)
                @test count_rows(table) == 3
            finally
                close(table)
            end
            data="""[{"id":1,"embedding":[1,0],"tags":["cat","outdoor"]},
                      {"id":2,"embedding":[0,1],"tags":[]}]"""
            table=import_json(db,"vectors",IOBuffer(data);vector_columns=[:embedding])
            try
                result=execute(vector_search(table,[1,0],:embedding) |> limit(1))
                try
                    @test Tables.columns(result).id == [1]
                finally
                    close(result)
                end
                rows=take_ids(table,[1,2])
                @test rows.tags isa ListColumn
                @test rows.tags == [["cat","outdoor"],String[]]
                @test Base.nonmissingtype(eltype(first(rows.embedding))) === Float32
            finally
                close(table)
            end
            table=import_json(db,"double_vectors",IOBuffer("""[{"id":1,"embedding":[1.0000000001,0]},{"id":2,"embedding":[0,1]}]""");
                              vector_columns=[:embedding],types=Dict(:embedding=>Vector{Float64}))
            try
                saved=take_ids(table,[1]).embedding[1]
                @test Base.nonmissingtype(eltype(saved)) === Float64
                @test saved[1] == 1.0000000001
                result=execute(vector_search(table,[1.0000000001,0],:embedding) |> limit(1))
                try
                    @test Tables.columns(result).id == [1]
                finally
                    close(result)
                end
            finally
                close(table)
            end
            table=import_json(db,"empty",IOBuffer("[]");types=Dict(:id=>Int64,:tags=>Vector{String}))
            try
                @test count_rows(table)==0
                import_json(table,IOBuffer("""[{"id":1,"tags":["cat"]}]"""))
                @test take_ids(table,[1]).tags == [["cat"]]
            finally
                close(table)
            end

            for bad in ("[]", "42", "[1,2]", "{\"id\":1}",
                        "{\"id\":[1,2],\"text\":[\"cat\"]}",
                        "[{\"value\":1},{\"value\":\"cat\"}]",
                        "[{\"value\":{\"nested\":1}}]",
                        "[{\"value\":[[1],[2,3]]}]",
                        "[{\"value\":9007199254740993},{\"value\":1.5}]")
                @test_throws ArgumentError import_json(db,"bad",IOBuffer(bad))
                @test !("bad" in table_names(db))
            end
            for bad in ("[[1,2],[1]]","[[true,false]]","[[1,null]]","[[1e100,2]]","[[]]","[null]")
                @test_throws ArgumentError import_json(db,"bad",IOBuffer("{\"embedding\":$bad}");vector_columns=[:embedding])
            end
            @test_throws ArgumentError import_json(db,"bad",IOBuffer(json_rows);types=Dict(:absent=>Int))
            @test_throws ArgumentError import_json(db,"bad",IOBuffer(json_rows);vector_columns=[:absent])
            @test_throws ArgumentError import_json(db,"bad",IOBuffer(json_rows);types=Dict(:id=>"integer"))
        end
    end
end
