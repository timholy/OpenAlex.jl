"""
    OpenAlex

A small client for the [OpenAlex](https://openalex.org) REST API, focused on
querying the `/works` endpoint and on citation traversal.

Start by constructing a client:

    client = OpenAlexClient()                       # anonymous (common pool)
    client = OpenAlexClient(; mailto="you@x.org")   # polite pool

Then run queries:

    page = works(client; filter = "publication_year:2020", per_page = 25)
    page.results        # the works on this page
    page.meta.count     # total number of matches

    all = paginate(client; filter = "publication_year:2020")   # every match, via cursor

Citation helpers build on the generic query layer:

    w        = resolve_work(client, "10.1038/nature12373")   # by DOI, OpenAlex id, or URL
    citers   = citing_works(client, w)                       # everything citing `w`
    nonrev   = citing_works(client, w; exclude_types = ["review"])
"""
module OpenAlex

using HTTP
using JSON3

export OpenAlexClient
export works, paginate, get_entity
export resolve_work, citing_works, openalex_id

const DEFAULT_BASE_URL = "https://api.openalex.org"
const MAX_PER_PAGE = 200

"""
    OpenAlexClient(; mailto, base_url, min_interval)

Configuration for OpenAlex requests.

# Keyword arguments
- `mailto`: contact email attached to every request (as both the `mailto` query
  parameter and the `User-Agent` header). Supplying it places requests in
  OpenAlex's faster, more reliable "polite pool". Defaults to the
  `OPENALEX_MAILTO` environment variable if set, otherwise `nothing`
  (anonymous, common pool). No email is sent unless you provide one.
- `base_url`: API root, default `$(DEFAULT_BASE_URL)`.
- `min_interval`: minimum number of seconds between successive HTTP requests
  issued through this client, used to stay within OpenAlex's rate limits during
  paging. Default `0.1` (10 requests/second).
"""
struct OpenAlexClient
    base_url::String
    mailto::Union{String,Nothing}
    user_agent::String
    min_interval::Float64
    # `Ref` so a single client can serialise its own request spacing.
    last_request::Base.RefValue{Float64}
end

function OpenAlexClient(; base_url::AbstractString = DEFAULT_BASE_URL,
                          mailto::Union{AbstractString,Nothing} = get(ENV, "OPENALEX_MAILTO", nothing),
                          min_interval::Real = 0.1)
    mailto = mailto === nothing ? nothing : String(mailto)
    ua = mailto === nothing ? "OpenAlex.jl" : "OpenAlex.jl (mailto:$mailto)"
    return OpenAlexClient(rstrip(base_url, '/'), mailto, ua, Float64(min_interval), Ref(0.0))
end

function Base.show(io::IO, c::OpenAlexClient)
    pool = c.mailto === nothing ? "common pool" : "polite pool, mailto=$(c.mailto)"
    print(io, "OpenAlexClient(", c.base_url, ", ", pool, ")")
end

# --- low-level request -----------------------------------------------------

function _throttle(c::OpenAlexClient)
    c.min_interval > 0 || return nothing
    elapsed = time() - c.last_request[]
    wait = c.min_interval - elapsed
    wait > 0 && sleep(wait)
    c.last_request[] = time()
    return nothing
end

"""
    get_entity(client, path; query)

Issue a `GET` against `client.base_url * path` and return the parsed JSON
(a `JSON3.Object`). `path` should begin with `/`, e.g. `"/works/W2741809807"`.
`query` is a `Dict` of extra query parameters; the client's `mailto` is added
automatically. This is the escape hatch for endpoints without a dedicated
wrapper.
"""
function get_entity(client::OpenAlexClient, path::AbstractString; query = Dict{String,String}())
    q = Dict{String,String}(query)
    client.mailto !== nothing && (q["mailto"] = client.mailto)
    url = client.base_url * path
    _throttle(client)
    resp = HTTP.get(url; query = q, headers = ["User-Agent" => client.user_agent])
    return JSON3.read(resp.body)
end

# --- query construction ----------------------------------------------------

# Render a filter argument into OpenAlex's `key:value,key:value` syntax.
# Accepts a ready-made string, or a Dict / NamedTuple / iterable of pairs.
_filterstr(s::AbstractString) = String(s)
_filterstr(pairs) = join((string(k, ":", _filterval(v)) for (k, v) in _pairs(pairs)), ",")

_pairs(d::AbstractDict) = d
_pairs(nt::NamedTuple) = pairs(nt)
_pairs(itr) = itr

# A vector value means "any of" (OpenAlex OR), expressed as `a|b|c`.
_filterval(v::AbstractString) = String(v)
_filterval(v::AbstractVector) = join(_filterval.(v), "|")
_filterval(v) = string(v)

# `select`/`sort` accept a string or a vector of fields.
_csv(s::AbstractString) = String(s)
_csv(v::AbstractVector) = join(string.(v), ",")

"""
    works(client; filter, search, sort, select, per_page, page, cursor, sample, seed, group_by)

Query the `/works` endpoint and return one page of results as parsed JSON.
All keyword arguments are optional and map onto the corresponding OpenAlex
query parameters.

- `filter`: either a raw filter string (`"cites:W123,type:!review"`) or a
  `Dict`/`NamedTuple`/iterable of pairs, e.g. `(cites = "W123", type = "!review")`.
  A vector value is treated as OR, e.g. `type = ["article", "preprint"]`.
- `select`, `sort`: a string or a vector of field names.
- `per_page`: results per page (max $(MAX_PER_PAGE)).
- `page`: 1-based page number (basic paging, capped by OpenAlex at 10 000 results).
- `cursor`: cursor token for deep paging; pass `"*"` to start. See [`paginate`](@ref).

The returned object has `.results` (a vector of works) and `.meta`
(with `.count`, `.next_cursor`, etc.).
"""
function works(client::OpenAlexClient;
               filter = nothing, search = nothing, sort = nothing, select = nothing,
               per_page = nothing, page = nothing, cursor = nothing,
               sample = nothing, seed = nothing, group_by = nothing)
    q = Dict{String,String}()
    filter   === nothing || (q["filter"]    = _filterstr(filter))
    search   === nothing || (q["search"]    = String(search))
    sort     === nothing || (q["sort"]      = _csv(sort))
    select   === nothing || (q["select"]    = _csv(select))
    per_page === nothing || (q["per-page"]  = string(per_page))
    page     === nothing || (q["page"]      = string(page))
    cursor   === nothing || (q["cursor"]    = String(cursor))
    sample   === nothing || (q["sample"]    = string(sample))
    seed     === nothing || (q["seed"]      = string(seed))
    group_by === nothing || (q["group_by"]  = _csv(group_by))
    return get_entity(client, "/works"; query = q)
end

"""
    paginate(client; endpoint="/works", per_page=$(MAX_PER_PAGE), max_results=nothing, kwargs...)

Fetch every result for a query by following OpenAlex's cursor paging, and
return them as a single `Vector`. `kwargs` are passed through to the page query
(`filter`, `search`, `select`, `sort`, ...). At most `max_results` entries are
returned when that is given. Requests are spaced according to the client's
`min_interval`.

Only `/works` is wrapped today; pass `endpoint` for forward compatibility.
"""
function paginate(client::OpenAlexClient;
                  endpoint::AbstractString = "/works",
                  per_page::Integer = MAX_PER_PAGE,
                  max_results::Union{Integer,Nothing} = nothing,
                  kwargs...)
    endpoint == "/works" || throw(ArgumentError("paginate currently supports only endpoint=\"/works\", got $endpoint"))
    results = Any[]
    cursor = "*"
    while cursor !== nothing
        page = works(client; per_page = per_page, cursor = cursor, kwargs...)
        append!(results, page.results)
        if max_results !== nothing && length(results) >= max_results
            resize!(results, max_results)
            break
        end
        cursor = get(page.meta, :next_cursor, nothing)
        # OpenAlex signals the end with a null cursor or an empty page.
        isempty(page.results) && break
    end
    return results
end

# --- citation helpers ------------------------------------------------------

"""
    openalex_id(work) -> String

Extract the short OpenAlex work id (e.g. `"W2741809807"`) from a work object,
a full id URL (`"https://openalex.org/W..."`), or a bare id string.
"""
openalex_id(id::AbstractString) = String(last(rsplit(id, '/'; limit = 2)))
openalex_id(work) = openalex_id(work.id)

# Turn a user-supplied identifier into the `/works/...` path segment.
function _work_path(id::AbstractString)
    s = strip(id)
    if startswith(s, "http") && occursin("doi.org", s)
        return "/works/" * s                        # full DOI URL is accepted as-is
    elseif startswith(s, "10.")
        return "/works/https://doi.org/" * s        # bare DOI
    elseif occursin("openalex.org/", s)
        return "/works/" * openalex_id(s)           # OpenAlex URL -> short id
    else
        return "/works/" * s                        # short id (W...) or other native id
    end
end

"""
    resolve_work(client, id) -> JSON3.Object

Fetch a single work by identifier. `id` may be a DOI (`"10.1038/nature12373"`
or its `https://doi.org/...` URL), an OpenAlex id (`"W2741809807"` or its URL),
or any other native id OpenAlex accepts on `/works/{id}`.
"""
resolve_work(client::OpenAlexClient, id::AbstractString) = get_entity(client, _work_path(id))

"""
    citing_works(client, work; exclude_types=nothing, extra_filter=nothing, kwargs...)

Return all works that cite `work` (given as a work object or an OpenAlex id).
Results come back as a `Vector` via cursor paging.

- `exclude_types`: a type or list of OpenAlex work types to drop, e.g.
  `"review"` or `["review", "editorial"]`. This adds a `type:!...` server-side
  filter, so reviews are excluded by OpenAlex rather than filtered locally.
- `extra_filter`: additional filter merged with the `cites` filter; same forms
  accepted as [`works`](@ref)'s `filter`.
- Remaining `kwargs` (`select`, `sort`, `max_results`, ...) pass through to
  [`paginate`](@ref).

If you only have a DOI, call [`resolve_work`](@ref) first to obtain the work.
"""
function citing_works(client::OpenAlexClient, work;
                      exclude_types = nothing, extra_filter = nothing, kwargs...)
    wid = openalex_id(work)
    parts = ["cites:" * wid]
    if exclude_types !== nothing
        types = exclude_types isa AbstractString ? [exclude_types] : exclude_types
        for t in types
            push!(parts, "type:!" * String(t))
        end
    end
    extra_filter !== nothing && push!(parts, _filterstr(extra_filter))
    return paginate(client; filter = join(parts, ","), kwargs...)
end

end # module OpenAlex
