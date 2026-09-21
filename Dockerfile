# --- fetch the compiler ------------------------------------------------
#
# No build stage: the image ships the compiler and the sources, and
# `jwc serve` runs the program directly, so there is no Rust toolchain here.
#
# The native AOT backend is back as of 0.9.902 — `jwc build` produces a
# single binary, and this service is one of the programs it was verified
# against: built natively and diffed against `jwc serve` request by request,
# every route identical. Going back to a two-stage image is worth doing once
# it is measured: `jwc build` ships in the pinned release, so that is a
# change to make here rather than one to wait for.
FROM debian:trixie-slim AS fetch
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && rm -rf /var/lib/apt/lists/*

# Pinned to the release `jwcproj.json` names: `rc.N` and `rc.N+1` promise
# nothing to each other (SEMVER.md), and a compiler that does not satisfy
# the manifest refuses the project before it reads a line of it. Moving
# this pin means moving the source — `jwc fix` does the mechanical part —
# and the `jwc` field, in the same change.
ARG JWC_VERSION=1.0.0-rc.7
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
# `jwc serve` reads the mount root per request, so the files come along.
# A `jwc build` image would not need this — the walk happens at compile
# time and the bytes go inside the binary (routing.md §10.6) — which is
# one more reason to make that switch once it is measured.
COPY public /app/public

EXPOSE 8080
ENV RUST_LOG=info
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget -q -O- http://127.0.0.1:8080/healthz || exit 1

# The port is `server { port }` in `src/app.jwc`; `--port`, `JWC_PORT` and
# `PORT` override it in that order (config.md §3.2.2).
CMD ["jwc", "serve", "/app"]
