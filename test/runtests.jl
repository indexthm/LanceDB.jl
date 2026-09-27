using Test
using LanceDB
using Tables

@testset "LanceDB.jl" begin
    include("test_connection.jl")
    include("test_current_abi.jl")
    include("test_resources.jl")
    include("test_arrow_export.jl")
    include("test_arrow_nested.jl")
    include("test_features.jl")
    include("test_multimodal.jl")
    include("test_embeddings.jl")
    include("test_isopen_reopen.jl")
    include("test_query.jl")
    include("test_table_add.jl")
    include("test_sink.jl")
    include("test_null_columns.jl")
    include("test_query_execute.jl")
    include("test_rows.jl")
    include("test_vector_search_execute.jl")
    # Native index optimization can retain Windows file mappings until exit.
    # Let the worker exit before the parent removes its database directory.
    mktempdir() do path
        file = joinpath(@__DIR__, "test_index.jl")
        script = "using Test, LanceDB, Tables; file=popfirst!(ARGS); include(file);"
        @test success(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $script $file $path`)
    end
    include("test_expr_filter.jl")
    include("test_integration.jl")
    include("test_arrow_extension.jl")
    include("test_dataframes.jl")
    include("test_csv_extension.jl")
    include("test_json_extension.jl")
    include("test_sqlite_extension.jl")
end
