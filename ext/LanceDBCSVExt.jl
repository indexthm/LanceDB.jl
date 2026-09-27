module LanceDBCSVExt

using LanceDB, CSV

function LanceDB.import_csv(conn::Connection, name::AbstractString,
                            source::Union{AbstractString,IO}; strict::Bool=true, kwargs...)
    LanceDB._assert_live(conn)
    LanceDB._check_string(name)
    create_table(conn, name, CSV.File(source; strict, kwargs...))
end

function LanceDB.import_csv(table::Table, source::Union{AbstractString,IO}; strict::Bool=true, kwargs...)
    LanceDB._assert_live(table)
    add(table, CSV.File(source; strict, kwargs...))
    table
end

end
