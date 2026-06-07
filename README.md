# OpenAlex

[![Build Status](https://github.com/timholy/OpenAlex.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/timholy/OpenAlex.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/timholy/OpenAlex.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/timholy/OpenAlex.jl)

A small Julia client for the [OpenAlex](https://openalex.org) REST API,
currently focused on querying the `/works` endpoint and on citation traversal.
OpenAlex is free and needs no API key.

## Quick start

```julia
using OpenAlex

client = OpenAlexClient()        # anonymous, see below for "mailto"

# One page of results (parsed JSON):
page = works(client; filter = "publication_year:2020", per_page = 25)
page.meta.count                  # total matches
page.results                     # this page's works

# Every match, following OpenAlex's cursor paging:
all2020 = paginate(client; filter = "publication_year:2020", max_results = 1000)
```

`works` accepts the OpenAlex query parameters as keywords (`filter`, `search`,
`sort`, `select`, `per_page`, `page`, `cursor`, `sample`, `seed`, `group_by`).
`filter` may be a raw string or a `NamedTuple`/`Dict`; a vector value becomes an
OR:

```julia
works(client; filter = (publication_year = 2020, type = ["article", "preprint"]))
# -> filter=publication_year:2020,type:article|preprint
```

## Citations

Count/list the works citing a paper, optionally with reviews removed server-side:

```julia
w = resolve_work(client, "10.1038/nature14539")   # DOI, OpenAlex id, or URL

all_citers = citing_works(client, w)
non_reviews = citing_works(client, w; exclude_types = ["review"])

println(length(all_citers), " citing works; ",
        length(non_reviews), " excluding reviews")
```

`exclude_types` adds a `type:!review` filter, so the exclusion happens at
OpenAlex rather than locally. You can also just write the filter yourself:

```julia
works(client; filter = "cites:$(openalex_id(w)),type:!review", per_page = 1).meta.count
```

A note on accuracy: OpenAlex's review classification is good but not perfect.

## The polite pool

OpenAlex serves identified traffic from a faster, more reliable "polite pool".
To opt in, pass a contact email; it is sent as the `mailto` query parameter and
in the `User-Agent` header:

```julia
client = OpenAlexClient(; mailto = "you@example.org")
```

No email is sent unless you supply one (directly or via the `OPENALEX_MAILTO`
environment variable). There is no signup or key; the rate limits (10 req/s,
100 000/day) are the same either way, but the polite pool is more likely to
deliver them reliably. `paginate` spaces requests by the client's
`min_interval` (default 0.1 s) to stay within those limits.

## Escape hatch

For endpoints without a dedicated wrapper, `get_entity` issues a raw GET and
returns the parsed JSON:

```julia
get_entity(client, "/works/W2741809807")
get_entity(client, "/authors"; query = Dict("search" => "Marie Curie"))
```
