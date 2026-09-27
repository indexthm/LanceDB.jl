module LanceDBSQLiteExt

using LanceDB, SQLite, Tables

function sqlite_columns(db; source_table=nothing, sql=nothing, params=())
    (source_table === nothing) != (sql === nothing) ||
        throw(ArgumentError("specify exactly one of source_table or sql"))
    statement = if source_table !== nothing
        name = String(source_table)
        LanceDB._check_string(name)
        "SELECT * FROM \"" * replace(name, "\"" => "\"\"") * "\""
    else
        String(sql)
    end
    stmt = SQLite.Stmt(db, statement)
    try
        columns = Tables.columntable(SQLite.DBInterface.execute(stmt, params))
        map(columns) do column
            T = Base.nonmissingtype(eltype(column))
            T !== Union{} && T <: AbstractVector{UInt8} ? BinaryColumn(column) : column
        end
    finally
        SQLite.DBInterface.close!(stmt)
    end
end

function LanceDB.import_sqlite(conn::Connection, name::AbstractString, db::SQLite.DB; kwargs...)
    LanceDB._assert_live(conn)
    LanceDB._check_string(name)
    create_table(conn, name, sqlite_columns(db; kwargs...))
end

function LanceDB.import_sqlite(table::Table, db::SQLite.DB; kwargs...)
    LanceDB._assert_live(table)
    add(table, sqlite_columns(db; kwargs...))
    table
end

end
