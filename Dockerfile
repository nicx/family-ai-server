# syntax=docker/dockerfile:1
#
# Family AI Server for Linux (amd64 / arm64).  Build:  docker build -t family-ai-server .
# Run with docker-compose.yml (see docs/docker.md): needs a master key secret, data lives in /data.

# ---- Family AI Runner (Windows, macOS arm64, Linux) ----
FROM --platform=$BUILDPLATFORM golang:1-bookworm AS runner
ARG VERSION=0.1.0-dev
WORKDIR /src/Runner
COPY Runner/ ./
RUN set -e; mkdir -p /out; \
    build() { CGO_ENABLED=0 GOOS=$1 GOARCH=$2 go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "/out/$3" .; }; \
    build windows amd64 family-ai-runner-windows-x64.exe; \
    build windows arm64 family-ai-runner-windows-arm64.exe; \
    build linux amd64 family-ai-runner-linux-x64; \
    build linux arm64 family-ai-runner-linux-arm64; \
    build darwin arm64 family-ai-runner-macos; \
    cd /out && sha256sum family-ai-runner-* > SHA256SUMS

# ---- Server ----
FROM swift:6.4-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product FamilyAIServer --static-swift-stdlib \
    && mkdir -p /out && cp "$(swift build -c release --show-bin-path)/FamilyAIServer" /out/

# ---- Runtime ----
FROM ubuntu:24.04
ARG VERSION=0.1.0-dev
# poppler-utils: PDF text, unzip: DOCX/ODT, ffmpeg: Safari voice recordings, libheif: iPhone photos (HEIC),
# curl: SMTP mail and the health check.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tzdata curl libcurl4 libxml2 libsqlite3-0 \
        poppler-utils unzip ffmpeg libheif-examples libheif-plugin-libde265 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin family \
    && mkdir -p /data /app && chown family:family /data
COPY --from=build /out/FamilyAIServer /app/FamilyAIServer
COPY Web /app/Web
COPY --from=runner /out /app/Web/runner
COPY docker/entrypoint.sh /app/entrypoint.sh
ENV FAMILY_AI_DATA=/data \
    FAMILY_AI_WEB=/app/Web \
    FAMILY_AI_PORT=8097 \
    FAMILY_AI_VERSION=$VERSION
VOLUME /data
EXPOSE 8097
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${FAMILY_AI_PORT}/api/info" >/dev/null || exit 1
ENTRYPOINT ["/app/entrypoint.sh"]
