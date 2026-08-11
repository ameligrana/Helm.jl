using Documenter
using Helm

DocMeta.setdocmeta!(
    Helm,
    :DocTestSetup,
    :(begin
        using Helm
        import Ark
    end);
    recursive=true,
)

makedocs(
    modules=[Helm],
    authors="Franz Scharnreitner and contributors",
    sitename="Helm.jl",
    repo="https://github.com/theplatters/Helm.jl/blob/{commit}{path}#{line}",
    format=Documenter.HTML(
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://theplatters.github.io/Helm.jl",
        edit_link="main",
        repolink="https://github.com/theplatters/Helm.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Systems and data access" => "systems.md",
        "Building schedules" => "schedules.md",
        "Executing schedules" => "execution.md",
        "API reference" => "api.md",
    ],
    checkdocs=:exports,
    doctest=true,
    warnonly=false,
)

deploydocs(repo="github.com/theplatters/Helm.jl.git")
