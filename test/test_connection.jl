@testset "Connection" begin
    tmp = mktempdir()

    # ── 1. Basic connect / URI ─────────────────────────────────────────────────
    @testset "connect and URI" begin
        db_uri = joinpath(tmp, "test-db")
        conn   = Connection(db_uri)
        @test conn isa Connection
        @test uri(conn) == db_uri
        close(conn)
    end

    # ── 2. Empty database has no tables ───────────────────────────────────────
    @testset "table_names on empty db" begin
        conn = Connection(joinpath(tmp, "empty-db"))
        @test table_names(conn) == String[]
        close(conn)
    end

    # ── 3. do-block closes automatically ──────────────────────────────────────
    @testset "do-block" begin
        captured_uri = ""
        open(Connection, joinpath(tmp, "do-db")) do conn
            captured_uri = uri(conn)
            @test conn isa Connection
        end
        @test !isempty(captured_uri)
    end

    # ── 4. create_table / table_names / open_table / drop_table ──────────────
    @testset "create, list, open, drop table" begin
        conn = Connection(joinpath(tmp, "crud-db"))

        schema = make_vector_schema("key", "data", 8)
        tbl    = create_table(conn, "embeddings", schema)
        release_arrow_schema(schema)

        @test tbl isa Table
        @test tbl.name == "embeddings"
        names = table_names(conn)
        @test "embeddings" in names

        tbl2 = open_table(conn, "embeddings")
        @test tbl2 isa Table
        @test tbl2.name == "embeddings"

        close(tbl)
        close(tbl2)
        drop_table(conn, "embeddings")
        @test isempty(table_names(conn))
        close(conn)
    end

    # ── 5. count_rows on empty table ──────────────────────────────────────────
    @testset "count_rows empty table" begin
        conn   = Connection(joinpath(tmp, "count-db"))
        schema = make_vector_schema("key", "data", 4)
        tbl    = create_table(conn, "t", schema)
        release_arrow_schema(schema)

        @test count_rows(tbl) == 0

        close(tbl)
        close(conn)
    end

    # ── 6. table_version ──────────────────────────────────────────────────────
    @testset "table_version" begin
        conn   = Connection(joinpath(tmp, "ver-db"))
        schema = make_vector_schema("key", "data", 4)
        tbl    = create_table(conn, "t", schema)
        release_arrow_schema(schema)

        v = table_version(tbl)
        @test v isa Int
        @test v >= 1

        close(tbl)
        close(conn)
    end

    # ── 7. open non-existent table throws ────────────────────────────────────
    @testset "open non-existent table" begin
        conn = Connection(joinpath(tmp, "err-db"))
        @test_throws LanceDBException open_table(conn, "no_such_table")
        close(conn)
    end

    # ── 8. LanceDBException is displayable ───────────────────────────────────
    @testset "LanceDBException display" begin
        e = LanceDBException(Int32(4), "table not found")
        @test sprint(showerror, e) == "LanceDBException(4): table not found"
    end

    # ── 9. execute failure: builder consumed on the error path ───────
    # Block the target path by placing a regular file there. LanceDB will attempt
    # to create/open it as a directory and fail, so lancedb_connect_builder_execute
    # returns an error code and the builder is consumed by Rust's Box::from_raw drop.
    #
    # NOTE: the Rust implementation drops the builder in BOTH the Ok and Err
    # branches (Box::from_raw takes ownership unconditionally). The C header says
    # "On success, the builder is consumed", which is understated — it is always
    # consumed. Any "fix" that calls lancedb_connect_builder_free on the failure
    # path would therefore be a double-free. This test verifies that:
    #   a) the failure produces LanceDBException, not a silent return or crash,
    #   b) the process is not corrupted afterwards (a new valid Connection works).
    @testset "execute failure throws LanceDBException, process stays healthy" begin
        # Mirror the technique from lancedb-c/tests/test_connection.cpp:
        # create a regular FILE at the parent path so that any attempt to create
        # a sub-directory inside it fails at the OS level (ENOTDIR).
        blocker = joinpath(tmp, "parent-is-a-file")
        write(blocker, "")                         # regular file, not a directory
        db_path = joinpath(blocker, "lance_db")    # URI: <file>/lance_db — impossible path

        @test_throws LanceDBException Connection(db_path)

        # If the builder were double-freed or memory were corrupted, this next
        # Connection call would likely crash or produce garbage.
        conn = Connection(joinpath(tmp, "post-failure"))
        @test conn isa Connection
        @test isempty(table_names(conn))
        close(conn)
    end
end
