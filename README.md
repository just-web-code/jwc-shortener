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
    pages.jwc             /, /docs, /openapi.json, /robots.txt, /sitemap.xml, /og.svg
    links.jwc             POST /api/links, GET /api/links/{code}, GET /{code}
    ops.jwc               /healthz, /api/v1/stats
  views/pages.jwc         the HTML, XML and SVG bodies
```

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET`  | `/` | landing page, `text/html` |
| `GET`  | `/docs` | Swagger UI, `text/html` |
| `GET`  | `/openapi.json` | the OpenAPI document |
| `GET`  | `/robots.txt`, `/sitemap.xml`, `/og.svg` | crawler and social-card files |
| `GET`  | `/healthz` | `{"status":"ok"}` — liveness probe |
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
# → 11 routes, listening on http://0.0.0.0:8080
```

The port is `serve(int(env("PORT") ?? "8080"))` in `src/app.jwc`, evaluated
at boot. `jwc serve --port N` overrides it.

Requires **jwc 0.9.9+**. Every one of these is used here and none is in an
earlier release:

| Needed for | Feature |
|---|---|
| `/`, `/docs`, `/robots.txt`, `/sitemap.xml`, `/og.svg` | `content(mime, body)` — the non-JSON body |
| the retry-on-conflict loop in `LinkService.create` | `break` / `continue` |
| `/api/v1/stats` | whole-table aggregates (`as { total: count(x) }`) |
| the 24-hour window in `/api/v1/stats` | `timestamptz - interval` |
| the landing page | `+` chains longer than 128 terms |

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
not be diffed against. A live database that already has these tables should
be reconciled with `jwc migrate status` rather than applied from empty.

## Stack

- **JWC** for the entire application.
- **Postgres** for storage, **Redis** for the rate-limit window.
- **Docker**: no build stage — the image ships the compiler and the sources, so it is
  the compiler plus `src/`, and the container runs `jwc serve`.
- **Kubernetes** + ArgoCD via the GitOps repo.
- **Cloudflare** edge + Let's Encrypt cert via cluster cert-manager.
