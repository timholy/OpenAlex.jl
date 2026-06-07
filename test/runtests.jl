using OpenAlex
using HTTP
using Test

const OA = OpenAlex

@testset "OpenAlex.jl" begin
    @testset "client construction" begin
        c = OpenAlexClient()
        @test c.mailto === nothing
        @test c.user_agent == "OpenAlex.jl"
        @test !occursin("@", c.user_agent)
        @test endswith(c.base_url, "openalex.org") || !endswith(c.base_url, "/")

        c2 = OpenAlexClient(; mailto = "test@example.org", min_interval = 0.0)
        @test c2.mailto == "test@example.org"
        @test occursin("mailto:test@example.org", c2.user_agent)

        # base_url trailing slash is normalised away
        @test OpenAlexClient(; base_url = "https://api.openalex.org/").base_url ==
              "https://api.openalex.org"

        # show does not leak nothing for the anonymous case
        @test occursin("common pool", sprint(show, c))
        @test occursin("polite pool", sprint(show, c2))
    end

    @testset "filter rendering" begin
        # raw string passes through
        @test OA._filterstr("cites:W123,type:!review") == "cites:W123,type:!review"
        # NamedTuple
        @test OA._filterstr((cites = "W123", type = "!review")) == "cites:W123,type:!review"
        # vector value -> OR with '|'
        @test OA._filterstr((type = ["article", "preprint"],)) == "type:article|preprint"
        # Dict with a single pair
        @test OA._filterstr(Dict("publication_year" => 2020)) == "publication_year:2020"
    end

    @testset "select/sort rendering" begin
        @test OA._csv("id,title") == "id,title"
        @test OA._csv(["id", "title", "type"]) == "id,title,type"
        @test OA._csv([:id, :doi]) == "id,doi"
    end

    @testset "id extraction" begin
        @test openalex_id("https://openalex.org/W2741809807") == "W2741809807"
        @test openalex_id("W2741809807") == "W2741809807"
        # works on an object exposing `.id`
        @test openalex_id((id = "https://openalex.org/W42",)) == "W42"
    end

    @testset "work path construction" begin
        @test OA._work_path("W123") == "/works/W123"
        @test OA._work_path("10.1038/nature12373") == "/works/https://doi.org/10.1038/nature12373"
        @test OA._work_path("https://doi.org/10.1038/nature12373") ==
              "/works/https://doi.org/10.1038/nature12373"
        @test OA._work_path("https://openalex.org/W123") == "/works/W123"
    end

    # Live tests hit the public API. They are rate-limited via the client's
    # min_interval and skipped (not failed) when the network is unavailable, so
    # the suite stays green offline and in CI. No email is sent: the client is
    # anonymous unless OPENALEX_MAILTO is set in the environment.
    @testset "live API" begin
        client = OpenAlexClient(; min_interval = 0.2)
        try
            page = works(client; filter = "publication_year:2020", per_page = 5)
            @test haskey(page, :results)
            @test length(page.results) == 5
            @test page.meta.count > 0
            @test all(w -> haskey(w, :id), page.results)

            # A well-known, heavily cited paper (the original AlexNet / a stable DOI).
            w = resolve_work(client, "10.1038/nature14539")  # LeCun, Bengio & Hinton, "Deep learning"
            @test startswith(openalex_id(w), "W")

            # Excluding reviews must yield no fewer-typed contradiction: the
            # non-review count should be <= the total citing count.
            total = works(client; filter = "cites:" * openalex_id(w), per_page = 1)
            nonrev = works(client; filter = "cites:" * openalex_id(w) * ",type:!review",
                           per_page = 1)
            @test nonrev.meta.count <= total.meta.count

            # Cursor paging returns at most max_results.
            some = paginate(client; filter = "cites:" * openalex_id(w),
                            per_page = 50, max_results = 75)
            @test length(some) == 75
        catch err
            if err isa HTTP.Exceptions.ConnectError || err isa HTTP.Exceptions.TimeoutError ||
               err isa Base.IOError
                @warn "Skipping OpenAlex live API tests (network unavailable)" exception = err
            else
                rethrow()
            end
        end
    end
end
