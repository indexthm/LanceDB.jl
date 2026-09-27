_normalize(v::Vector{Float32}) = v ./ max(sqrt(sum(v.^2)), 1f-9)

@testset "Integration" begin
    tmp = mktempdir()

    # ── 1. Data persists across connection close/reopen ───────────────────────
    @testset "persistence across reconnect" begin
        db = joinpath(tmp, "persist")

        # Write
        conn1 = Connection(db)
        tbl1  = create_table(conn1, "items",
                    (id = Int32[1,2,3], label = ["a","b","c"],
                     vec = [Float32[1,0,0], Float32[0,1,0], Float32[0,0,1]]))
        add(tbl1, (id = Int32[4], label = ["d"], vec = [Float32[1,1,0]]))
        @test count_rows(tbl1) == 4
        close(tbl1); close(conn1)

        # Read back fresh
        conn2 = Connection(db)
        @test "items" in table_names(conn2)
        tbl2 = open_table(conn2, "items")
        @test count_rows(tbl2) == 4
        cols = Tables.columns(query(tbl2) |> execute)
        @test sort(collect(cols[:id])) == Int32[1,2,3,4]
        @test sort(collect(cols[:label])) == ["a","b","c","d"]
        close(tbl2); close(conn2)
    end

    # ── 2. All supported column types round-trip ──────────────────────────────
    @testset "all column types round-trip" begin
        conn = Connection(joinpath(tmp, "types"))
        data = (
            c_i8  = Int8[-1, 0, 1],
            c_u8  = UInt8[0, 128, 255],
            c_i16 = Int16[-1000, 0, 1000],
            c_u16 = UInt16[0, 1000, 5000],
            c_i32 = Int32[-1, 0, 1],
            c_u32 = UInt32[0, 1, 999],
            c_i64 = Int64[-1, 0, 1],
            c_u64 = UInt64[0, 1, 999],
            c_f32 = Float32[-1.5, 0.0, 1.5],
            c_f64 = Float64[-1.5, 0.0, 1.5],
            c_str = ["hello", "world", "foo"],
            c_vec = [Float32[1,0], Float32[0,1], Float32[1,1]],
        )
        tbl  = create_table(conn, "t", data)
        cols = Tables.columns(query(tbl) |> execute)

        @test eltype(cols[:c_i8])  == Int8
        @test eltype(cols[:c_u8])  == UInt8
        @test eltype(cols[:c_i16]) == Int16
        @test eltype(cols[:c_u16]) == UInt16
        @test eltype(cols[:c_i32]) == Int32
        @test eltype(cols[:c_u32]) == UInt32
        @test eltype(cols[:c_i64]) == Int64
        @test eltype(cols[:c_u64]) == UInt64
        @test eltype(cols[:c_f32]) == Float32
        @test eltype(cols[:c_f64]) == Float64
        @test eltype(cols[:c_str]) == String
        @test eltype(cols[:c_vec]) == Vector{Float32}

        for (k, v) in pairs(data)
            @test sort(collect(cols[k])) == sort(collect(v))
        end

        close(tbl); close(conn)
    end

    # ── 3. delete_rows removes matching rows and bumps version ────────────────
    @testset "delete_rows" begin
        conn = Connection(joinpath(tmp, "delete"))
        tbl  = create_table(conn, "t",
                    (id = Int32.(1:6), tag = ["even","odd","even","odd","even","odd"]))

        v0 = table_version(tbl)
        delete_rows(tbl, "tag = 'odd'")
        @test count_rows(tbl) == 3
        @test table_version(tbl) > v0

        cols = Tables.columns(query(tbl) |> execute)
        @test all(t -> t == "even", cols[:tag])

        # Delete all remaining rows
        delete_rows(tbl, "id > 0")
        @test count_rows(tbl) == 0

        close(tbl); close(conn)
    end

    # ── 4. merge_insert upserts correctly ─────────────────────────────────────
    @testset "merge_insert upsert" begin
        conn = Connection(joinpath(tmp, "upsert"))
        tbl  = create_table(conn, "t", (id=Int32[1,2,3], score=Float32[1.0,2.0,3.0]))

        # Update id=2, insert id=4; id=1 and id=3 stay unchanged
        merge_insert(tbl, (id=Int32[2,4], score=Float32[99.0,4.0]), "id")
        @test count_rows(tbl) == 4

        cols = Tables.columns(query(tbl) |> execute)
        by_id = Dict(zip(collect(cols[:id]), collect(cols[:score])))
        @test by_id[Int32(1)] ≈ 1.0f0
        @test by_id[Int32(2)] ≈ 99.0f0
        @test by_id[Int32(3)] ≈ 3.0f0
        @test by_id[Int32(4)] ≈ 4.0f0

        close(tbl); close(conn)
    end

    # ── 5. merge_insert with multi-column key ─────────────────────────────────
    @testset "merge_insert multi-column key" begin
        conn = Connection(joinpath(tmp, "upsert2"))
        tbl  = create_table(conn, "t",
                    (a=Int32[1,1,2], b=Int32[10,20,10], val=Float32[1,2,3]))

        # Update (a=1,b=20), insert (a=2,b=20)
        merge_insert(tbl,
                     (a=Int32[1,2], b=Int32[20,20], val=Float32[99,4]),
                     ["a","b"])
        @test count_rows(tbl) == 4

        cols = Tables.columns(query(tbl) |> execute)
        pairs_map = Dict(zip(zip(collect(cols[:a]), collect(cols[:b])), collect(cols[:val])))
        @test pairs_map[(Int32(1), Int32(20))] ≈ 99.0f0

        close(tbl); close(conn)
    end

    # ── 6. table_version increments on every write ───────────────────────────
    @testset "table_version increments on writes" begin
        conn = Connection(joinpath(tmp, "versions"))
        tbl  = create_table(conn, "t", (x=Int32[1],))
        v0 = table_version(tbl)

        add(tbl, (x=Int32[2],));      v1 = table_version(tbl)
        add(tbl, (x=Int32[3],));      v2 = table_version(tbl)
        delete_rows(tbl, "x = 1");    v3 = table_version(tbl)
        merge_insert(tbl, (x=Int32[2],), "x"); v4 = table_version(tbl)

        @test v1 > v0
        @test v2 > v1
        @test v3 > v2
        @test v4 > v3

        close(tbl); close(conn)
    end

    # ── 7. Multiple tables coexist in same database ───────────────────────────
    @testset "multiple tables in same database" begin
        conn = Connection(joinpath(tmp, "multi"))
        t1 = create_table(conn, "alpha",   (id=Int32[1,2],))
        t2 = create_table(conn, "beta",    (id=Int32[10,20,30],))
        t3 = create_table(conn, "gamma",   (id=Int32[100],))

        names = table_names(conn)
        @test "alpha" in names
        @test "beta"  in names
        @test "gamma" in names

        @test count_rows(t1) == 2
        @test count_rows(t2) == 3
        @test count_rows(t3) == 1

        drop_table(conn, "beta")
        names2 = table_names(conn)
        @test !("beta" in names2)
        @test "alpha" in names2
        @test "gamma" in names2

        close(t1); close(t2); close(t3); close(conn)
    end

    # ── 8. select_cols limits returned columns ────────────────────────────────
    @testset "select_cols on full-table query" begin
        conn = Connection(joinpath(tmp, "select"))
        tbl  = create_table(conn, "t", (a=Int32[1,2], b=Float32[3,4], c=["x","y"]))

        cols = Tables.columns(query(tbl) |> select_cols(["a","c"]) |> execute)
        @test  haskey(cols, :a)
        @test  haskey(cols, :c)
        @test !haskey(cols, :b)

        close(tbl); close(conn)
    end

    # ── 9. offset + limit on full-table query ─────────────────────────────────
    @testset "offset and limit" begin
        conn = Connection(joinpath(tmp, "paginate"))
        tbl  = create_table(conn, "t", (id=Int32.(1:10),))

        page1 = sort(collect(Tables.columns(query(tbl) |> offset(0) |> limit(4) |> execute)[:id]))
        page2 = sort(collect(Tables.columns(query(tbl) |> offset(4) |> limit(4) |> execute)[:id]))
        page3 = sort(collect(Tables.columns(query(tbl) |> offset(8) |> limit(4) |> execute)[:id]))

        @test length(page1) == 4
        @test length(page2) == 4
        @test length(page3) == 2
        @test isempty(intersect(page1, page2))
        @test isempty(intersect(page2, page3))

        close(tbl); close(conn)
    end

    # ── 10. Vector search sees newly added rows ───────────────────────────────
    @testset "vector search after incremental adds" begin
        conn = Connection(joinpath(tmp, "vs-add"))
        schema = make_vector_schema("id", "vec", 3)
        tbl    = create_table(conn, "t", schema)
        release_arrow_schema(schema)

        add(tbl, (id=["a","b"], vec=[Float32[1,0,0], Float32[0,1,0]]))

        # Nearest to [0,0,1] is not yet in table — b is nearest so far
        cols1 = Tables.columns(vector_search(tbl, Float32[0,0,1], "vec") |> limit(1) |> execute)
        first_before = cols1[:id][1]

        # Now add the perfect match
        add(tbl, (id=["c"], vec=[Float32[0,0,1]]))
        cols2 = Tables.columns(vector_search(tbl, Float32[0,0,1], "vec") |> limit(1) |> execute)
        @test cols2[:id][1] == "c"
        @test cols2[:_distance][1] ≈ 0.0f0

        close(tbl); close(conn)
    end

    # ── 11. Full workflow: create, populate, index, search, delete, verify ────
    @testset "full workflow" begin
        conn = Connection(joinpath(tmp, "workflow"))
        n    = 50
        ids  = string.(1:n)
        vecs = [_normalize(Float32.(rand(4))) for _ in 1:n]
        data = (id=ids, vec=vecs, score=Float32.(rand(n)))
        tbl  = create_table(conn, "docs", data)

        @test count_rows(tbl) == n

        # Scalar index on score
        create_scalar_index(tbl, "score")
        @test "score_idx" in list_indices(tbl)

        # Filter + count
        cols = Tables.columns(
            query(tbl) |> filter_where("score > 0.5") |> execute
        )
        high_score_count = length(cols[:id])
        @test high_score_count >= 0   # just verify it doesn't error

        # Vector search returns results
        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |> limit(5) |> execute
        vcols = Tables.columns(qr)
        @test length(vcols[:id]) == 5
        @test issorted(vcols[:_distance])

        # Delete high-score rows
        delete_rows(tbl, "score > 0.5")
        @test count_rows(tbl) == n - high_score_count

        # Merge-insert remaining rows with doubled scores
        remaining = Tables.columns(query(tbl) |> execute)
        new_scores = min.(collect(remaining[:score]) .* 2, 1.0f0)
        merge_insert(tbl, (id=collect(remaining[:id]), vec=collect(remaining[:vec]),
                           score=new_scores), "id")
        @test count_rows(tbl) == n - high_score_count

        close(tbl); close(conn)
    end
end
