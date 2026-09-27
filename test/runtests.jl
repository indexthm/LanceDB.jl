using Test
using LanceDB
using Tables

@testset "LanceDB.jl" begin
    include("test_connection.jl")
    include("test_current_abi.jl")
    include("test_resources.jl")
    include("test_isopen_reopen.jl")
    include("test_table.jl")
    include("test_query.jl")
    include("test_vector_search.jl")
    include("test_table_add.jl")
    include("test_sink.jl")
    include("test_null_columns.jl")
    include("test_make_reader_leak.jl")
    include("test_query_execute.jl")
    include("test_rows.jl")
    include("test_vector_search_execute.jl")
    include("test_index.jl")
    include("test_expr_filter.jl")
    include("test_integration.jl")
end
