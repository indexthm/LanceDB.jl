@testset "Index management" begin
    tmp = only(ARGS)

    # ── Scalar index (BTree) ──────────────────────────────────────────────────
    @testset "create and drop scalar index" begin
        conn = Connection(joinpath(tmp, "idx-scalar"))
        tbl  = create_table(conn, "t", (id = Int32.(1:20), label = ["x$i" for i in 1:20]))

        @test isempty(list_indices(tbl))

        create_scalar_index(tbl, "id")
        idxs = list_indices(tbl)
        @test "id_idx" in idxs

        stats = index_stats(tbl, "id_idx")
        @test stats.num_indexed_rows == 20
        @test stats.num_unindexed_rows == 0

        drop_index(tbl, "id_idx")
        @test !("id_idx" in list_indices(tbl))

        close(tbl); close(conn)
    end

    # ── Multiple scalar indices ───────────────────────────────────────────────
    @testset "multiple scalar indices" begin
        conn = Connection(joinpath(tmp, "idx-multi-scalar"))
        tbl  = create_table(conn, "t", (a = Int32.(1:10), b = Float32.(1:10)))

        create_scalar_index(tbl, "a")
        create_scalar_index(tbl, "b")
        idxs = list_indices(tbl)
        @test "a_idx" in idxs
        @test "b_idx" in idxs
        @test length(idxs) == 2

        close(tbl); close(conn)
    end

    # ── FTS index ─────────────────────────────────────────────────────────────
    @testset "create and drop FTS index" begin
        conn = Connection(joinpath(tmp, "idx-fts"))
        labels = ["apple banana", "cherry date", "elderberry fig",
                  "grape honeydew", "kiwi lemon"]
        tbl = create_table(conn, "t", (id = Int32.(1:5), text = labels))

        create_fts_index(tbl, "text")
        @test "text_idx" in list_indices(tbl)

        stats = index_stats(tbl, "text_idx")
        @test stats.num_indexed_rows == 5

        drop_index(tbl, "text_idx")
        @test isempty(list_indices(tbl))

        close(tbl); close(conn)
    end

    # ── FTS config options ────────────────────────────────────────────────────
    @testset "FTS index with config" begin
        conn = Connection(joinpath(tmp, "idx-fts-cfg"))
        tbl  = create_table(conn, "t", (doc = ["hello world", "foo bar"],))

        cfg = LanceDBFtsIndexConfig()
        cfg.lowercase = 1
        cfg.stem      = 0
        create_fts_index(tbl, :doc; config=cfg, stem=true, remove_stop_words=true,
                         ascii_folding=true, max_token_length=40, language="English")
        @test cfg.stem == 0
        @test cfg.max_token_length == -1
        @test "doc_idx" in list_indices(tbl)
        @test_throws LanceDBException create_fts_index(tbl, :doc; replace=false)
        create_fts_index(tbl, :doc; replace=true, max_token_length=-1)
        @test index_stats(tbl, "doc_idx").num_indexed_rows == 2
        @test_throws ArgumentError create_fts_index(tbl, String[])
        @test_throws ArgumentError create_fts_index(tbl, ["doc", "doc"])
        @test_throws ArgumentError create_fts_index(tbl, :doc; max_token_length=-2)
        @test_throws ArgumentError create_fts_index(tbl, :doc; max_token_length=big(typemax(Cint))+1)
        @test_throws ArgumentError create_fts_index(tbl, :doc; language="bad\0language")

        close(tbl); close(conn)
    end

    # ── index_stats for non-existent index throws ────────────────────────────
    @testset "index_stats throws for unknown index" begin
        conn = Connection(joinpath(tmp, "idx-notfound"))
        tbl  = create_table(conn, "t", (x = Int32[1, 2],))

        @test_throws LanceDBException index_stats(tbl, "ghost_idx")

        close(tbl); close(conn)
    end

    # ── Vector index (IVFFlat) — needs ≥ 256 rows for training ───────────────
    @testset "create vector index (IVFFlat)" begin
        conn = Connection(joinpath(tmp, "idx-vec"))
        n    = 300
        data = (id  = string.(1:n),
                vec = [Float32.(rand(4)) for _ in 1:n])
        tbl  = create_table(conn, "t", data)

        cfg = LanceDBVectorIndexConfig()
        cfg.num_partitions = 1
        create_vector_index(tbl, "vec"; type=IVFFlat, config=cfg)

        idxs = list_indices(tbl)
        @test "vec_idx" in idxs

        stats = index_stats(tbl, "vec_idx")
        @test stats.num_indexed_rows  == n
        @test stats.num_unindexed_rows == 0
        @test stats.num_indices >= 1

        close(tbl); close(conn)
    end

    # ── Add rows after index → unindexed count grows ─────────────────────────
    @testset "unindexed rows after add" begin
        conn = Connection(joinpath(tmp, "idx-unindexed"))
        n    = 300
        data = (id  = string.(1:n),
                vec = [Float32.(rand(4)) for _ in 1:n])
        tbl  = create_table(conn, "t", data)

        cfg = LanceDBVectorIndexConfig(); cfg.num_partitions = 1
        create_vector_index(tbl, "vec"; type=IVFFlat, config=cfg)

        add(tbl, (id=["x", "y"], vec=[Float32.(rand(4)), Float32.(rand(4))]))

        stats = index_stats(tbl, "vec_idx")
        @test stats.num_unindexed_rows == 2
        @test stats.num_indexed_rows   == n

        close(tbl); close(conn)
    end

    # ── optimize(OptimizeIndex) re-indexes new rows ───────────────────────────
    @testset "optimize_index re-indexes" begin
        conn = Connection(joinpath(tmp, "idx-reindex"))
        n    = 300
        data = (id  = string.(1:n),
                vec = [Float32.(rand(4)) for _ in 1:n])
        tbl  = create_table(conn, "t", data)

        cfg = LanceDBVectorIndexConfig(); cfg.num_partitions = 1
        create_vector_index(tbl, "vec"; type=IVFFlat, config=cfg)

        add(tbl, (id=["p", "q"], vec=[Float32.(rand(4)), Float32.(rand(4))]))
        optimize(tbl; type=OptimizeIndex)

        stats = index_stats(tbl, "vec_idx")
        @test stats.num_unindexed_rows == 0
        @test stats.num_indexed_rows   == n + 2

        close(tbl); close(conn)
    end

    # ── Vector search quality after indexing ─────────────────────────────────
    @testset "vector search still correct after index" begin
        conn = Connection(joinpath(tmp, "idx-search"))
        # Pad unit vectors to dim=4 with noise rows so we hit 300
        basis = [Float32[1,0,0,0], Float32[0,1,0,0],
                 Float32[0,0,1,0], Float32[0,0,0,1]]
        n_noise = 296
        noise_ids  = ["n$i" for i in 1:n_noise]
        noise_vecs = [Float32.(rand(4)) for _ in 1:n_noise]
        ids  = vcat(["a","b","c","d"], noise_ids)
        vecs = vcat(basis, noise_vecs)
        tbl  = create_table(conn, "t", (id=ids, vec=vecs))

        cfg = LanceDBVectorIndexConfig(); cfg.num_partitions = 4
        create_vector_index(tbl, "vec"; type=IVFFlat, config=cfg)

        # With nprobes covering all partitions, exact match should be first
        qr   = vector_search(tbl, Float32[1,0,0,0], "vec") |>
               nprobes(4) |>
               limit(1) |>
               execute
        cols = Tables.columns(qr)
        @test cols[:id][1] == "a"
        @test cols[:_distance][1] ≈ 0.0f0 atol=1f-5

        close(tbl); close(conn)
    end

    # ── optimize variants don't error ─────────────────────────────────────────
    @testset "optimize variants" begin
        conn = Connection(joinpath(tmp, "idx-opt"))
        tbl  = create_table(conn, "t", (x = Int32.(1:5),))

        @test (optimize(tbl);                          true)
        @test (optimize(tbl; type=OptimizeCompact);    true)
        @test (optimize(tbl; type=OptimizePrune);      true)
        @test (optimize(tbl; type=OptimizeIndex);      true)

        close(tbl); close(conn)
    end
end
