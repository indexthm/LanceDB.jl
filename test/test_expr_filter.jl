@testset "Expression DSL filter" begin
    tmp = mktempdir()

    # Shared table for all expression tests
    conn = Connection(joinpath(tmp, "expr"))
    data = (
        id    = Int32[1, 2, 3, 4, 5],
        score = Float32[0.1, 0.5, 0.9, 0.3, 0.7],
        label = ["cat", "dog", "cat", "bird", "dog"],
    )
    tbl = create_table(conn, "t", data)

    function qids(e)
        cols = Tables.columns(query(tbl) |> filter_expr(e) |> execute)
        isempty(cols) ? Int32[] : sort(collect(cols[:id]))
    end

    # ── Comparison operators ──────────────────────────────────────────────────
    @testset "greater-than filter" begin
        @test qids(col("score") > lit(0.5f0)) == Int32[3, 5]
    end

    @testset "less-than filter" begin
        @test qids(col("score") < lit(0.5f0)) == Int32[1, 4]
    end

    @testset "greater-than-or-equal filter" begin
        @test qids(col("id") >= lit(3)) == Int32[3, 4, 5]
    end

    @testset "less-than-or-equal filter" begin
        @test qids(col("id") <= lit(2)) == Int32[1, 2]
    end

    @testset "equality filter (numeric)" begin
        @test qids(col("id") == lit(3)) == Int32[3]
    end

    @testset "not-equal filter" begin
        @test qids(col("id") != lit(3)) == Int32[1, 2, 4, 5]
    end

    @testset "string equality filter" begin
        @test qids(col("label") == lit("cat")) == Int32[1, 3]
    end

    # ── Boolean combinators ───────────────────────────────────────────────────
    @testset "AND combinator" begin
        e = (col("score") > lit(0.3f0)) & (col("score") < lit(0.9f0))
        @test qids(e) == Int32[2, 5]
    end

    @testset "OR combinator" begin
        e = (col("label") == lit("cat")) | (col("label") == lit("bird"))
        @test qids(e) == Int32[1, 3, 4]
    end

    @testset "NOT unary operator" begin
        @test qids(!(col("label") == lit("cat"))) == Int32[2, 4, 5]
    end

    @testset "compound AND+OR" begin
        # score > 0.4 AND (label == cat OR label == dog)
        e = (col("score") > lit(0.4f0)) & ((col("label") == lit("cat")) | (col("label") == lit("dog")))
        @test qids(e) == Int32[2, 3, 5]
    end

    # ── Arithmetic in filter ──────────────────────────────────────────────────
    @testset "arithmetic expression in filter" begin
        @test qids((col("score") * lit(2.0f0)) > lit(1.0f0)) == Int32[3, 5]
    end

    # ── In-list operators ─────────────────────────────────────────────────────
    @testset "isin string values" begin
        e = isin(col("label"), lit("cat"), lit("bird"))
        @test qids(e) == Int32[1, 3, 4]
    end

    @testset "notiin string values" begin
        e = notiin(col("label"), lit("cat"), lit("bird"))
        @test qids(e) == Int32[2, 5]
    end

    @testset "isin single value" begin
        @test qids(isin(col("id"), lit(2))) == Int32[2]
    end

    @testset "isin requires at least one value" begin
        @test_throws ArgumentError isin(col("id"))
        @test_throws ArgumentError notiin(col("id"))
    end

    # ── Null predicates ───────────────────────────────────────────────────────
    @testset "isnotnull returns all rows for non-null column" begin
        @test length(qids(isnotnull(col("label")))) == 5
    end

    @testset "isnull returns no rows for non-null column" begin
        @test isempty(qids(isnull(col("score"))))
    end

    # ── Expression copy/reuse ─────────────────────────────────────────────────
    @testset "copy allows expression reuse" begin
        original = col("score") > lit(0.4f0)
        cloned   = copy(original)
        @test !original._consumed
        r1 = qids(original)
        r2 = qids(cloned)
        @test r1 == r2 == Int32[2, 3, 5]
    end

    @testset "consumed expr raises on reuse" begin
        e = col("id") == lit(1)
        qids(e)   # consumes e
        @test e._consumed
        @test_throws LanceDBException qids(e)
    end

    # ── filter_expr curried form ──────────────────────────────────────────────
    @testset "filter_expr curried form" begin
        result = query(tbl) |> filter_expr(col("id") == lit(2)) |> execute
        @test Tables.columns(result)[:id] == Int32[2]
    end

    # ── filter_expr on VectorQuery ────────────────────────────────────────────
    @testset "filter_expr on VectorQuery" begin
        conn2 = Connection(joinpath(tmp, "expr-vq"))
        vdata = (
            id    = Int32[1, 2, 3, 4, 5],
            score = Float32[0.1, 0.5, 0.9, 0.3, 0.7],
            vec   = [Float32.(rand(4)) for _ in 1:5],
        )
        tbl2 = create_table(conn2, "t", vdata)

        cols = Tables.columns(
            vector_search(tbl2, Float32[1, 0, 0, 0], "vec") |>
            filter_expr(col("score") > lit(0.4f0)) |>
            limit(5) |>
            execute
        )
        @test all(s -> s > 0.4f0, cols[:score])

        close(tbl2); close(conn2)
    end

    # ── filter_expr + limit ───────────────────────────────────────────────────
    @testset "filter_expr combined with limit" begin
        cols = Tables.columns(
            query(tbl) |> filter_expr(col("score") > lit(0.2f0)) |> limit(2) |> execute
        )
        @test length(cols[:id]) == 2
        @test all(s -> s > 0.2f0, cols[:score])
    end

    close(tbl); close(conn)
end
