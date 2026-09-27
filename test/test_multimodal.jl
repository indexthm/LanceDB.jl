@testset "Binary, lists and nested records" begin
    mktempdir() do path
        open(Connection,path) do db
            for large in (false,true)
                bytes = Union{Missing,Vector{UInt8}}[UInt8[0,255,128,1],UInt8[],missing]
                lists = Union{Missing,Vector{Int32}}[Int32[1,2],Int32[],missing]
                records = Union{Missing,@NamedTuple{score::Int32,label::String}}[(score=Int32(1),label="一"),missing,(score=Int32(3),label="三")]
                t = create_table(db,"media$large",(id=[1,2,3],
                    media=BinaryColumn(bytes;large), tags=ListColumn(lists;large), info=records))
                try
                    s = table_schema(t)
                    @test s.children[2].format == (large ? "Z" : "z")
                    @test s.children[3].format == (large ? "+L" : "+l")
                    r = Tables.columns(execute(query(t)))
                    @test isequal(r.media,bytes)
                    @test isequal(r.tags,lists)
                    @test isequal(r.info,records)
                    @test r.media isa BinaryColumn
                    @test r.tags isa ListColumn
                    copied = create_table(db,"copy$large",r)
                    @test table_schema(copied).children[2].format == (large ? "Z" : "z")
                    close(copied)
                    add(t,(id=[4],media=BinaryColumn([UInt8[2,3]];large),
                           tags=ListColumn([Int32[4,5,6]];large),info=[(score=Int32(4),label="四")]))
                    @test take_ids(t,[4,1];columns=[:media]).media == [UInt8[2,3],bytes[1]]
                finally
                    close(t)
                end
            end
            empty = create_table(db,"emptybinary",(id=Int64[],media=BinaryColumn(Vector{UInt8}[]),tags=ListColumn(Vector{String}[])))
            @test count_rows(empty) == 0
            close(empty)
            @test_throws ArgumentError BinaryColumn([[1,2]])
            @test_throws ArgumentError ListColumn([1,2])
            @test_throws ArgumentError BinaryColumn([missing])
            @test_throws ArgumentError ListColumn([missing])
            pins = Any[]
            GC.@preserve pins begin
                array,schema = LanceDB._column_to_arrow(BinaryColumn([UInt8[1]]),"bytes",pins)
                try
                    @test unsafe_load(schema).n_children == 0
                    @test unsafe_load(schema).children == C_NULL
                finally
                    LanceDB._free_array_tree(array)
                    release_arrow_schema(schema)
                end
            end
            nested = create_table(db,"nested",(id=[1,2],segments=ListColumn([
                [(start=1,label="a"),(start=2,label="b")],[(start=3,label="c")]])))
            try
                @test Tables.columns(execute(query(nested))).segments[1][2].label == "b"
            finally
                close(nested)
            end
        end
    end
end

@testset "Temporal data and empty manifests" begin
    D = LanceDB.Dates
    data = (id=[1,2], date=[D.Date(1960,1,1),D.Date(2026,9,27)],
            timestamp=Union{Missing,D.DateTime}[D.DateTime(2026,9,27,12,30,0,123),missing],
            time=[D.Time(1,2,3,4,5,6),D.Time(0)])
    mktempdir() do path
        open(Connection,path) do db
            t = create_table(db,"dates",data)
            try
                @test isequal(Tables.columns(execute(query(t))),data)
                @test isequal(take_ids(t,[2,1]).timestamp,reverse(data.timestamp))
                @test eltype(take_ids(t,Int[]).date) == D.Date
                empty = IDDataset(t;ids=Int[])
                @test isempty(collect(batches(empty)))
                @test isempty(sample_rows(empty,0).id)
                @test_throws ArgumentError sample_rows(empty,1;replace=true)
            finally
                close(t)
            end
        end
    end
end

@testset "Column marker preservation across batches" begin
    a,b = BinaryColumn([UInt8[1]]),BinaryColumn([UInt8[2,3]];large=true)
    @test vcat(a,b) isa BinaryColumn
    @test LanceDB._large(vcat(a,b))
    @test a[[1,1]] isa BinaryColumn
    @test copy(a) isa BinaryColumn
    @test vcat(ListColumn([[1]]),ListColumn([[2,3]])) isa ListColumn
    mktempdir() do path
        open(Connection,path) do db
            data = (id=collect(1:10000),bytes=BinaryColumn(fill(UInt8[1,0,255],10000)),
                    tags=ListColumn(fill(Int32[1,2],10000)))
            t = create_table(db,"batches",data)
            try
                result = execute(query(t))
                @test length(Tables.partitions(result)) > 1
                columns = Tables.columns(result)
                @test columns.bytes isa BinaryColumn
                @test columns.tags isa ListColumn
                @test columns.bytes[10000] == UInt8[1,0,255]
            finally
                close(t)
            end
        end
    end
end

@testset "Ordered indexed ID access and training batches" begin
    mktempdir() do path
        open(Connection,path) do db
            t = create_table(db,"samples",(id=Int64[10,30,50,90,110],label=["a","b","c","d","e"],media=BinaryColumn([UInt8[i] for i in 1:5])))
            try
                create_scalar_index(t,:id)
                @test take_ids(t,[90,10,90];batch_size=1).label == ["d","a","d"]
                @test keys(take_ids(t,[30];columns=[:media])) == (:media,)
                @test isempty(take_ids(t,Int[]).id)
                @test eltype(take_ids(t,Int[]).id) == Int64
                @test_throws KeyError take_ids(t,[20])
                @test take_ids(t,[10,20,30];on_missing=:skip).id == [10,30]
                @test_throws ArgumentError take_ids(t,[true])
                @test_throws ArgumentError take_ids(t,[1.0])
                @test_throws ArgumentError take_ids(t,[10];batch_size=0)
                @test_throws ArgumentError take_ids(t,[10];columns=[:absent])
                ds = IDDataset(t;batch_size=2)
                @test length(ds) == 5
                @test ds[2].id == 30
                @test ds[[5,1,5]].id == [110,10,110]
                @test_throws BoundsError ds[0]
                @test_throws BoundsError ds[[6]]
                @test_throws ArgumentError ds[[true]]
                @test_throws ArgumentError IDDataset(t;ids=[10,10])
                seq = collect(batches(ds;batchsize=2))
                @test length.(getproperty.(seq,:id)) == [2,2,1]
                @test vcat(getproperty.(seq,:id)...) == ds.ids
                @test length(collect(batches(ds;batchsize=2,drop_last=true))) == 2
                rng() = LanceDB.Random.MersenneTwister(12)
                shuffled1 = collect(batches(ds;batchsize=2,shuffle=true,rng=rng()))
                shuffled2 = collect(batches(ds;batchsize=2,shuffle=true,rng=rng()))
                @test shuffled1 == shuffled2
                @test sort(vcat(getproperty.(shuffled1,:id)...)) == ds.ids
                @test sample_rows(ds,3;rng=rng()) == sample_rows(ds,3;rng=rng())
                @test length(unique(sample_rows(ds,5;rng=rng()).id)) == 5
                @test length(sample_rows(ds,8;replace=true,rng=rng()).id) == 8
                @test_throws ArgumentError sample_rows(ds,6)
                @test isempty(sample_rows(ds,0).id)
                decoded = collect(batches(ds;batchsize=2,transform=b->sum(Int(only(x)) for x in b.media)))
                @test sum(decoded) == 15
                add(t,(id=[200],label=["f"],media=BinaryColumn([UInt8[6]])))
                @test_throws ArgumentError ds[1]
                close(t)
                @test_throws LanceDBException take_ids(t,[10])
            finally
                close(t)
            end
            dup = create_table(db,"duplicates",(id=[1,1,2],x=[1,2,3]))
            @test_throws ArgumentError take_ids(dup,[1,2])
            @test_throws ArgumentError IDDataset(dup)
            close(dup)
            strings = create_table(db,"stringids",(id=["a'b","中文","z"],x=[1,2,3]))
            @test take_ids(strings,["中文","a'b","中文"]).x == [2,1,2]
            close(strings)
            unusual = create_table(db,"unusual",NamedTuple{(Symbol("sample key"),:value)}(([1,2],["a","b"])))
            @test take_ids(unusual,[2,1];id_column="sample key",columns=[:value]).value == ["b","a"]
            close(unusual)
        end
    end
end
