using CSV

@testset "CSV import" begin
    @test Base.get_extension(LanceDB,:LanceDBCSVExt) !== nothing
    mktempdir() do path
        open(Connection,path) do db
            file=joinpath(path,"rows.csv")
            write(file,"id;text;score\n1;\"cat; dog\";2.5\n2;你好;NA\n")
            table=import_csv(db,"csv",file;delim=';',missingstring="NA",
                             types=Dict(:id=>Int64,:text=>String,:score=>Float64))
            try
                @test take_ids(table,[1]).text == ["cat; dog"]
                @test ismissing(only(take_ids(table,[2]).score))
                input=IOBuffer("id;text;score\n3;bird;4\n")
                @test import_csv(table,input;delim=';',types=Dict(:score=>Float64)) === table
                @test isopen(input)
                @test count_rows(table) == 3
                @test_throws Exception import_csv(table,IOBuffer("id,text,score\n4,bad,oops\n");types=Dict(:score=>Float64))
                @test count_rows(table) == 3
            finally
                close(table)
            end
            @test_throws LanceDBException import_csv(table,IOBuffer("id\n1\n"))
        end
    end
end
