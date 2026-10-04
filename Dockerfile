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

# The two targets the release builds. The upstream recipe shipped fifteen; each
# extra one is another full GCC build, so the rest are left out.
ARG MUSL_TARGETS="x86_64-linux-musl aarch64-linux-musl"

# Empty means one make job per CPU. Set it when the builder has more cores than
# RAM to spare: a GCC build is memory-hungry, and the default is a poor fit for a
# small container VM.
ARG MUSL_JOBS=

# cross-make fetches these two from git.savannah.gnu.org while it unpacks sources
# (Makefile:197-210), and that host's git front-end is regularly unreachable, which
# fails the build before a compiler is built. No mirror of the exact revision it pins
# is dependable either. Seeding the files it wants means make finds them and skips its
# own download, at the cost of bypassing cross-make's sha1 check for them: these two
# sha256 values are ours, recorded from GCC's mirror at the commit pinned here. They are
# the same config.guess and config.sub that GCC ships.
ARG GCC_MIRROR_COMMIT=a72c55f2a6eae4093fd378d6d5e37cb3f4737fd0
ARG CONFIG_GUESS_SHA256=7d1e3c79b86de601c3a0457855ab854dffd15163f53c91edac54a7be2e9c931b
ARG CONFIG_SUB_SHA256=71b8d73e46e0c31b1dc91ba5306f5ef0af009273b3bb283f31d8dad69666fa9e

RUN apk add --no-cache \
        make curl bash patch gcc g++ musl-dev linux-headers \
        ca-certificates git gawk xz rsync file

COPY cross-make /build/cross-make
WORKDIR /build/cross-make

RUN set -eux; \
    mkdir -p /build/cross-make/sources; \
    for file in config.guess config.sub; do \
        case "$file" in \
            config.guess) want="$CONFIG_GUESS_SHA256" ;; \
            config.sub) want="$CONFIG_SUB_SHA256" ;; \
        esac; \
        curl -fsSL --retry 5 --retry-delay 3 --proto '=https' --proto-redir '=https' \
            -o "/build/cross-make/sources/$file" \
            "https://raw.githubusercontent.com/gcc-mirror/gcc/${GCC_MIRROR_COMMIT}/$file"; \
        printf '%s  %s\n' "$want" "/build/cross-make/sources/$file" >"/tmp/$file.sha256"; \
        sha256sum -c "/tmp/$file.sha256"; \
        rm -f "/tmp/$file.sha256"; \
        chmod +x "/build/cross-make/sources/$file"; \
    done

# HOST= pins cross-make's OUTPUT at output-gcc/ either side of a submodule bump:
# older revisions leave HOST empty, newer ones default it to "local", which
# appends a -local suffix to the output directory.
#
# FREEBSD_VER/NETBSD_VER/GLIBC_VER/MINGW_VER are cleared because cross-make's second,
# unconditional `extract_all` prerequisite line rebinds every SRC_DIRS entry and so
# defeats the per-target filter-out directly above it. Left alone, a musl build also
# downloads FreeBSD, NetBSD, glibc and mingw-w64 sources it never uses, and FreeBSD
# 14.3's base.txz is now a 404, so the build dies before reaching a compiler. Clearing
# them leaves exactly the sources a musl GCC build needs.
#
# They have to be make command-line assignments. Passed through the environment
# they would lose to the Makefile's own `FREEBSD_VER = 14.3` and change nothing.
RUN set -eux; \
    for target in $MUSL_TARGETS; do \
        make "TARGET=$target" HOST= FREEBSD_VER= NETBSD_VER= GLIBC_VER= MINGW_VER= -j"${MUSL_JOBS:-$(nproc)}"; \
        make "TARGET=$target" HOST= FREEBSD_VER= NETBSD_VER= GLIBC_VER= MINGW_VER= install; \
        make clean; \
    done; \
    # cross-make's install leaves usr -> . behind for its own build-time paths.
    # Copied into /usr/local it becomes a self-referential link at the root of the tree.
    rm -f /build/cross-make/output-gcc/usr

# --- windows ---------------------------------------------------------------
# llvm-mingw's release tarball, picked by build-host architecture. It carries the
# x86_64, i686, armv7 and aarch64 mingw targets, so this stage is not per-target.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS mingw

# Needed so a failure on the left of a pipe fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG LLVM_MINGW_VERSION=20260922
ARG LLVM_MINGW_HOST=ubuntu-22.04
# llvm-mingw publishes no checksums of its own. These are the sha256 values
# GitHub reports for the release assets, which is the only authoritative digest
# available for them. Bumping LLVM_MINGW_VERSION means re-reading them from
# `gh api repos/mstorsjo/llvm-mingw/releases/tags/<version>`.
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
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /llvm-mingw; \
    curl -fsSL --retry 5 --retry-delay 3 --proto '=https' --proto-redir '=https' \
        -o /tmp/llvm-mingw.tar.xz \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-${LLVM_MINGW_HOST}-${mingw_arch}.tar.xz"; \
    printf '%s  %s\n' "$mingw_sha" /tmp/llvm-mingw.tar.xz | sha256sum -c -; \
    tar -xJ --strip-components=1 -C /llvm-mingw -f /tmp/llvm-mingw.tar.xz; \
    rm -f /tmp/llvm-mingw.tar.xz

# --- final -----------------------------------------------------------------
FROM ubuntu:noble@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

# Needed so a failure on the left of a pipe fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG MISE_VERSION=v2026.10.1
# As with llvm-mingw, these are the sha256 values GitHub reports for the mise
# release binaries. They replace `curl https://mise.run | sh`, which fetched
# mutable script content over a redirect and executed it unverified.
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
# Only the mount point is trusted, and MISE_YES is deliberately absent from this
# image: on its own it answers mise's trust prompt for any configuration anywhere,
# which would make the trusted-paths list pointless. Paranoid mode is on because in
# normal mode mise exempts a configuration whose only content is plain [tools] pins, so
# a tools-only mise.toml anywhere on the filesystem is honoured and its tools fetched
# without a prompt. Under paranoid mode /work still works and that config is refused.
ENV MISE_TRUSTED_CONFIG_PATHS=/work
ENV MISE_PARANOID=1
ENV OSX_CROSS_PATH=/usr/local/osxcross

# file is for test/verify-toolchains.sh. libxml2 is here because osxcross's ld64
# and xar link against it and the upstream osxcross image does not carry a copy.
# llvm is here for dsymutil, and the dependency is hard: Go runs a bare `dsymutil`
# from PATH for an unstripped darwin cgo build, and fails the link with
# `running dsymutil failed: executable file not found in $PATH` when there is none.
# Neither the osxcross image nor llvm-mingw puts a bare dsymutil on PATH, because
# osxcross names its own after the target (arm64-apple-darwin25.1-dsymutil) and Go
# does not look there. Passing -w in ldflags is the only way to avoid the call.
# make and pkg-config are here because cgo dependencies commonly want them, and
# the image this replaces carried them. zip and tar stay for consumers whose
# release hooks want them. GoReleaser itself does not shell out to zip.
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        ca-certificates curl file git gzip libxml2 llvm make pkg-config \
        tar xz-utils zip; \
    rm -rf /var/lib/apt/lists/*; \
    # GoReleaser runs `git describe` on the mounted repository. The mount is owned
    # by the host user and the container is root, so git's ownership check would
    # refuse it as a dubious ownership unless the image opts out.
    git config --system --add safe.directory /work; \
    case "$TARGETARCH" in \
        amd64) mise_arch=x64; mise_sha="$MISE_SHA256_AMD64" ;; \
        arm64) mise_arch=arm64; mise_sha="$MISE_SHA256_ARM64" ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
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
    rm -rf /mise/downloads /root/.local/state/mise/trusted-configs

COPY --from=osxcross "${OSX_CROSS_PATH}" "${OSX_CROSS_PATH}"
COPY --from=musl-builder /build/cross-make/output-gcc/ /usr/local/
COPY --from=mingw /llvm-mingw /llvm-mingw

# The shims come first so a consumer's own mise.toml wins over the pinned tools,
# and mise fetches whatever that config asks for.
ENV PATH=/mise/shims:/usr/local/osxcross/bin:/llvm-mingw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
