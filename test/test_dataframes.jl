using DataFrames

@testset "DataFrames through Tables" begin
    mktempdir() do path
        open(Connection,path) do db
            frame=DataFrame(id=[1,2,3],label=Union{Missing,String}["a",missing,"c"])
            table=create_table(db,"frames",view(frame,1:2,:))
            try
                add(table,frame[3:3,:])
                result=execute(query(table))
                try
                    output=DataFrame(result)
                    sort!(output,:id)
                    @test isequal(output,frame)
                    @test isequal(DataFrame(take_ids(table,[3,1])),frame[[3,1],:])
                finally
                    close(result)
                end
            finally
                close(table)
            end
        end
    end
end
