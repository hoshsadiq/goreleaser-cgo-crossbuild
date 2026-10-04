# goreleaser-cgo-crossbuild

A container image with the C toolchains needed to cross-build one Go binary with
`CGO_ENABLED=1` for Linux, macOS and Windows on amd64 and arm64, plus mise with
Go, GoReleaser, cosign and syft already installed.

It exists because a cgo build needs a C compiler per target, and putting all of
them in one image means a single `goreleaser release` can produce every target
instead of shelling out per platform.

Forked from [goreleaser/goreleaser-cross-toolchains](https://github.com/goreleaser/goreleaser-cross-toolchains),
which is where the mingw, llvm-mingw and osxcross recipes come from and where
upstream toolchain bumps land.

## What is inside

| `GOOS/GOARCH`   | `CC`                                          | `CXX`                                          |
| --------------- | --------------------------------------------- | ---------------------------------------------- |
| `linux/amd64`   | `/usr/local/bin/x86_64-linux-musl-gcc`        | `/usr/local/bin/x86_64-linux-musl-g++`         |
| `linux/arm64`   | `/usr/local/bin/aarch64-linux-musl-gcc`       | `/usr/local/bin/aarch64-linux-musl-g++`        |
| `darwin/amd64`  | `/usr/local/osxcross/bin/o64-clang`           | `/usr/local/osxcross/bin/o64-clang++`          |
| `darwin/arm64`  | `/usr/local/osxcross/bin/oa64-clang`          | `/usr/local/osxcross/bin/oa64-clang++`         |
| `windows/amd64` | `/llvm-mingw/bin/x86_64-w64-mingw32-gcc`      | `/llvm-mingw/bin/x86_64-w64-mingw32-g++`       |
| `windows/arm64` | `/llvm-mingw/bin/aarch64-w64-mingw32-gcc`     | `/llvm-mingw/bin/aarch64-w64-mingw32-g++`      |

The mingw and osxcross toolchains are multi-target, so `i686`, `armv7` and
`o32-clang` are there too, and they are on `PATH` under their usual names.

The base is `ubuntu:noble` (glibc). That is not incidental: osxcross does not
run on musl. The musl toolchains are built in an Alpine stage and copied in,
which works because cross-make links their executables statically
(`litecross/Makefile.gcc` sets `STAT = -static --static` unless the build host is
darwin).

On `PATH`, ahead of everything else, are mise shims for Go, GoReleaser, cosign
and syft. A repository mounted into the container that carries its own
`mise.toml` overrides those versions and mise installs whatever it asks for.
`MISE_TRUSTED_CONFIG_PATHS` is set to `/`, so no config needs explicit trusting.

## Using it

Pin by digest. The tag in a `FROM` line is for humans and the digest is what
actually decides which image runs.

```
ghcr.io/hoshsadiq/goreleaser-cgo-crossbuild@sha256:<digest>
```

GoReleaser picks the compiler per target through `CC_<os>_<arch>` and
`CXX_<os>_<arch>` environment variables:

```yaml
builds:
  - env:
      - CGO_ENABLED=1
      - 'CC={{ index .Env (print "CC_" .Os "_" .Arch) }}'
      - 'CXX={{ index .Env (print "CXX_" .Os "_" .Arch) }}'
```

Static linking for Linux goes in `ldflags`, alongside the toolchain choice:

```yaml
      - '{{ if eq .Os "linux" }}-extldflags "-static"{{ end }}'
```

The digest of the last successful build is printed on the workflow run summary
under the *Report the digest* step.

## Checking an image

`mise run image:verify` builds the image for the host architecture and then runs
`test/verify-toolchains.sh` inside it, which compiles a hello-world with each of
the six toolchains and checks the file format of each result. Use it after any
change to the Dockerfile or the `cross-make` submodule, before pinning a new
digest anywhere.

## Build time

A cold build takes one to two hours. The two musl toolchains dominate: cross-make
compiles GCC and binutils once per musl target, and the mingw and osxcross stages
are downloads by comparison. Buildx caching turns this into minutes when the
musl stage is untouched, but any change to the `cross-make` submodule commit or
to `MUSL_TARGETS` invalidates that layer and the hour returns. The weekly
scheduled rebuild in `.github/workflows/image.yml` is there to catch upstream
toolchain moves, and it is the slow kind of run.

## The macOS SDK

The Darwin toolchain, and the macOS SDK it links against, are copied out of
`ghcr.io/goreleaser/goreleaser-osxcross`, not built here. That SDK is Apple's and
its redistribution terms are not ours to interpret. GoReleaser already publishes
it in that form; anyone using this image is bound by the same Apple licence terms
as anyone using theirs. Worth a human read before this image is made public.

## Licence

MIT, inherited from the upstream repository. See `LICENSE`.
