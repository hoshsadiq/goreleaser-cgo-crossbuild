# goreleaser-cgo-crossbuild

A container image with the C toolchains needed to cross-build one Go binary with
`CGO_ENABLED=1` for Linux, macOS and Windows, plus mise with Go, GoReleaser,
cosign and syft already installed.

A cgo build needs a C compiler per target. Putting all of them in one image means
one `goreleaser release` produces every target instead of shelling out per
platform.

Forked from [goreleaser/goreleaser-cross-toolchains](https://github.com/goreleaser/goreleaser-cross-toolchains),
which is where the llvm-mingw and osxcross recipes came from. Upstream's release
machinery is dropped here, so toolchain versions are bumped in this repository
rather than merged from there.

## What is inside

| `GOOS/GOARCH`   | `CC`                                      | `CXX`                                      |
| --------------- | ----------------------------------------- | ------------------------------------------ |
| `linux/amd64`   | `/usr/local/bin/x86_64-linux-musl-gcc`    | `/usr/local/bin/x86_64-linux-musl-g++`     |
| `linux/arm64`   | `/usr/local/bin/aarch64-linux-musl-gcc`   | `/usr/local/bin/aarch64-linux-musl-g++`    |
| `linux/386`     | `/usr/local/bin/i686-linux-musl-gcc`      | `/usr/local/bin/i686-linux-musl-g++`       |
| `darwin/amd64`  | `/usr/local/osxcross/bin/o64-clang`       | `/usr/local/osxcross/bin/o64-clang++`      |
| `darwin/arm64`  | `/usr/local/osxcross/bin/oa64-clang`      | `/usr/local/osxcross/bin/oa64-clang++`     |
| `windows/amd64` | `/llvm-mingw/bin/x86_64-w64-mingw32-gcc`  | `/llvm-mingw/bin/x86_64-w64-mingw32-g++`   |
| `windows/arm64` | `/llvm-mingw/bin/aarch64-w64-mingw32-gcc` | `/llvm-mingw/bin/aarch64-w64-mingw32-g++`  |

The 32-bit Linux compiler is cross-make's `i686-linux-musl`, which is what
`GOARCH=386` pairs with. llvm-mingw also carries `i686` and `armv7` for Windows,
though nothing here builds those. The osxcross image has `o64`, `o64h`, `oa64` and
`oa64e`, and no 32-bit Darwin compiler.

On `PATH`, ahead of `/usr/local/bin`, are mise shims for Go, GoReleaser, cosign
and syft, so a `mise.toml` in the mounted repository decides the versions. A
repository that pins its own Go gets that Go, downloaded at run time.

The base is `ubuntu:noble`, so glibc. The osxcross binaries this image copies are
glibc-linked and will not run on musl. The musl toolchains are built in an Alpine
stage and copied in, which works because cross-make links its compilers statically
(`litecross/Makefile.gcc` sets `STAT = -static --static` unless the build host is
darwin).

The osxcross wrappers look up a bare `clang` on `PATH`, so Darwin builds depend on
the llvm-mingw clang further down `PATH`. Dropping `/llvm-mingw/bin` breaks them,
even though Darwin never runs a Windows compiler.

Go links an unstripped Darwin cgo build through `dsymutil`. It asks the compiler
driver for it (`CC --print-prog-name=dsymutil`), which answers with osxcross's
per-target name, and that name is a symlink into the `llvm` package this stage
installs. Without the package the symlink dangles and the build fails with
`running dsymutil failed: exec: "dsymutil": executable file not found in $PATH`.
Either `-s` or `-w` in `ldflags` avoids the call, since Go treats `-s` as implying
`-w` when `-w` was not given.

## Using it

Pin by digest and verify the signature first. A tag in a `FROM` line is for your
eyes; the digest is what decides which image runs.

```
cosign verify ghcr.io/hoshsadiq/goreleaser-cgo-crossbuild@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/hoshsadiq/goreleaser-cgo-crossbuild/\.github/workflows/image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Mount the repository you are releasing at `/work`. That is the working directory,
and the only path whose mise configuration is trusted:

```
docker run --rm -it \
  --volume "$PWD:/work" --workdir /work \
  --env GITHUB_TOKEN \
  ghcr.io/hoshsadiq/goreleaser-cgo-crossbuild@sha256:<digest> \
  goreleaser release --clean
```

GoReleaser picks the compiler per target through `CC_<os>_<arch>` and
`CXX_<os>_<arch>`:

```yaml
env:
  - CGO_ENABLED=1
  - CC_linux_amd64=/usr/local/bin/x86_64-linux-musl-gcc
  - CXX_linux_amd64=/usr/local/bin/x86_64-linux-musl-g++
  - CC_linux_arm64=/usr/local/bin/aarch64-linux-musl-gcc
  - CXX_linux_arm64=/usr/local/bin/aarch64-linux-musl-g++
  - CC_linux_386=/usr/local/bin/i686-linux-musl-gcc
  - CXX_linux_386=/usr/local/bin/i686-linux-musl-g++
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

Keep the list explicit. `index` on a missing key returns an empty string instead of
failing, so a target you forget is compiled with an empty `CC`. That does fail here,
but the message comes from cgo, not from GoReleaser.

Static linking for Linux goes in `ldflags`, next to the toolchain choice:

```yaml
      - '{{ if eq .Os "linux" }}-extldflags "-static"{{ end }}'
```

Go reports the result as `statically linked`. Compiling C directly with those musl
compilers reports `static-pie linked` instead, since they default to PIE. Both are
static binaries.

## Publishing

A run that is allowed to publish pushes one tag per architecture named after the
run id (`:<run-id>-amd64`, `:<run-id>-arm64`), merges those two digests into an
index, signs the index, and only then adds the release tags. A tag push `v1.2.3`
becomes `1.2.3` and `1.2`; the default branch gets `latest`, the date and
`sha-<7>`. The `v` is dropped, so image tags do not match git tags.

The run-id tags are breadcrumbs showing which builds an index was assembled from.
They are unsigned, nothing should pin them, and nothing removes them.

## Trust

The container runs as root, and a repository mounted at `/work` is trusted: its
`mise.toml` may choose tool versions and mise will fetch them. Mount only a
repository you would run a release for.

Nothing else is trusted. `MISE_PARANOID` is set because mise otherwise exempts a
configuration whose only content is plain `[tools]` pins, so a tools-only
`mise.toml` anywhere on disk would be honoured silently. With it, a configuration
outside `/work` is refused by `mise ls`, `mise env`, `mise exec` and the shims.
That refusal reaches the shims, so `go`, `goreleaser`, `cosign` and `syft` all exit
with the trust error rather than falling back to the baked-in versions. A mount
elsewhere needs its own entry in `MISE_TRUSTED_CONFIG_PATHS` and in git's
`safe.directory`.

`MISE_YES` is deliberately absent: on its own it answers the trust prompt for any
configuration anywhere, which makes the trusted-paths list pointless. `MISE_SAFE`
is absent too, because it blocks `_.file` in `[env]`, which is how many
repositories load a `.env`, and it does so without a word.

`git config --system --add safe.directory /work` is set because the mount belongs
to the host user while the container is root, and git refuses that otherwise.

mise treats its own global configuration as trusted by definition, and here that
is `/mise/config.toml`, where the pinned tools are recorded. Do not mount anything
over `/mise`.

## Darwin deployment target

osxcross links against a macOS deployment target older than the one Go stamps its
objects with, so a Darwin build logs:

```
ld: warning: object file (/tmp/go-link-XXXX/go.o) was built for newer macOS version (13.0) than being linked (11.0)
```

Set `MACOSX_DEPLOYMENT_TARGET` in the build environment, as a GoReleaser `env`
entry, to silence it and to state the target you actually support.

## Checking an image

```
mise run check          # hadolint, actionlint, shellcheck
mise run image:verify   # build for the host architecture, then exercise every toolchain
mise run image:release  # run a GoReleaser snapshot release for seven targets in the image
```

`test/verify-toolchains.sh` compiles a C and a C++ hello-world with each of the
seven toolchains, checks what `file` reports for each result, and checks that every
musl compiler's include search list reaches its own sysroot and not the host's glibc
headers. Both scripts run on every workflow run, including the ones that publish.

## Building it

```
mise run image:build
```

That initialises the submodule first; without it the build fails with
`make: *** No targets specified and no makefile found. Stop.`, which says nothing
about what is missing. A GCC build is memory-hungry, so on a small builder pass a
job count:

```
mise run image:build -- --build-arg MUSL_JOBS=2
```

The musl stage dominates: cross-make compiles GCC and binutils once per musl
target, and everything else is downloading by comparison. That is half an hour to
an hour on a 5 CPU, 4 GiB machine at `MUSL_JOBS=2` (27 minutes for two targets on
an idle machine, 53 for three while other containers shared the CPU); once the
layer is cached a rebuild is minutes. The workflow gives each architecture a native
runner and a five-hour budget, because running both architectures on one runner
puts the musl stage under QEMU, where the GCC builds do not fit inside GitHub's
six-hour cap.

cross-make fetches `config.guess` and `config.sub` from `git.savannah.gnu.org`
while unpacking sources, and that host is regularly unreachable, which kills the
build before a compiler is built. Both files are committed under `gnu-config/`
instead, taken from the revision cross-make's Makefile pins, with their sha256 in
the Dockerfile. A build-time guard compares that revision against the one in
`cross-make/Makefile` and fails if a submodule bump moves it, so the copy cannot go
stale without saying so.

nixpkgs solves the same problem by pinning the two files by hash and fetching them
from a cgit URL (`pkgs/by-name/gn/gnu-config`). That is the right shape, but when
the host is down the fetch still fails, so the files are committed here and nothing
is fetched at build time.

## Pinned versions

Every version is an ARG default at the top of the stages in `Dockerfile`. Renovate
is configured to bump them and the base image digests, which assumes the Renovate
app is installed on this repository: there is no Dependabot config, so nothing else
will move them, and with issues disabled the dependency dashboard is switched off.

Three pins have a digest beside them and cannot be bumped alone:

- `LLVM_MINGW_VERSION` with `LLVM_MINGW_SHA256_AMD64` and `LLVM_MINGW_SHA256_ARM64`
- `MISE_VERSION` with `MISE_SHA256_AMD64` and `MISE_SHA256_ARM64`
- the two config scripts with `CONFIG_GUESS_SHA256` and `CONFIG_SUB_SHA256`, whose
  revision comes out of cross-make's Makefile at build time

Neither project publishes checksums, so those values are the digests GitHub reports
for the release assets:

```
gh api repos/mstorsjo/llvm-mingw/releases/tags/<version> --jq '.assets[].digest'
gh api repos/jdx/mise/releases/tags/<version> --jq '.assets[].digest'
```

Renovate bumps the versions but not the digests, so such a pull request arrives red
until someone edits the matching digest. That is the point: a version bump without
it fails the build instead of fetching something new and unverified.

The `cross-make` submodule is pinned on purpose. It decides the GCC, binutils,
musl and Linux header versions and carries the musl patches, so bumping it changes
the Linux toolchain: read the versions in `cross-make/Makefile` and run the
toolchain check afterwards.

## What this image does not carry

The `goreleaser-cross` image it replaces is built on goreleaser's full toolchains
image, so it also has `python3`, `jq`, `wget`, `cmake`, `autoconf`, `automake`,
`bc`, `libtool`, `patch`, `mercurial`, `gdb`, `openssl` and glibc cross toolchains
for nine Debian architectures. None of that is here, and there is no `docker`
client or daemon either, so a GoReleaser `dockers:` or `dockers_v2:` block cannot
run in this image. A release whose `before.hooks` runs Python, `jq` or `cmake` needs
those added. A build that wants a glibc Linux binary instead of a static musl one,
or that publishes a container image, needs a different image.

## The macOS SDK

The Darwin toolchain and the macOS SDK it links against are copied out of
`ghcr.io/goreleaser/goreleaser-osxcross`, not built here. That SDK is Apple's, and
its redistribution terms are not ours to interpret. GoReleaser already publishes it
in that form. Worth a human read before this image is made widely available.

## Licence

MIT for this repository, inherited from upstream. See `LICENSE`.

The image also redistributes GCC and binutils, which are GPLv3. Their
corresponding source is the `cross-make` submodule at the commit pinned here, plus
the tarballs cross-make downloads at the versions named in `cross-make/Makefile`.
