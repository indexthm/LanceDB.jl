@testset "Vector search execute" begin
    tmp = mktempdir()

    # Canonical 4-D unit-basis test data
    ids  = ["a", "b", "c", "d"]
    vecs = [Float32[1,0,0,0], Float32[0,1,0,0], Float32[0,0,1,0], Float32[0,0,0,1]]

    # ── 1. basic ANN: nearest first, _distance present ───────────────────────
    @testset "nearest neighbor ordering and _distance" begin
        conn = Connection(joinpath(tmp, "vs-basic"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |> limit(4) |> execute
        cols = Tables.columns(qr)

        @test haskey(cols, :id)
        @test haskey(cols, :vec)
        @test haskey(cols, :_distance)
        @test length(cols[:id]) == 4

        # Exact match is first with distance 0
        @test cols[:id][1] == "a"
        @test cols[:_distance][1] ≈ 0.0f0

        # All distances non-negative
        @test all(d -> d >= 0, cols[:_distance])

        # Results are distance-sorted
        @test issorted(cols[:_distance])

        close(tbl); close(conn)
    end

    # ── 2. limit controls result count ───────────────────────────────────────
    @testset "limit controls result count" begin
        conn = Connection(joinpath(tmp, "vs-limit"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        for k in 1:4
            cols = Tables.columns(vector_search(tbl, Float32[1,0,0,0], "vec") |> limit(k) |> execute)
            @test length(cols[:id]) == k
        end

        close(tbl); close(conn)
    end

    # ── 3. Cosine distance returns exact match with distance 0 ────────────────
    @testset "Cosine distance" begin
        conn = Connection(joinpath(tmp, "vs-cosine"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |>
               distance_type(Cosine) |>
               limit(4) |>
               execute
        cols = Tables.columns(qr)

        @test cols[:id][1] == "a"
        @test cols[:_distance][1] ≈ 0.0f0 atol=1f-6
        @test issorted(cols[:_distance])

        close(tbl); close(conn)
    end

    # ── 4. Dot distance ───────────────────────────────────────────────────────
    @testset "Dot distance" begin
        conn = Connection(joinpath(tmp, "vs-dot"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |>
               distance_type(Dot) |>
               limit(4) |>
               execute
        cols = Tables.columns(qr)

        @test length(cols[:id]) == 4
        @test cols[:id][1] == "a"   # best dot-product match still first

        close(tbl); close(conn)
    end

    # ── 5. vector_search without explicit column name ─────────────────────────
    @testset "implicit vector column" begin
        conn = Connection(joinpath(tmp, "vs-implicit"))
        # Table with only one vector column (named "vector" — LanceDB default)
        data = (id=ids, vector=vecs)
        tbl  = create_table(conn, "t", data)

        cols = Tables.columns(vector_search(tbl, Float32[1,0,0,0]) |> limit(2) |> execute)
        @test length(cols[:id]) == 2

        close(tbl); close(conn)
    end

    # ── 6. filter_where narrows candidates ───────────────────────────────────
    @testset "filter_where with vector search" begin
        conn = Connection(joinpath(tmp, "vs-filter"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        # Only rows where id != "a" — nearest among b,c,d should be b
        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |>
               filter_where("id != 'a'") |>
               limit(3) |>
               execute
        cols = Tables.columns(qr)

        @test !("a" in cols[:id])
        @test length(cols[:id]) <= 3

        close(tbl); close(conn)
    end

    # ── 7. select_cols limits returned columns ────────────────────────────────
    @testset "select_cols with vector search" begin
        conn = Connection(joinpath(tmp, "vs-select"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        # Request only id and _distance (no vec)
        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |>
               select_cols(["id", "_distance"]) |>
               limit(2) |>
               execute
        cols = Tables.columns(qr)

        @test haskey(cols, :id)
        @test haskey(cols, :_distance)
        @test !haskey(cols, :vec)
        @test length(cols[:id]) == 2

        close(tbl); close(conn)
    end

    # ── 8. multiple queries from the same table handle ────────────────────────
    @testset "multiple sequential queries" begin
        conn = Connection(joinpath(tmp, "vs-multi"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        for (q_vec, expected_id) in [
            (Float32[1,0,0,0], "a"),
            (Float32[0,1,0,0], "b"),
            (Float32[0,0,1,0], "c"),
            (Float32[0,0,0,1], "d"),
        ]
            cols = Tables.columns(vector_search(tbl, q_vec, "vec") |> limit(1) |> execute)
            @test cols[:id][1] == expected_id
        end

        close(tbl); close(conn)
    end

    # ── 9. add rows then vector search sees new data ──────────────────────────
    @testset "add then search" begin
        conn = Connection(joinpath(tmp, "vs-addthen"))
        schema = make_vector_schema("id", "vec", 2)
        tbl    = create_table(conn, "t", schema)
        release_arrow_schema(schema)

        add(tbl, (id=["x"], vec=[Float32[1, 0]]))
        add(tbl, (id=["y"], vec=[Float32[0, 1]]))

        cols = Tables.columns(vector_search(tbl, Float32[1, 0], "vec") |> limit(1) |> execute)
        @test cols[:id][1] == "x"
        @test cols[:_distance][1] ≈ 0.0f0

        close(tbl); close(conn)
    end

    # ── 10. _distance column is Float32 ──────────────────────────────────────
    @testset "_distance column element type" begin
        conn = Connection(joinpath(tmp, "vs-dtype"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        s = Tables.schema(vector_search(tbl, Float32[1,0,0,0], "vec") |> limit(2) |> execute)
        type_map = Dict(zip(s.names, s.types))
        @test type_map[:_distance] == Float32

        close(tbl); close(conn)
    end

    @testset "Invalid column leaves table usable" begin
        conn = Connection(joinpath(tmp, "vq-finalizer"))
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))
        qvec = Float32[1.0, 0.0, 0.0, 0.0]

        bad_col = String(copy(UInt8[0xFF]))   # invalid UTF-8 → column call fails

        @test_throws LanceDBException vector_search(tbl, qvec, bad_col)

        GC.gc(); GC.gc()

        cols = Tables.columns(vector_search(tbl, qvec, "vec") |> limit(1) |> execute)
        @test length(cols[:id]) == 1

        close(tbl); close(conn)
    end
end
