# syntax=docker/dockerfile:1

# darwin: the toolchain and the macOS SDK, taken whole from GoReleaser's image
FROM ghcr.io/goreleaser/goreleaser-osxcross:v26.1.1@sha256:19aaaee7baa7948e18aa91d435b82f053b722fa7b6fcf9b8482794f067073532 AS osxcross

# linux: cross-make builds the musl toolchains here. The base is alpine because
# cross-make links its compilers statically, so they run on the glibc base below;
# osxcross does not run on musl, which is why the final stage is not alpine.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8 AS musl-builder

# One more target is another full GCC build, so only what the release needs.
ARG MUSL_TARGETS="x86_64-linux-musl aarch64-linux-musl i686-linux-musl"
ARG MUSL_JOBS=

# cross-make fetches these from git.savannah.gnu.org at the revision its Makefile
# names, and that host is regularly unreachable, which fails the build before a
# compiler is built. The revision is read from the recipe and the content is checked
# below, so a submodule bump that moves the revision fails here instead of silently
# using an older copy. Re-read the digests after such a bump with:
#   git clone git://git.savannah.gnu.org/config.git
#   git -C config cat-file -p <rev>:config.guess | sha256sum
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

# HOST= keeps cross-make's output directory named output-gcc/ either side of a
# submodule bump. The *_VER overrides are command-line assignments, not environment,
# because an environment value loses to the Makefile's own: cross-make's unconditional
# extract_all prerequisites pull every source in SRC_DIRS, so without them a musl
# build also downloads FreeBSD, NetBSD, glibc and mingw sources it never uses, and
# FreeBSD 14.3's base.txz is a 404.
RUN set -eux; \
    for target in $MUSL_TARGETS; do \
        make "TARGET=$target" HOST= FREEBSD_VER= NETBSD_VER= GLIBC_VER= MINGW_VER= -j"${MUSL_JOBS:-$(nproc)}"; \
        make "TARGET=$target" HOST= FREEBSD_VER= NETBSD_VER= GLIBC_VER= MINGW_VER= install; \
        make clean; \
    done; \
    rm -f output-gcc/usr; \
    rm -rf sources ./*.orig

# windows: llvm-mingw's release tarball, which carries the i686, x86_64, armv7 and
# aarch64 mingw targets, so this stage is not per-target.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS mingw

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# llvm-mingw publishes no checksums; these are the sha256 values GitHub reports for
# the release assets. Bumping either version means re-reading both digests with
#   gh api repos/mstorsjo/llvm-mingw/releases/tags/<version> --jq '.assets[].digest'
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

# mise publishes no checksums either; these are GitHub's digests for the release
# binaries, and they replace `curl https://mise.run | sh`.
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
# MISE_YES answers the trust prompt for any configuration anywhere, so it is absent.
# MISE_PARANOID is set because without it mise exempts a configuration whose only
# content is plain [tools] pins, so one anywhere on disk would be honoured silently.
ENV MISE_TRUSTED_CONFIG_PATHS=/work
ENV MISE_PARANOID=1
ENV OSX_CROSS_PATH=/usr/local/osxcross

# libxml2: osxcross's ld64 and xar link against it and the upstream image has no copy.
# llvm: Go asks the compiler driver for dsymutil, gets osxcross's per-target name, and
# that name is a symlink into this package; without it an unstripped darwin cgo build
# fails to link. -s or -w in ldflags avoids the call.
# make, pkg-config, zip, tar: what cgo dependencies and release hooks commonly want.
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        ca-certificates curl file git gzip libxml2 llvm make pkg-config \
        tar xz-utils zip; \
    rm -rf /var/lib/apt/lists/*; \
    # GoReleaser runs `git describe` on a mount owned by the host user while the
    # container is root, which git refuses without this.
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
    # mise's state directory does not follow MISE_DATA_DIR, so the global install
    # above leaves a trusted entry behind. Only /work should be trusted at run time.
    rm -rf /mise/downloads /root/.local/state/mise/trusted-configs; \
    # Read by test/verify-toolchains.sh, which asserts rather than prints them.
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

# The shims come first so a mounted repository's mise.toml wins over the pinned tools.
ENV PATH=/mise/shims:/usr/local/osxcross/bin:/llvm-mingw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
