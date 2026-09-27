import Base.Libc

# Arrow C Data Interface support.
#
# Defines the concrete memory layout of FFI_ArrowSchema and FFI_ArrowArray so
# that Julia code can construct schemas/batches to pass to lancedb-c, and
# read result batches returned by lancedb-c.
#
# These structs match the Arrow C Data Interface specification exactly.

# ── Struct layouts ────────────────────────────────────────────────────────────

"""
    ArrowSchema

Julia mirror of the Arrow C Data Interface `FFI_ArrowSchema` struct. You
rarely need to construct one directly — use `make_schema` or
`make_vector_schema` instead, and free with `release_arrow_schema`.

Exported so that users can pass an `Ptr{ArrowSchema}` to the low-level
`create_table(conn, name, schema::Ptr{ArrowSchema})` overload when they
need full control over the schema.
"""
struct ArrowSchema
    format::Ptr{UInt8}        # const char* — Arrow format string
    name::Ptr{UInt8}          # const char* — field name (may be NULL)
    metadata::Ptr{UInt8}      # const char* — key-value metadata (may be NULL)
    flags::Int64              # field flags (e.g. nullable)
    n_children::Int64         # number of child schemas
    children::Ptr{Cvoid}      # ArrowSchema** children
    dictionary::Ptr{Cvoid}    # ArrowSchema* dictionary (for dict-encoded)
    release::Ptr{Cvoid}       # release callback (NULL for Julia-owned schemas)
    private_data::Ptr{Cvoid}
end

struct ArrowArray
    length::Int64
    null_count::Int64
    offset::Int64
    n_buffers::Int64
    n_children::Int64
    buffers::Ptr{Cvoid}       # const void**
    children::Ptr{Cvoid}      # ArrowArray** children
    dictionary::Ptr{Cvoid}    # ArrowArray* dictionary
    release::Ptr{Cvoid}       # release callback
    private_data::Ptr{Cvoid}
end

# ── Memory helpers ────────────────────────────────────────────────────────────

function _checked_malloc(n::Integer)
    ptr = Libc.malloc(n)
    ptr == C_NULL && n != 0 && throw(OutOfMemoryError())
    ptr
end

function _malloc_cstr(s::AbstractString)::Ptr{UInt8}
    n   = ncodeunits(s)
    ptr = Ptr{UInt8}(_checked_malloc(n + 1))
    GC.@preserve s unsafe_copyto!(ptr, pointer(codeunits(s)), n)
    unsafe_store!(ptr, 0x00, n + 1)
    ptr
end

# ── Schema construction ───────────────────────────────────────────────────────
# All Julia-constructed schemas use C_NULL for the release field.
# lancedb_table_create uses Schema::try_from(&*schema) — a reference — so it
# does NOT call release. We free memory ourselves in release_arrow_schema.

function _alloc_leaf_schema(format::String, name::String)::Ptr{ArrowSchema}
    _check_string(format); _check_string(name)
    fmt = _malloc_cstr(format)
    nm = Ptr{UInt8}(C_NULL)
    try
        nm = _malloc_cstr(name)
        ptr = Ptr{ArrowSchema}(_checked_malloc(sizeof(ArrowSchema)))
        unsafe_store!(ptr, ArrowSchema(fmt, nm, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL))
        return ptr
    catch
        Libc.free(fmt)
        nm == C_NULL || Libc.free(nm)
        rethrow()
    end
end

"""
    make_schema(fields) -> Ptr{ArrowSchema}

Allocate a root Arrow C ABI schema (struct type) from a list of
`(name, format_string)` pairs. Caller is responsible for releasing it
via `release_arrow_schema`.

# Common format strings
- `"u"`      — UTF-8 string
- `"l"`      — Int64
- `"i"`      — Int32
- `"f"`      — Float32
- `"g"`      — Float64
- `"+w:N"`   — FixedSizeList of N elements (add a child for the element type)
- `"+s"`     — Struct (set children manually)
"""
function make_schema(fields::Vector{Pair{String,String}})::Ptr{ArrowSchema}
    foreach(p -> (_check_string(first(p)); _check_string(last(p))), fields)
    children = Ptr{ArrowSchema}[]
    sizehint!(children,length(fields))
    try
        for (fname,fmt) in fields
            push!(children,_alloc_leaf_schema(fmt,fname))
        end
    catch
        foreach(release_arrow_schema,children)
        rethrow()
    end
    _schema_with_children("+s","",children)
end

# Takes ownership of all child schemas, including if construction fails.
function _schema_with_children(format, name, children)
    root = Ptr{ArrowSchema}(C_NULL)
    ptrs = Ptr{Ptr{ArrowSchema}}(C_NULL)
    try
        root = _alloc_leaf_schema(format,name)
        if !isempty(children)
            ptrs = Ptr{Ptr{ArrowSchema}}(_checked_malloc(length(children)*sizeof(Ptr{Cvoid})))
            for (i,child) in enumerate(children)
                unsafe_store!(ptrs,child,i)
            end
        end
        s = unsafe_load(root)
        unsafe_store!(root,ArrowSchema(s.format,s.name,C_NULL,0,length(children),
                                      ptrs,C_NULL,C_NULL,C_NULL))
        return root
    catch
        root == C_NULL || release_arrow_schema(root)
        ptrs == C_NULL || Libc.free(ptrs)
        foreach(release_arrow_schema,children)
        rethrow()
    end
end

"""
    make_vector_schema(key_field, vec_field, dim) -> Ptr{ArrowSchema}

Convenience builder for the canonical LanceDB test schema:
`{key_field: utf8, vec_field: FixedSizeList<Float32>[dim]}`.
"""
function make_vector_schema(key_field::String, vec_field::String, dim::Int)::Ptr{ArrowSchema}
    dim > 0 || throw(ArgumentError("vector dimension must be positive"))
    _check_string(key_field); _check_string(vec_field)
    children = Ptr{ArrowSchema}[]
    sizehint!(children,2)
    try
        push!(children,_alloc_leaf_schema("u",key_field))
        elements = Ptr{ArrowSchema}[]
        sizehint!(elements,1)
        push!(elements,_alloc_leaf_schema("f","item"))
        push!(children,_schema_with_children("+w:$dim",vec_field,elements))
    catch
        foreach(release_arrow_schema,children)
        rethrow()
    end
    _schema_with_children("+s","",children)
end

# ── Memory release ────────────────────────────────────────────────────────────

function _free_schema_recursive(ptr::Ptr{ArrowSchema})
    s = unsafe_load(ptr)
    s.format   != C_NULL && Libc.free(s.format)
    s.name     != C_NULL && Libc.free(s.name)
    s.metadata != C_NULL && Libc.free(s.metadata)
    if s.n_children > 0 && s.children != C_NULL
        children_ptr = Ptr{Ptr{ArrowSchema}}(s.children)
        for i in 1:s.n_children
            child = unsafe_load(children_ptr, i)
            if child != C_NULL
                _free_schema_recursive(child)
                Libc.free(child)
            end
        end
        Libc.free(s.children)
    end
end

"""
    release_arrow_schema(schema)

Free all memory allocated by `make_schema` / `make_vector_schema`.
Must be called exactly once after the schema is no longer needed.
"""
function release_arrow_schema(schema::Ptr{ArrowSchema})
    schema == C_NULL && return
    _free_schema_recursive(schema)
    Libc.free(schema)
end
