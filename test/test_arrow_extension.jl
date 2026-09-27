using Arrow

function ipc_table(data; kwargs...)
    io = IOBuffer()
    Arrow.write(io, data; kwargs...)
    Arrow.Table(take!(io))
end

@testset "Optional Arrow ingestion" begin
    @test Base.get_extension(LanceDB, :LanceDBArrowExt) !== nothing
    numeric = ipc_table((id=Int64[1,2,3],))
    array, schema, pins = LanceDB._to_arrow_c_abi(numeric)
    try
        GC.@preserve pins begin
            child = unsafe_load(unsafe_load(Ptr{Ptr{LanceDB.ArrowArray}}(unsafe_load(array).children)))
            @test unsafe_load(Ptr{Ptr{Cvoid}}(child.buffers),2) == pointer(numeric.id.data)
            GC.gc()
            @test LanceDB._read_batch_columns(Ptr{Cvoid}(array),Ptr{Cvoid}(schema)).id == [1,2,3]
        end
    finally
        LanceDB._free_array_tree(array)
        release_arrow_schema(schema)
    end

    source = (id=Int64[1,2,3],
        bytes=Union{Missing,typeof(codeunits(""))}[codeunits("ab"),missing,codeunits("")],
        lists=Union{Missing,Vector{Int32}}[[1,2],missing,[]],
        embedding=Union{Missing,NTuple{2,Float32}}[(1,2),missing,(3,4)],
        value=Union{Missing,Float64}[1,missing,3],
        text=Union{Missing,String}["hello",missing,"你好"])
    for large in (false,true)
        input = ipc_table(source; largelists=large)
        array,schema,pins = LanceDB._to_arrow_c_abi(input)
        try
            GC.@preserve pins begin
                fields = LanceDB._schema_description(schema).children
                @test fields[2].format == (large ? "Z" : "z")
                @test fields[3].format == (large ? "+L" : "+l")
                @test fields[4].format == "+w:2"
                @test fields[6].format == (large ? "U" : "u")
            end
        finally
            LanceDB._free_array_tree(array)
            release_arrow_schema(schema)
        end
        mktempdir() do path
            open(Connection,path) do db
                table=create_table(db,"arrow",input)
                try
                    rows=take_ids(table,[1,2,3])
                    @test isequal(rows.bytes,[UInt8[0x61,0x62],missing,UInt8[]])
                    @test isequal(rows.lists,source.lists)
                    @test isequal(rows.embedding,[Float32[1,2],missing,Float32[3,4]])
                    @test isequal(rows.value,source.value)
                    @test isequal(rows.text,source.text)
                finally
                    close(table)
                end
            end
        end
    end
end
