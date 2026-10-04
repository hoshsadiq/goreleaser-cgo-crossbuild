# syntax=docker/dockerfile:1
#
# One image, three C toolchains, for cgo cross-builds of a single Go binary:
#
#   linux   /usr/local/bin/x86_64-linux-musl-gcc, aarch64-linux-musl-gcc
#   darwin  /usr/local/osxcross/bin/o64-clang, oa64-clang
#   windows /llvm-mingw/bin/x86_64-w64-mingw32-gcc, aarch64-w64-mingw32-gcc
#
# The base is glibc (ubuntu:noble) because osxcross will not run on musl, and the
# musl toolchains are built here rather than taken from an alpine image because
# cross-make links their executables statically, so they run on glibc.
#
# Pinned versions are the ARG defaults below. Renovate bumps them, and the base
# images, from renovate.json.

# --- darwin ----------------------------------------------------------------
# The toolchain and the macOS SDK, taken whole from GoReleaser's osxcross image.
# We redistribute it rather than build it; see the SDK note in README.md.
FROM ghcr.io/goreleaser/goreleaser-osxcross:v26.1.1@sha256:19aaaee7baa7948e18aa91d435b82f053b722fa7b6fcf9b8482794f067073532 AS osxcross

# --- linux -----------------------------------------------------------------
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8 AS musl-builder

# The two targets the release builds. cross-make supports fifteen; each extra
# one is another full GCC build, so the rest are left out.
ARG MUSL_TARGETS="x86_64-linux-musl aarch64-linux-musl"

RUN apk add --no-cache \
        make curl bash patch gcc g++ musl-dev linux-headers \
        ca-certificates git gawk xz rsync file

COPY cross-make /build/cross-make
WORKDIR /build/cross-make

# HOST= pins cross-make's OUTPUT at output-gcc/ either side of a submodule bump:
# older revisions leave HOST empty, newer ones default it to "local", which
# appends a -local suffix to the output directory.
RUN set -eux; \
    for target in $MUSL_TARGETS; do \
        TARGET="$target" HOST= make -j"$(nproc)"; \
        TARGET="$target" HOST= make install; \
        make clean; \
    done

# --- windows ---------------------------------------------------------------
# llvm-mingw's release tarball, picked by build-host architecture. It carries the
# x86_64, i686, armv7 and aarch64 mingw targets, so this stage is not per-target.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS mingw

ARG LLVM_MINGW_VERSION=20260922
ARG LLVM_MINGW_HOST=ubuntu-22.04
ARG TARGETARCH

RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    case "$TARGETARCH" in \
        amd64) mingw_arch=x86_64 ;; \
        arm64) mingw_arch=aarch64 ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /llvm-mingw; \
    curl -fsSL --retry 5 --retry-delay 3 \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-${LLVM_MINGW_HOST}-${mingw_arch}.tar.xz" \
        | tar -xJ --strip-components=1 -C /llvm-mingw

# --- final -----------------------------------------------------------------
FROM ubuntu:noble@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

ARG MISE_VERSION=v2026.10.1
ARG GO_VERSION=1.27.1
ARG GORELEASER_VERSION=v2.18.2
ARG COSIGN_VERSION=v3.1.3
ARG SYFT_VERSION=v1.54.0

LABEL org.opencontainers.image.source="https://github.com/hoshsadiq/goreleaser-cgo-crossbuild"
LABEL org.opencontainers.image.description="cgo cross-compilation toolchains for GoReleaser: linux/musl, darwin and windows, on a glibc base with mise"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV MISE_DATA_DIR=/mise
ENV MISE_GLOBAL_CONFIG_FILE=/mise/config.toml
# The image is mounted with arbitrary repositories, so trust any config it finds
# rather than making every consumer pass --trusted-configs.
ENV MISE_TRUSTED_CONFIG_PATHS=/
ENV MISE_YES=1
ENV OSX_CROSS_PATH=/usr/local/osxcross

# zip is here for GoReleaser, which shells out to it for zip archives; file is
# for test/verify-toolchains.sh; libxml2 is here because osxcross's ld64 and xar
# link against it and the upstream osxcross image does not carry a copy.
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        ca-certificates curl file git gzip libxml2 tar xz-utils zip; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL --retry 5 --retry-delay 3 https://mise.run \
        | MISE_VERSION="${MISE_VERSION}" MISE_INSTALL_PATH=/usr/local/bin/mise sh; \
    mise use -g --yes \
        "go@${GO_VERSION}" \
        "goreleaser@${GORELEASER_VERSION}" \
        "cosign@${COSIGN_VERSION}" \
        "syft@${SYFT_VERSION}"; \
    rm -rf /mise/downloads

COPY --from=osxcross "${OSX_CROSS_PATH}" "${OSX_CROSS_PATH}"
COPY --from=musl-builder /build/cross-make/output-gcc/ /usr/local/
COPY --from=mingw /llvm-mingw /llvm-mingw

# The shims come first so a consumer's own mise.toml wins over the pinned tools,
# and mise fetches whatever that config asks for.
ENV PATH=/mise/shims:/usr/local/osxcross/bin:/llvm-mingw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
