# Unit tests for null-bitmap reading in _read_column.
#
# Arrow validity bitmap encoding:
#   bit i (0-indexed) == 1 → slot i is valid
#   bit i (0-indexed) == 0 → slot i is null
#   null_count == 0        → fast path: skip bitmap check, return non-nullable Vector{T}
#
# We construct mock ArrowArray structs on the Julia heap and call LanceDB._read_column
# directly, so no C library is required.

@testset "null bitmap reading in _read_column" begin

    # ── 1. Primitive numeric column ─────────────────────────────────────────────

    @testset "Int32 column: slot 2 (1-indexed) is null" begin
        #   bits: 3=1 2=1 1=0 0=1  →  0b00001101 = 0x0D
        data     = Int32[10, 0, 30, 40]   # 0 is the placeholder written for the null slot
        validity = UInt8[0x0D]
        bufs     = Ptr{Cvoid}[Ptr{Cvoid}(pointer(validity)), Ptr{Cvoid}(pointer(data))]

        local result
        GC.@preserve data validity bufs begin
            arr    = LanceDB.ArrowArray(Int64(4), Int64(1), Int64(0), Int64(2), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "i")
        end

        @test result isa Vector{Union{Int32, Missing}}
        @test result[1] === Int32(10)
        @test ismissing(result[2])
        @test result[3] === Int32(30)
        @test result[4] === Int32(40)
    end

    @testset "Float64 column: slots 1 and 3 (1-indexed) are null" begin
        #   bits: 3=1 2=0 1=1 0=0  →  0b00001010 = 0x0A
        data     = Float64[0.0, 2.0, 0.0, 4.0]
        validity = UInt8[0x0A]
        bufs     = Ptr{Cvoid}[Ptr{Cvoid}(pointer(validity)), Ptr{Cvoid}(pointer(data))]

        local result
        GC.@preserve data validity bufs begin
            arr    = LanceDB.ArrowArray(Int64(4), Int64(2), Int64(0), Int64(2), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "g")
        end

        @test result isa Vector{Union{Float64, Missing}}
        @test ismissing(result[1])
        @test result[2] === 2.0
        @test ismissing(result[3])
        @test result[4] === 4.0
    end

    # ── 2. UTF-8 string column ───────────────────────────────────────────────────

    @testset "String column: slot 3 (1-indexed) is null" begin
        # strings: ["hello", "world", missing]
        # For null slots the convention is start == end offset (zero-length slice).
        offsets  = Int32[0, 5, 10, 10]
        data_bytes = Vector{UInt8}(codeunits("helloworld"))
        validity = UInt8[0x03]           # 0b00000011: bits 0,1 valid; bit 2 null
        bufs     = Ptr{Cvoid}[
            Ptr{Cvoid}(pointer(validity)),
            Ptr{Cvoid}(pointer(offsets)),
            Ptr{Cvoid}(pointer(data_bytes)),
        ]

        local result
        GC.@preserve offsets data_bytes validity bufs begin
            arr    = LanceDB.ArrowArray(Int64(3), Int64(1), Int64(0), Int64(3), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "u")
        end

        @test result isa Vector{Union{String, Missing}}
        @test result[1] == "hello"
        @test result[2] == "world"
        @test ismissing(result[3])
    end

    # ── 3. Fast paths: no nulls ──────────────────────────────────────────────────

    @testset "null_count == 0: returns plain Vector{T}, no Missing" begin
        data = Int32[1, 2, 3]
        bufs = Ptr{Cvoid}[C_NULL, Ptr{Cvoid}(pointer(data))]

        local result
        GC.@preserve data bufs begin
            arr    = LanceDB.ArrowArray(Int64(3), Int64(0), Int64(0), Int64(2), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "i")
        end

        @test result isa Vector{Int32}        # not Union{Int32, Missing}
        @test result == Int32[1, 2, 3]
    end

    @testset "null_count == 0 with non-NULL bitmap: fast path skips bitmap" begin
        # null_count == 0 must win over a non-NULL validity pointer
        data     = Int32[1, 2, 3]
        validity = UInt8[0xFF]           # all valid, but should not even be read
        bufs     = Ptr{Cvoid}[Ptr{Cvoid}(pointer(validity)), Ptr{Cvoid}(pointer(data))]

        local result
        GC.@preserve data validity bufs begin
            arr    = LanceDB.ArrowArray(Int64(3), Int64(0), Int64(0), Int64(2), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "i")
        end

        @test result isa Vector{Int32}        # null_count=0 → non-nullable fast path
        @test result == Int32[1, 2, 3]
    end

    # ── 4. null_count == -1 (unknown) uses bitmap ────────────────────────────────

    @testset "null_count == -1 (unknown): falls back to bitmap" begin
        #   bits: 2=1 1=0 0=1  →  0b00000101 = 0x05
        data     = Int32[10, 0, 30]
        validity = UInt8[0x05]
        bufs     = Ptr{Cvoid}[Ptr{Cvoid}(pointer(validity)), Ptr{Cvoid}(pointer(data))]

        local result
        GC.@preserve data validity bufs begin
            arr    = LanceDB.ArrowArray(Int64(3), Int64(-1), Int64(0), Int64(2), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "i")
        end

        @test result isa Vector{Union{Int32, Missing}}
        @test result[1] === Int32(10)
        @test ismissing(result[2])
        @test result[3] === Int32(30)
    end

    # ── 5. Bitmap spanning two bytes (> 8 elements) ──────────────────────────────

    @testset "validity bitmap spans two bytes (9 elements, slot 9 null)" begin
        #  byte 0: 0xFF (all 8 valid), byte 1: 0x00 (slot 8 in 0-indexed = slot 9 null)
        data     = Int32[1, 2, 3, 4, 5, 6, 7, 8, 0]
        validity = UInt8[0xFF, 0x00]
        bufs     = Ptr{Cvoid}[Ptr{Cvoid}(pointer(validity)), Ptr{Cvoid}(pointer(data))]

        local result
        GC.@preserve data validity bufs begin
            arr    = LanceDB.ArrowArray(Int64(9), Int64(1), Int64(0), Int64(2), Int64(0),
                         Ptr{Cvoid}(pointer(bufs)), C_NULL, C_NULL, C_NULL, C_NULL)
            result = LanceDB._read_column(arr, "i")
        end

        @test result isa Vector{Union{Int32, Missing}}
        @test all(!ismissing, result[1:8])
        @test result[1:8] == Int32[1, 2, 3, 4, 5, 6, 7, 8]
        @test ismissing(result[9])
    end

end
