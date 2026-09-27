using LanceDB
using Documenter

DocMeta.setdocmeta!(LanceDB, :DocTestSetup, :(using LanceDB, DataFrames); recursive=true)
makedocs(;
    root=@__DIR__,
    sitename="LanceDB.jl",
    authors="LanceDB.jl contributors",
    modules=[LanceDB],
    pagesonly=true,
    checkdocs=:exports,
    doctest=true,
    format=Documenter.HTML(;
        prettyurls=true,
        canonical="https://indexthm.github.io/LanceDB.jl/dev/",
        repolink="https://github.com/indexthm/LanceDB.jl",
        edit_link="main",
        collapselevel=2,
    ),
    pages=[
        "Home" => "index.md",
        "User guide" => "guide.md",
        "Multimodal data" => "multimodal.md",
        "Capabilities and ownership" => "capabilities.md",
        "API reference" => "api.md",
    ],
)

if get(ENV, "GITHUB_ACTIONS", "false") == "true"
    deploydocs(;
        repo="github.com/indexthm/LanceDB.jl.git",
        devbranch="main",
    )
end
