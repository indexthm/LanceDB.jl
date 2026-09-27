"""
    LanceDBException(code, message)

Thrown whenever a LanceDB C API call returns an error. `code` is the raw
`LanceDBError` integer; `message` is the human-readable string returned by
the C library (or a fallback when none is provided).
"""
struct LanceDBException <: Exception
    code::Int32
    message::String
end

Base.showerror(io::IO, e::LanceDBException) =
    print(io, "LanceDBException($(e.code)): $(e.message)")

# Called after every C function that returns LanceDBError + optional char** errmsg.
function check(code::Cint, errmsg_ref::Ref{Ptr{UInt8}})
    code == Int32(LANCEDB_SUCCESS) && return
    ptr = errmsg_ref[]
    msg = try
        ptr != C_NULL ? unsafe_string(ptr) : "error code $code"
    finally
        ptr != C_NULL && lancedb_free_string(ptr)
        errmsg_ref[] = C_NULL
    end
    throw(LanceDBException(code, msg))
end

# Called for C functions that signal failure by returning a NULL pointer.
function check_ptr(ptr::Ptr, context::AbstractString)
    ptr == C_NULL && throw(LanceDBException(Int32(LANCEDB_RUNTIME), context))
    ptr
end
