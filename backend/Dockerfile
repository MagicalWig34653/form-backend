# SPDX-License-Identifier: AGPL-3.0-only
# Multi-arch image (linux/amd64, linux/arm64) of the backend binary. Build context: repository root.
#   docker buildx build --platform linux/amd64,linux/arm64 -f backend/Dockerfile .
FROM swift:6.4-noble AS build
WORKDIR /src
COPY backend/Package.swift backend/Package.resolved ./backend/
COPY backend/Vendor ./backend/Vendor
WORKDIR /src/backend
RUN swift package resolve
COPY backend/Sources ./Sources
COPY backend/Tests ./Tests
# Tests are compiled separately in CI; the release image only needs the App product.
RUN swift build -c release --product App --static-swift-stdlib -Xswiftc -gnone && strip .build/release/App

# Runtime: Swift's slim image (glibc, ca-certificates, tzdata); no package installation needed in this stage.
FROM swift:6.4-noble-slim
RUN useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /src/backend/.build/release/App /app/App
COPY backend/db/schema-p3.sql /app/db/schema-p3.sql
# migrate also applies db/upgrades/0027-account-recovery.sql (next to the schema file); without it a fresh install fails.
COPY backend/db/upgrades /app/db/upgrades
COPY deploy/docker-entrypoint.sh /app/docker-entrypoint.sh
COPY pwa/dist /app/public
# The build context keeps the modes of the checkout (a dist built under umask 077 is 0600/0700 and unreadable for uid 10001): make it readable.
RUN chmod -R a+rX /app/public
COPY sdk/php/VERSION sdk/php/composer.json sdk/php/README.md /app/sdk/
COPY sdk/php/src /app/sdk/src
COPY sdk/php/bin /app/sdk/bin
USER 10001:10001
# glibc malloc: large upload buffers (up to ~20 MB, several copies per request) are served from mmap and returned to the OS
# on free, and arenas are capped. Without this the heap fragments, RSS keeps growing with every large submission and the
# process is OOM-killed at APP_MEMORY=512M (measured: 12 x 19.5 MB uploads, peak 417 MB -> 180 MB, steady RSS 265 MB -> 54 MB).
# Overridable at runtime (-e / compose environment).
ENV MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072 MALLOC_ARENA_MAX=2
ENV FORM_HTTP_HOST=0.0.0.0 FORM_SCHEMA_FILE=/app/db/schema-p3.sql FORM_PUBLIC_DIR=/app/public FORM_SDK_DIR=/app/sdk
EXPOSE 8080 8081
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["serve"]
