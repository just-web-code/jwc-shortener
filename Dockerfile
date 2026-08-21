# --- fetch the compiler ------------------------------------------------
#
# No build stage: the image ships the compiler and the sources, and
# `jwc serve` runs the program directly, so there is no Rust toolchain here.
#
# The native AOT backend is back as of 0.9.902 — `jwc build` produces a
# single binary, and this service is one of the programs it was verified
# against: built natively and diffed against `jwc serve` request by request,
# every route identical. Going back to a two-stage image is worth doing once
# a release carries that backend; 0.9.9 (pinned below) does not, and pinning
# to a version that does not exist would break the build rather than the
# benchmark.
FROM debian:trixie-slim AS fetch
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && rm -rf /var/lib/apt/lists/*

# This service needs every one of these, and no earlier release has them:
#   content(mime, body)            the landing page, robots.txt, sitemap.xml
#                                  and og.svg are not JSON
#   break / continue               the retry-on-conflict loop in LinkService
#   whole-table aggregates         /api/v1/stats
#   timestamptz - interval         the 24-hour window in /api/v1/stats
#   long `+` chains                the landing page is 360 concatenated lines
# Do not pin below 0.9.9.
ARG JWC_VERSION=0.9.9
RUN curl -fsSL https://github.com/just-web-code/jwc-lang/releases/download/v${JWC_VERSION}/jwc-v${JWC_VERSION}-x86_64-linux.tar.gz \
        | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/jwc \
    && jwc --version

# --- runtime -----------------------------------------------------------
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# One binary serves both roles: the init container runs `jwc migrate up`
# and the pod runs `jwc serve`.
COPY --from=fetch /usr/local/bin/jwc /usr/local/bin/jwc
COPY jwcproj.json /app/jwcproj.json
COPY src /app/src
COPY migrations /app/migrations

EXPOSE 8080
ENV RUST_LOG=info
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget -q -O- http://127.0.0.1:8080/healthz || exit 1

# The port comes from `serve(int(env("PORT") ?? "8080"))` in `src/app.jwc`,
# which the runtime evaluates at boot (config.md §3.2.2).
CMD ["jwc", "serve", "/app"]
