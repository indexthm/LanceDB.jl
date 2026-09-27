@testset "Nested Arrow import" begin
    data = (x=Int32[1,2], y=["a","b"])
    array, schema, pins = LanceDB._to_arrow_c_abi(data)
    try
        GC.@preserve pins begin
            rows = LanceDB._read_column(unsafe_load(array), "+s", unsafe_load(schema))
            @test rows == [(x=Int32(1),y="a"),(x=Int32(2),y="b")]
        end
    finally
        LanceDB._free_array_tree(array)
        release_arrow_schema(schema)
    end

    pins = Any[]
    GC.@preserve pins begin
        dictionary, ds = LanceDB._column_to_arrow(["red","blue"], "dict", pins)
        codes, cs = LanceDB._column_to_arrow(Int8[0,1,0], "code", pins)
        try
            a, s = unsafe_load(codes), unsafe_load(cs)
            withdict = LanceDB.ArrowArray(a.length,a.null_count,a.offset,a.n_buffers,a.n_children,
                a.buffers,a.children,dictionary,a.release,a.private_data)
            dictschema = ArrowSchema(s.format,s.name,s.metadata,s.flags,s.n_children,
                s.children,ds,s.release,s.private_data)
            @test LanceDB._read_column(withdict, "c", dictschema) == ["red","blue","red"]
        finally
            LanceDB._free_array_tree(dictionary); release_arrow_schema(ds)
            LanceDB._free_array_tree(codes); release_arrow_schema(cs)
        end
    end

    pins = Any[]
    GC.@preserve pins begin
        child, cs = LanceDB._column_to_arrow(Int32[10,20,30], "item", pins)
        offsets = Int32[0,2,3]
        children, schemas = [child], [cs]
        buffers = Ptr{Cvoid}[C_NULL, pointer(offsets)]
        try
            GC.@preserve offsets children schemas buffers begin
                a = LanceDB.ArrowArray(2,0,0,2,1,pointer(buffers),pointer(children),C_NULL,C_NULL,C_NULL)
                s = ArrowSchema(C_NULL,C_NULL,C_NULL,0,1,pointer(schemas),C_NULL,C_NULL,C_NULL)
                @test LanceDB._read_column(a, "+l", s) == [Int32[10,20],Int32[30]]
            end
        finally
            LanceDB._free_array_tree(child); release_arrow_schema(cs)
        end
    end
end
