@testset "Query execute" begin
    tmp = mktempdir()

    # ── 1. full-table scan returns all rows ───────────────────────────────────
    @testset "full scan returns correct data" begin
        conn = Connection(joinpath(tmp, "q-scan"))
        data = (
            id    = Int64[10, 20, 30],
            score = Float32[1.5f0, 2.5f0, 3.5f0],
            label = ["alpha", "beta", "gamma"],
        )
        tbl = create_table(conn, "t", data)

        qr = query(tbl) |> execute
        @test qr isa QueryResult

        cols = Tables.columns(qr)
        @test sort(collect(keys(cols))) == [:id, :label, :score]
        @test sort(collect(cols[:id]))    == Int64[10, 20, 30]
        @test sort(collect(cols[:score])) == Float32[1.5f0, 2.5f0, 3.5f0]
        @test sort(collect(cols[:label])) == ["alpha", "beta", "gamma"]

        close(tbl)
        close(conn)
    end

    # ── 2. vector column round-trips correctly ────────────────────────────────
    @testset "vector column round-trip" begin
        conn = Connection(joinpath(tmp, "q-vec"))
        vecs = [Float32[1, 0, 0], Float32[0, 1, 0], Float32[0, 0, 1]]
        data = (id = ["a", "b", "c"], vec = vecs)
        tbl  = create_table(conn, "t", data)

        qr   = query(tbl) |> execute
        cols = Tables.columns(qr)
        got  = cols[:vec]

        @test length(got) == 3
        @test all(v -> length(v) == 3, got)
        # All original vectors appear in result (order may vary)
        for v in vecs
            @test any(r -> r ≈ v, got)
        end

        close(tbl)
        close(conn)
    end

    # ── 3. materialise is idempotent ──────────────────────────────────────────
    @testset "materialise idempotent" begin
        conn = Connection(joinpath(tmp, "q-idem"))
        tbl  = create_table(conn, "t", (x = Int32[1, 2],))

        qr = query(tbl) |> execute
        c1 = Tables.columns(qr)
        c2 = Tables.columns(qr)   # second access — should reuse cached data
        @test c1[:x] == c2[:x]

        close(tbl)
        close(conn)
    end

    # ── 4. empty table returns empty result ───────────────────────────────────
    @testset "empty table scan" begin
        conn   = Connection(joinpath(tmp, "q-empty"))
        schema = make_schema(["val" => "i"])
        tbl    = create_table(conn, "t", schema)
        release_arrow_schema(schema)

        qr   = query(tbl) |> execute
        cols = Tables.columns(qr)
        @test isempty(cols)

        close(tbl)
        close(conn)
    end

    # ── 5. Tables.schema returns correct types ────────────────────────────────
    @testset "Tables.schema types" begin
        conn = Connection(joinpath(tmp, "q-schema"))
        data = (a = Int32[1], b = Float64[2.0], c = ["x"])
        tbl  = create_table(conn, "t", data)

        qr = query(tbl) |> execute
        s  = Tables.schema(qr)
        @test s isa Tables.Schema
        type_map = Dict(zip(s.names, s.types))
        @test type_map[:a] == Int32
        @test type_map[:b] == Float64
        @test type_map[:c] == String

        close(tbl)
        close(conn)
    end
end
