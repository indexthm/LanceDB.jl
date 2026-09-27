# julia --project=. benchmark/run.jl
# Use --arrow from an environment containing Arrow to measure Arrow.Table input.
load_seconds = @elapsed using LanceDB
const Tables = LanceDB.Tables

function measure(operation, name; samples=31)
    operation(); operation()
    timings, allocations = Float64[], Int[]
    for _ in 1:samples
        GC.gc()
        measurement = @timed operation()
        push!(timings,measurement.time)
        push!(allocations,measurement.bytes)
    end
    println(name," median_ms=",round(sort(timings)[cld(samples,2)]*1000;digits=4),
            " julia_bytes=",sort(allocations)[cld(samples,2)])
end

function convert_input(data)
    array,schema,pins = LanceDB._to_arrow_c_abi(data)
    GC.@preserve pins begin
        LanceDB._free_array_tree(array)
        release_arrow_schema(schema)
    end
end

println("Julia ",VERSION,"; package_load_seconds=",round(load_seconds;digits=4))
numeric = (id=collect(Int64,1:20000),value=fill(1.5,20000))
text = (id=numeric.id,text=fill("LanceDB",20000))
vectors = (id=numeric.id,embedding=[Float32[1,0,0,1] for _ in 1:20000])
measure(()->convert_input(numeric),"numeric export")
measure(()->convert_input(text),"text export")
measure(()->convert_input(vectors),"vector export")
if "--arrow" in ARGS
    @eval using Arrow
    buffer=IOBuffer()
    Arrow.write(buffer,numeric)
    arrow=Arrow.Table(take!(buffer))
    measure(()->convert_input(arrow),"Arrow numeric export")
end
mktempdir() do path
    open(Connection,path) do db
        table=create_table(db,"numeric",numeric)
        try
            measure("native scan and import") do
                result=execute(query(table))
                try
                    cols=Tables.columns(result)
                    @assert cols.id == numeric.id
                finally
                    close(result)
                end
            end
        finally
            close(table)
        end
    end
end
