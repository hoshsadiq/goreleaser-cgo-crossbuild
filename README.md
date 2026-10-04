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

The base is `ubuntu:noble` (glibc). That is not incidental: the osxcross binaries
this image copies are linked against glibc and will not run on musl. The musl toolchains are built in an Alpine stage and copied in, which
works because cross-make links their executables statically
(`litecross/Makefile.gcc` sets `STAT = -static --static` unless the build host is
darwin).

The osxcross wrappers look up a bare `clang` on `PATH`, so the Darwin toolchain
depends on the llvm-mingw clang that comes later in `PATH`. `/llvm-mingw/bin`
cannot be dropped from `PATH` without breaking Darwin builds even though Darwin
never runs a Windows compiler.

Go also links an unstripped Darwin cgo build through `dsymutil`, so the final stage
installs `llvm` for it. Go asks the compiler driver for it
(`CC --print-prog-name=dsymutil`), which answers with osxcross's per-target name
under `/usr/local/osxcross/bin`, and that name is a symlink to the `dsymutil` in
this package. Without the package the symlink dangles, and an unstripped build
fails with `running dsymutil failed: exec: "dsymutil": executable file not found
in $PATH`. Either `-s` or `-w` in `ldflags` avoids the call: Go treats `-s` as
implying `-w` when `-w` was not given explicitly.

## Using it

Pin by digest, and verify the signature first. The tag in a `FROM` line or a
compose file is for humans; the digest is what decides which image runs.

```
cosign verify ghcr.io/hoshsadiq/goreleaser-cgo-crossbuild@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/hoshsadiq/goreleaser-cgo-crossbuild/\.github/workflows/image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

A run that can publish also pushes a single-architecture tag per architecture named
after the run id (`:<run-id>-amd64` and `:<run-id>-arm64`), merges those two
digests into an index, signs the index, and only then adds the release tags: on a
tag push `v1.2.3` that is `1.2.3` and `1.2`, and on the default branch (including
the weekly rebuild) `latest`, the date and `sha-<7>`. The `v` is dropped, so the
image tags do not match the git tag names.

The run-id tags are breadcrumbs showing which builds an index was assembled from.
They are unsigned, nothing should pin them, and nothing removes them.

Mount the repository you are releasing at `/work`. That is the working directory
and the only path whose mise configuration is trusted:

```
docker run --rm -it \
  --volume "$PWD:/work" --workdir /work \
  --env GITHUB_TOKEN \
  ghcr.io/hoshsadiq/goreleaser-cgo-crossbuild@sha256:<digest> \
  goreleaser release --clean
```

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
than failing, so a target you forgot to list is compiled with an empty `CC`. Here
that fails loudly rather than silently, because the image has no bare `gcc` on
`PATH`, but the error arrives from cgo rather than from GoReleaser.

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

That refusal is not confined to mise itself: with the mount elsewhere, the shims
stop resolving too, so `go`, `goreleaser`, `cosign` and `syft` all exit with the
trust error rather than falling back to the versions baked into the image. Mount
at `/work`.

`MISE_YES` is deliberately absent. On its own it answers mise's trust prompt for
any configuration anywhere, which would make the trusted-paths list pointless.
`MISE_SAFE` is also absent: it blocks `_.file` in `[env]`, which is how many
repositories (including the one this image was built for) load a `.env`, and it
does so silently.

`git config --system --add safe.directory /work` is set because the mount is owned
by the host user while the container is root, so git would otherwise refuse it as
a dubious ownership. A repository mounted somewhere else needs its own entry.

One assumption is worth naming: mise treats its own global configuration as
trusted by definition, and that is `/mise/config.toml` here, which is where the
pinned tools are recorded. Nothing should be mounted over `/mise`.

## Darwin deployment target

osxcross links against a default macOS deployment target older than the one Go
stamps its objects with, so a Darwin build logs

```
ld: warning: object file (/tmp/go-link-XXXX/go.o) was built for newer macOS version (13.0) than being linked (11.0)
```

Set `MACOSX_DEPLOYMENT_TARGET` in the build environment (as a GoReleaser `env`
entry) to silence it and to state the target your catalog requires.

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
fetched from the same repository over the git protocol instead, at the revision
cross-make's Makefile names, and written into its sources directory before `make`
runs. The revision is read from the recipe rather than pinned here, and the
content is checked against the sha256 values in the Dockerfile, since git's own
transport is unencrypted. If a cross-make bump moves the revision, that check
fails loudly instead of quietly using an older copy.

## Pinned versions

Every version is an ARG default at the top of the stages in `Dockerfile`, and
Renovate is configured to bump them along with the base image digests. That
assumes the Renovate app is installed on this repository: there is no Dependabot
config, so nothing else will move them, and with issues disabled the dependency
dashboard is switched off in `renovate.json`. Three of them cannot be bumped on
their own:

- `LLVM_MINGW_VERSION` has `LLVM_MINGW_SHA256_AMD64` and `LLVM_MINGW_SHA256_ARM64`
  beside it.
- `MISE_VERSION` has `MISE_SHA256_AMD64` and `MISE_SHA256_ARM64`.
- the two config scripts have `CONFIG_GUESS_SHA256` and `CONFIG_SUB_SHA256`. Their
  revision is read out of cross-make's Makefile at build time, so those two
  digests are what changes with it.

Neither project publishes checksums, so those values are the sha256 digests
GitHub reports for the release assets:

```
gh api repos/mstorsjo/llvm-mingw/releases/tags/<version> --jq '.assets[].digest'
gh api repos/jdx/mise/releases/tags/<version> --jq '.assets[].digest'
```

Renovate bumps the version values, but not the digests beside them, so a bump PR
arrives red until someone edits the matching digest. That is deliberate: it makes
the digest a decision rather than a side effect. A version bump without it fails
the build rather than fetching something new and unverified.

The `cross-make` submodule is pinned deliberately. It decides the GCC, binutils,
musl and Linux header versions and carries the musl patches, so bumping it changes
the Linux toolchain: read the versions in `cross-make/Makefile` and run the
toolchain check afterwards. The two config scripts are the one thing the recipe
fetches that the submodule pin does not cover, which is why they are pinned above
instead.

## What this image does not carry

The `goreleaser-cross` image it replaces is built on goreleaser's full toolchains
image, so it also has `python3`, `jq`, `wget`, `cmake`, `autoconf`, `automake`,
`bc`, `libtool`, `patch`, `mercurial`, `gdb`, `openssl` and glibc cross toolchains
for nine Debian architectures. None of that is here, and there is no `docker`
client or daemon either, so a GoReleaser `dockers:` or `dockers_v2:` block cannot
run in this image. A release whose `before.hooks` runs Python, `jq` or `cmake`
needs it added; a build that wants a glibc Linux binary rather than a static musl
one, or that publishes a container image, needs a different image.

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
