# jwc-shortener

A real production app written in [JWC](https://github.com/just-web-code/jwc-lang)
— a URL shortener with a landing page, QR codes and traffic stats.

Live: <https://1kb.uz/>

Ported to the **1.0 vocabulary**. The 0.9.x source (`dbcontext`, `entity`,
`pk`, `//` comments, one flat namespace) does not lex under the current
compiler; the layout below is the v1 one.

```
src/
  app.jwc                 database, schema, server { }, error, main()
  db/links.jwc            table Links, table ApiCalls
  dto/links.jwc           class LinkCreate — the POST body
  middleware/
    ratelimit.jwc         RateLimit  — redis.rate_limit, 60/60s per client
    metrics.jwc           MetricsTracker — an `after` block, one row per request
  services/
    links.jwc             create / resolve / detail
    qr.jwc                QR markup (was the `qr-lite` package)
  routes/
    site.jwc              the static mount, and two 301s for the 0.9 URLs
    links.jwc             POST /api/links, GET /api/links/{code}, GET /{code}
    ops.jwc               /api/v1/stats
public/
  index.html              the landing page
  robots.txt              crawler rules
  sitemap.xml             the two indexable URLs
  docs/index.html         Swagger UI over the OpenAPI document
  assets/og.svg           the social card
  assets/openapi.json     written by `jwc openapi` — see below
```

The pages are **files**, served by `static "/" from "public"`. The port
before this one carried them as 489 lines of `+ "\n"` string concatenation
in a `views/pages.jwc`, because 0.9 held the HTML in an `r"..."` literal
and 1.0 has no multi-line string. Neither form was right: they are files,
they never change per request, and as files they get an ETag, a 304 and a
`Cache-Control` for free — and under `jwc build` they are walked at compile
time and `include_bytes!`d into the binary, so the container needs no
directory beside it.

`robots.txt`, `sitemap.xml` and `docs/index.html` were routes until jwc
0.9.942: routing.md §10.2 put every route ahead of a `static` mount, and
`/{code}` is a route, so `/robots.txt` reached the redirect handler and
answered "no such link". §10.2 now ranks a mount ahead of a route that
bound a path parameter. The cost is that a mount takes no middleware, so
these four paths no longer reach `MetricsTracker` and drop out of
`/api/v1/stats` — in exchange they are cached, revalidated with an ETag,
and served without touching the database.

Regenerate the OpenAPI document after changing a route:

```bash
jwc openapi --out public/assets/openapi.json --title "1kb.uz API"
```

It is derived from the typed signatures, so unlike the hand-written 2 KB
JSON string it replaced there is no second description of the route table
to drift.

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET`  | `/` | landing page, `text/html` |
| `GET`  | `/docs` | Swagger UI, `text/html` |
| `GET`  | `/assets/openapi.json` | the OpenAPI document (`/openapi.json` 301s here) |
| `GET`  | `/robots.txt`, `/sitemap.xml` | crawler files |
| `GET`  | `/assets/og.svg` | the social card (`/og.svg` 301s here) |
| `GET`  | `/healthz`, `/readyz`, `/metrics` | operational, served by the runtime |
| `POST` | `/api/links` | `{"url":"..."}` → `{code, short, qr_svg}` |
| `GET`  | `/api/links/{code}` | `{code, url, hits, created_at}` |
| `GET`  | `/{code}` | 302 to the original URL, counting the click |
| `GET`  | `/api/v1/stats` | aggregate traffic, for the landing counters |

## Local dev

```bash
# 1. Postgres + Redis
docker compose up -d

# 2. Env
export DATABASE_URL=postgres://jwc:jwc@localhost:5432/shortener
export JWC_REDIS_URL=redis://localhost:6379
export PUBLIC_BASE_URL=http://localhost:8080

# 3. Migrate + run
jwc migrate up .
jwc serve .
# → 9 routes, listening on http://0.0.0.0:8080
```

The port is `server { port = 8080; }` in `src/app.jwc`; `jwc serve --port N`,
`JWC_PORT` and `PORT` override it in that order (config.md §3.2.2).

Requires **jwc 1.0.0-rc.8**, exactly — `jwcproj.json` names it, and a
compiler that does not satisfy it refuses the project. Moving the pin is
`jwc fix` plus the field. Every one of these is used here, and each
arrived in the 0.9.x release named:

| Needed for | Feature |
|---|---|
| `/robots.txt`, `/sitemap.xml`, `/docs` served from `public/` | a `static` mount outranking `/{code}` (routing.md §10.2, 0.9.942) |
| `GET /{code}` | `redirectExternal` — `redirect` refuses an off-site target (0.9.941) |
| the retry-on-conflict loop in `LinkService.create` | `break` / `continue` |
| `/api/v1/stats` | whole-table aggregates (`as { total: count(x) }`) |
| the 24-hour window in `/api/v1/stats` | `timestamptz - interval` (0.9.935) |
| `RateLimit` | `redis.rate_limit` (0.9.918) |

## `JWC_REDIS_URL` is not optional

There is no in-process fallback in 1.0. `redis.rate_limit` raises without a
server, and that is deliberate: a limiter that reads "no Redis" as "allowed"
admits every request and nothing in the response says so.

| | with `JWC_REDIS_URL` | without |
|---|---|---|
| `RateLimit` | shared across replicas | raises — the route answers 500 |
| `INCR` + `EXPIRE` | one atomic Lua script | — |

## Try it

```bash
curl -X POST http://localhost:8080/api/links \
    -H 'content-type: application/json' \
    -d '{"url":"https://example.com/very/long/path?with=many&query=params"}'
# → {"code":"a3f9c2d","short":"localhost:8080/a3f9c2d","qr_svg":"<img …/>"}

curl -I http://localhost:8080/a3f9c2d
# → HTTP/1.1 302 Found
# → Location: https://example.com/very/long/path?with=many&query=params
```

## Storage

The tables keep the physical names the 0.9.x deployment created — `link` and
`api_call`, via `as "…"` on the declarations — so an existing database needs
no data migration. `migrations/` was restarted for 1.0: the v1 applier is
snapshot-based and the three 0.9.x files carried no snapshot, so they could
not be diffed against.

A live database that already has these tables is adopted with **`jwc migrate
baseline`**, which marks the migrations applied without running them:

```bash
jwc migrate baseline     # the database is not touched
jwc migrate verify       # what still differs
```

`migrate status` was named here before and does not do this — it reports,
it does not reconcile, and `migrate up` against a 0.9.x database fails with
`relation "api_call" already exists`.

Baseline leaves the constraint and index names to you, because that is what
0.9.x got different: it wrote a bare `PRIMARY KEY (…)` and let Postgres name
it `link_pkey`, while 1.0 names it `pk_link` so a violated constraint can be
mapped back to its message. `verify` lists them, and the reconciling SQL is
run once, by hand, against that database only:

```sql
ALTER TABLE public.link     RENAME CONSTRAINT link_pkey     TO pk_link;
ALTER TABLE public.api_call RENAME CONSTRAINT api_call_pkey TO pk_api_call;
CREATE INDEX ix_link__hits   ON public.link (hits);
CREATE INDEX ix_api_call__ts ON public.api_call (ts);
```

It is not a file in `migrations/` on purpose: a database built by `jwc
migrate up` already has those names, and the rename would fail there.

## Stack

- **JWC** for the entire application.
- **Postgres** for storage, **Redis** for the rate-limit window.
- **Docker**: no build stage — the image ships the compiler and the sources, so it is
  the compiler plus `src/`, and the container runs `jwc serve`.
- **Kubernetes** + ArgoCD via the GitOps repo.
- **Cloudflare** edge + Let's Encrypt cert via cluster cert-manager.
