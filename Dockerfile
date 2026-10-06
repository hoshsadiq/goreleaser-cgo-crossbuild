# syntax=docker/dockerfile:1

FROM ghcr.io/goreleaser/goreleaser-osxcross:v26.1.1@sha256:19aaaee7baa7948e18aa91d435b82f053b722fa7b6fcf9b8482794f067073532 AS osxcross

# Alpine builds the musl toolchains; the final stage cannot be Alpine because the
# osxcross binaries are glibc-linked. cross-make links its own compilers statically.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8 AS musl-builder

ARG MUSL_TARGETS="x86_64-linux-musl aarch64-linux-musl i686-linux-musl"
ARG MUSL_JOBS=

# Savannah is regularly unreachable and the build dies there, so these two are
# fetched here instead. The revision comes from cross-make's Makefile, and a bump
# that moves it fails the check below rather than silently using an older copy.
ARG CONFIG_GUESS_SHA256=50205cf3ec5c7615b17f937a0a57babf4ec5cd0aade3d7b3cccbe5f1bf91a7ef
ARG CONFIG_SUB_SHA256=26b852f75a637448360a956931439f7e818bf63150eaadb9b85484347628d1fd

RUN apk add --no-cache \
        make curl bash patch gcc g++ musl-dev linux-headers \
        ca-certificates git gawk xz rsync file

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY cross-make /build/cross-make
WORKDIR /build/cross-make

RUN set -eux; \
    git clone --quiet git://git.savannah.gnu.org/config.git /tmp/config; \
    mkdir -p sources; \
    for file in config.guess config.sub; do \
        case "$file" in \
            config.guess) rev_var=CONFIG_GUESS_REV; want="$CONFIG_GUESS_SHA256" ;; \
            config.sub) rev_var=CONFIG_SUB_REV; want="$CONFIG_SUB_SHA256" ;; \
        esac; \
        rev="$(sed -n "s/^$rev_var *= *//p" Makefile | head -1)"; \
        git -C /tmp/config cat-file -p "$rev:$file" >"sources/$file"; \
        printf '%s  %s\n' "$want" "sources/$file" | sha256sum -c -; \
        chmod +x "sources/$file"; \
    done; \
    rm -rf /tmp/config

# HOST= keeps the output directory named output-gcc/. The *_VER overrides have to be
# command-line assignments, not environment: an environment value loses to the
# Makefile's own. Without them cross-make's unconditional extract_all prerequisites
# also pull FreeBSD, NetBSD, glibc and mingw sources no musl build uses, and FreeBSD
# 14.3's tarball is a 404.
RUN set -eux; \
    for target in $MUSL_TARGETS; do \
        make "TARGET=$target" HOST= FREEBSD_VER= NETBSD_VER= GLIBC_VER= MINGW_VER= -j"${MUSL_JOBS:-$(nproc)}"; \
        make "TARGET=$target" HOST= FREEBSD_VER= NETBSD_VER= GLIBC_VER= MINGW_VER= install; \
        make clean; \
    done; \
    rm -f output-gcc/usr; \
    rm -rf sources ./*.orig

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS mingw

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# llvm-mingw publishes no checksums, so these are GitHub's digests for the assets.
ARG LLVM_MINGW_VERSION=20260922
ARG LLVM_MINGW_HOST=ubuntu-22.04
ARG LLVM_MINGW_SHA256_AMD64=bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21
ARG LLVM_MINGW_SHA256_ARM64=07d21263c56bfe9a713db6fdb3f7434bf4c121a005e40397d3b4c0170fb06769
ARG TARGETARCH

RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    case "$TARGETARCH" in \
        amd64) mingw_arch=x86_64; mingw_sha="$LLVM_MINGW_SHA256_AMD64" ;; \
        arm64) mingw_arch=aarch64; mingw_sha="$LLVM_MINGW_SHA256_ARM64" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH:-empty}; build with buildx and --platform" >&2; exit 1 ;; \
    esac; \
    mkdir -p /llvm-mingw; \
    curl -fsSL --retry 5 --retry-delay 3 --proto '=https' --proto-redir '=https' \
        -o /tmp/llvm-mingw.tar.xz \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-${LLVM_MINGW_HOST}-${mingw_arch}.tar.xz"; \
    printf '%s  %s\n' "$mingw_sha" /tmp/llvm-mingw.tar.xz | sha256sum -c -; \
    tar -xJ --strip-components=1 -C /llvm-mingw -f /tmp/llvm-mingw.tar.xz; \
    rm -f /tmp/llvm-mingw.tar.xz

FROM ubuntu:noble@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG MISE_VERSION=v2026.10.1
ARG MISE_SHA256_AMD64=31e6859cf639ed4594906da3fcd0fe2055e9daddae75e9786dbe50b3fb3c0f4a
ARG MISE_SHA256_ARM64=d4785456a86d1c836f09ccfe00aa6b044b18d29d79aae46a1820c96024cf9c38
ARG GO_VERSION=1.27.1
ARG GORELEASER_VERSION=v2.18.2
ARG COSIGN_VERSION=v3.1.3
ARG SYFT_VERSION=v1.54.0
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/hoshsadiq/goreleaser-cgo-crossbuild"
LABEL org.opencontainers.image.description="cgo cross-compilation toolchains for GoReleaser: linux/musl, darwin and windows, on a glibc base with mise"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV MISE_DATA_DIR=/mise
ENV MISE_GLOBAL_CONFIG_FILE=/mise/config.toml
ENV MISE_TRUSTED_CONFIG_PATHS=/work
ENV MISE_PARANOID=1
ENV OSX_CROSS_PATH=/usr/local/osxcross

# libxml2 for osxcross's ld64 and xar, llvm for the dsymutil Go looks for when it
# links an unstripped darwin cgo binary.
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        ca-certificates curl file git gzip libxml2 llvm make pkg-config \
        tar xz-utils zip; \
    rm -rf /var/lib/apt/lists/*; \
    git config --system --add safe.directory /work; \
    case "$TARGETARCH" in \
        amd64) mise_arch=x64; mise_sha="$MISE_SHA256_AMD64" ;; \
        arm64) mise_arch=arm64; mise_sha="$MISE_SHA256_ARM64" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH:-empty}; build with buildx and --platform" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 3 --proto '=https' --proto-redir '=https' \
        -o /tmp/mise \
        "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${mise_arch}"; \
    printf '%s  %s\n' "$mise_sha" /tmp/mise | sha256sum -c -; \
    install -m 0755 /tmp/mise /usr/local/bin/mise; \
    rm -f /tmp/mise; \
    mise use -g --yes \
        "go@${GO_VERSION}" \
        "goreleaser@${GORELEASER_VERSION}" \
        "cosign@${COSIGN_VERSION}" \
        "syft@${SYFT_VERSION}"; \
    rm -rf /mise/downloads /root/.local/state/mise/trusted-configs; \
    printf '%s\n' \
        "mise=$MISE_VERSION" \
        "go=$GO_VERSION" \
        "goreleaser=$GORELEASER_VERSION" \
        "cosign=$COSIGN_VERSION" \
        "syft=$SYFT_VERSION" \
        >/etc/goreleaser-cgo-crossbuild-versions

COPY --from=osxcross "${OSX_CROSS_PATH}" "${OSX_CROSS_PATH}"
COPY --from=musl-builder /build/cross-make/output-gcc/ /usr/local/
COPY --from=mingw /llvm-mingw /llvm-mingw

ENV PATH=/mise/shims:/usr/local/osxcross/bin:/llvm-mingw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
