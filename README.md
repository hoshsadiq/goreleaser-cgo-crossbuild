# goreleaser-cgo-crossbuild

A container image with the C toolchains needed to cross-build one Go binary with
`CGO_ENABLED=1` for Linux, macOS and Windows on amd64 and arm64, plus mise with
Go, GoReleaser, cosign and syft already installed.

It exists because a cgo build needs a C compiler per target, and putting all of
them in one image means a single `goreleaser release` can produce every target
instead of shelling out per platform.

Forked from [goreleaser/goreleaser-cross-toolchains](https://github.com/goreleaser/goreleaser-cross-toolchains),
which is where the llvm-mingw and osxcross recipes came from. Upstream's release
machinery is dropped here, so toolchain versions are bumped in this repository
rather than merged from there.

## What is inside

| `GOOS/GOARCH`   | `CC`                                      | `CXX`                                      |
| --------------- | ----------------------------------------- | ------------------------------------------ |
| `linux/amd64`   | `/usr/local/bin/x86_64-linux-musl-gcc`    | `/usr/local/bin/x86_64-linux-musl-g++`     |
| `linux/arm64`   | `/usr/local/bin/aarch64-linux-musl-gcc`   | `/usr/local/bin/aarch64-linux-musl-g++`    |
| `darwin/amd64`  | `/usr/local/osxcross/bin/o64-clang`       | `/usr/local/osxcross/bin/o64-clang++`      |
| `darwin/arm64`  | `/usr/local/osxcross/bin/oa64-clang`      | `/usr/local/osxcross/bin/oa64-clang++`     |
| `windows/amd64` | `/llvm-mingw/bin/x86_64-w64-mingw32-gcc`  | `/llvm-mingw/bin/x86_64-w64-mingw32-g++`   |
| `windows/arm64` | `/llvm-mingw/bin/aarch64-w64-mingw32-gcc` | `/llvm-mingw/bin/aarch64-w64-mingw32-g++`  |

llvm-mingw also carries `i686` and `armv7` for Windows. The osxcross image ships
`o64`, `o64h`, `oa64` and `oa64e`, so there is no 32-bit Darwin compiler, and
`o32-clang` that later GoReleaser images mention does not exist here.

On `PATH`, ahead of `/usr/local/bin`, are mise shims for Go, GoReleaser, cosign
and syft, so a `mise.toml` in the mounted repository decides the versions. A
repository that pins its own Go gets that Go, downloaded at run time.

The base is `ubuntu:noble` (glibc). That is not incidental: osxcross does not run
on musl. The musl toolchains are built in an Alpine stage and copied in, which
works because cross-make links their executables statically
(`litecross/Makefile.gcc` sets `STAT = -static --static` unless the build host is
darwin).

The osxcross wrappers look up a bare `clang` on `PATH`, so the Darwin toolchain
depends on the llvm-mingw clang that comes later in `PATH`. `/llvm-mingw/bin`
cannot be dropped from `PATH` without breaking Darwin builds even though Darwin
never runs a Windows compiler.

Go also links an unstripped Darwin cgo build through a bare `dsymutil` taken from
`PATH`, so the final stage installs `llvm` for it. Without one the link fails
outright, and `-w` in `ldflags` is the only way to avoid the call: `-s` alone does
not. The copy osxcross ships is named after the target
(`arm64-apple-darwin25.1-dsymutil`) and Go never looks for that name, so the
osxcross image on its own is not enough.

## Using it

Pin by digest, and verify the signature first. The tag in a `FROM` line or a
compose file is for humans; the digest is what decides which image runs.

```
cosign verify ghcr.io/hoshsadiq/goreleaser-cgo-crossbuild@sha256:<digest> \
  --certificate-identity-regexp '^https://github.com/hoshsadiq/goreleaser-cgo-crossbuild/\.github/workflows/image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Each workflow run also pushes two single-architecture tags named after the run id
(`:<run-id>-amd64` and `:<run-id>-arm64`) and merges their digests into the
version tags. Those run-id tags are breadcrumbs showing which builds the index was
assembled from. They are unsigned, and nothing should pin them.

Mount the repository you are releasing at `/work`. That is the working directory
and the only path whose mise configuration is trusted.

GoReleaser selects the compiler per target through `CC_<os>_<arch>` and
`CXX_<os>_<arch>`:

```yaml
env:
  - CGO_ENABLED=1
  - CC_linux_amd64=/usr/local/bin/x86_64-linux-musl-gcc
  - CXX_linux_amd64=/usr/local/bin/x86_64-linux-musl-g++
  - CC_linux_arm64=/usr/local/bin/aarch64-linux-musl-gcc
  - CXX_linux_arm64=/usr/local/bin/aarch64-linux-musl-g++
  - CC_darwin_amd64=/usr/local/osxcross/bin/o64-clang
  - CXX_darwin_amd64=/usr/local/osxcross/bin/o64-clang++
  - CC_darwin_arm64=/usr/local/osxcross/bin/oa64-clang
  - CXX_darwin_arm64=/usr/local/osxcross/bin/oa64-clang++
  - CC_windows_amd64=/llvm-mingw/bin/x86_64-w64-mingw32-gcc
  - CXX_windows_amd64=/llvm-mingw/bin/x86_64-w64-mingw32-g++
  - CC_windows_arm64=/llvm-mingw/bin/aarch64-w64-mingw32-gcc
  - CXX_windows_arm64=/llvm-mingw/bin/aarch64-w64-mingw32-g++

builds:
  - env:
      - 'CC={{ index .Env (print "CC_" .Os "_" .Arch) }}'
      - 'CXX={{ index .Env (print "CXX_" .Os "_" .Arch) }}'
```

Keep the explicit list. `index` on a missing key returns an empty string rather
than failing, so a target you forgot to list would be compiled by whatever `gcc`
happens to be on `PATH`.

Static linking for Linux goes in `ldflags`, alongside the toolchain choice:

```yaml
      - '{{ if eq .Os "linux" }}-extldflags "-static"{{ end }}'
```

The result reports as `statically linked` when Go drives the link. Compiling C
with the musl compilers directly and the same `-static` reports `static-pie
linked`, because those toolchains default to PIE. Both are static binaries.

## Trust

The container runs as root, and a repository mounted at `/work` is trusted: its
`mise.toml` may select tool versions, and mise will fetch them. Mount only a
repository you would run a release for.

Nothing else is trusted. `MISE_PARANOID` is set because in its normal mode mise
exempts a configuration whose only content is plain `[tools]` pins: without it a
tools-only `mise.toml` anywhere on the filesystem would be honoured, and its tools
fetched, with no prompt at all. With it, a configuration anywhere outside `/work`
is refused by `mise ls`, `mise env`, `mise exec` and the shims, while `/work` keeps
working, including a repository that pins its own Go version.

`MISE_YES` is deliberately absent. On its own it answers mise's trust prompt for
any configuration anywhere, which would make the trusted-paths list pointless.
`MISE_SAFE` is also absent: it blocks `_.file` in `[env]`, which is how many
repositories (including the one this image was built for) load a `.env`, and it
does so silently.

`git config --system --add safe.directory /work` is set because the mount is owned
by the host user while the container is root, so git would otherwise refuse it as
a dubious ownership. A repository mounted somewhere else needs its own entry.

## Checking an image

```
mise run check          # hadolint, actionlint, shellcheck
mise run image:verify   # build for the host architecture, then exercise every toolchain
mise run image:release  # run a GoReleaser snapshot release for six targets in the image
```

`test/verify-toolchains.sh` compiles a C and a C++ hello-world with each of the
six toolchains, checks the file format of each result, and checks that each musl
compiler's include search list reaches its own sysroot rather than the host's
glibc headers. It runs on every workflow run, including the ones that publish.

## Building it

```
git submodule update --init --recursive
mise run image:build
```

`mise run image:build` does the submodule step for you. A GCC build is
memory-hungry, so on a small builder pass a job count:

```
mise run image:build -- --build-arg MUSL_JOBS=2
```

The musl stage dominates the build: cross-make compiles GCC and binutils once per
musl target, and the rest is downloading by comparison. A cold build of both musl
targets took 28 minutes on a 5 CPU, 4 GiB machine at `MUSL_JOBS=2`; the GitHub
runners have 4 CPUs and use the default `-j4`. Once that layer is cached a rebuild
is minutes.

The workflow gives each architecture a native runner and a five-hour budget.
Running both architectures on one runner would put the musl stage under QEMU,
where two GCC builds do not fit inside GitHub's six-hour cap.

The two config scripts cross-make would fetch from `git.savannah.gnu.org` are
instead downloaded from GCC's mirror and seeded into its sources directory before
`make` runs, with a sha256 check. Savannah's git front-end is regularly
unreachable, and a build that fails there dies before reaching a compiler.

## Pinned versions

Every version is an ARG default at the top of the stages in `Dockerfile`, and
Renovate bumps them along with the base image digests. Three of them cannot be
bumped on their own:

- `LLVM_MINGW_VERSION` has `LLVM_MINGW_SHA256_AMD64` and `LLVM_MINGW_SHA256_ARM64`
  beside it.
- `MISE_VERSION` has `MISE_SHA256_AMD64` and `MISE_SHA256_ARM64`.
- `GCC_MIRROR_COMMIT` has `CONFIG_GUESS_SHA256` and `CONFIG_SUB_SHA256` for the
  two config scripts taken from that commit.

Neither project publishes checksums, so those values are the sha256 digests
GitHub reports for the release assets:

```
gh api repos/mstorsjo/llvm-mingw/releases/tags/<version> --jq '.assets[].digest'
gh api repos/jdx/mise/releases/tags/<version> --jq '.assets[].digest'
```

A version bump without the matching digest change fails the build rather than
fetching something new and unverified.

The `cross-make` submodule is pinned deliberately. It decides the GCC, binutils,
musl and Linux header versions and carries the musl patches, so bumping it changes
the Linux toolchain: read the versions in `cross-make/Makefile` and run the
toolchain check afterwards. The two config scripts are the one thing the recipe
fetches that the submodule pin does not cover, which is why they are pinned above
instead.

## What this image does not carry

The `goreleaser-cross` image it replaces is built on goreleaser's full toolchains
image, so it also has `python3`, `jq`, `wget`, `cmake`, `autoconf`, `automake`,
`bc`, `libtool`, `patch`, `rsync`, `unzip` and glibc cross toolchains for nine
Debian architectures. None of that is here. A release whose `before.hooks` runs
Python, `jq` or `cmake` needs it added; a build that wants a glibc Linux binary
rather than a static musl one needs a different image.

## The macOS SDK

The Darwin toolchain, and the macOS SDK it links against, are copied out of
`ghcr.io/goreleaser/goreleaser-osxcross`, not built here. That SDK is Apple's and
its redistribution terms are not ours to interpret. GoReleaser already publishes
it in that form. Worth a human read before this image is made widely available.

## Licence

MIT for this repository, inherited from upstream. See `LICENSE`.

The image also redistributes GCC and binutils, which are GPLv3. Their
corresponding source is the `cross-make` submodule at the commit pinned in this
repository, plus the tarballs cross-make downloads at the versions named in
`cross-make/Makefile`.
