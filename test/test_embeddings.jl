@testset "Batched user encoders" begin
    calls = Ref(0)
    encoder(xs) = (calls[]+=1; [[Float32(length(x)),1.0f0] for x in xs])
    source = (id=[1,2,3],text=["a","abcd","xy"])
    encoded = with_embeddings(source,:text,encoder;batchsize=2)
    @test calls[] == 2
    @test encoded.embedding == [Float32[1,1],Float32[4,1],Float32[2,1]]
    @test encoded.id === source.id
    @test with_embeddings(source,:text,x->ones(Float32,2,length(x))).embedding == fill(Float32[1,1],3)
    @test_throws DimensionMismatch with_embeddings(source,:text,x->[Float32[1]])
    @test_throws ArgumentError with_embeddings(source,:text,x->[Float32[NaN] for _ in x])
    @test_throws ArgumentError with_embeddings(encoded,:text,encoder)
    @test_throws ArgumentError with_embeddings((text=String[],),:text,encoder)
    @test_throws ArgumentError with_embeddings(source,:text,x->fill(1+im,2,length(x)))
    @test_throws DimensionMismatch with_embeddings(source,:text,x->[ones(Float32,length(x)) for _ in x];batchsize=2)
    mktempdir() do path
        open(Connection,path) do db
            t = create_table(db,"embeddings",encoded)
            try
                @test Tables.columns(embedding_search(t,"1234",encoder) |> limit(1) |> execute).id == [2]
            finally
                close(t)
            end
        end
    end
end
