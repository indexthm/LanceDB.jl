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
@testset "Nullable list schema is independent of batch values" begin
    descriptions = map((Union{Missing,Vector{Float32}}[[1,2]],
                        Union{Missing,Vector{Float32}}[[1,2],missing])) do values
        a,s,pins = LanceDB._to_arrow_c_abi((embedding=values,))
        try
            LanceDB._schema_description(s)
        finally
            LanceDB._free_array_tree(a)
            release_arrow_schema(s)
        end
    end
    @test descriptions[1] == descriptions[2]
    mktempdir() do path
        open(Connection,path) do db
            t = create_table(db,"nullable_vectors",
                (id=[1],embedding=Union{Missing,Vector{Float32}}[[1,2]]))
            try
                add(t,(id=[2,3],embedding=Union{Missing,Vector{Float32}}[missing,[3,4]]))
                @test isequal(take_ids(t,[3,2,1]).embedding,[Float32[3,4],missing,Float32[1,2]])
            finally
                close(t)
            end
        end
    end
end


@testset "Invalid Arrow schema reports a native error" begin
    data = (x = Int32[1, 2, 3],)

    arr_ptr, schema_ptr, pins = LanceDB._to_arrow_c_abi(data)

    root      = unsafe_load(schema_ptr)
    ch_ptrs   = Ptr{Ptr{LanceDB.ArrowSchema}}(root.children)
    child_ptr = unsafe_load(ch_ptrs, 1)    # pointer to the "x: Int32" schema
    child     = unsafe_load(child_ptr)
    Base.Libc.free(child.format)           # free the original "i" string
    bad_fmt   = LanceDB._malloc_cstr("ZZZZ_UNKNOWN_FORMAT")
    unsafe_store!(child_ptr, LanceDB.ArrowSchema(
        bad_fmt,          child.name,       child.metadata,
        child.flags,      child.n_children, child.children,
        child.dictionary, child.release,    child.private_data,
    ))

    reader_out = Ref{Ptr{LanceDB.LanceDBRecordBatchReaderHandle}}(C_NULL)
    errmsg     = Ref{Ptr{UInt8}}(C_NULL)
    local code
    GC.@preserve pins begin
        code = LanceDB.lancedb_record_batch_reader_from_arrow(
            Ptr{Cvoid}(arr_ptr), Ptr{Cvoid}(schema_ptr), reader_out, errmsg)
    end

    @test code != Cint(LanceDB.LANCEDB_SUCCESS)

    errmsg[] != C_NULL && LanceDB.lancedb_free_string(errmsg[])

    LanceDB._free_array_tree(arr_ptr)
    LanceDB.release_arrow_schema(schema_ptr)
end
