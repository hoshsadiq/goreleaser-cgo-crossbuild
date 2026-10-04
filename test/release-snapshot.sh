#!/usr/bin/env bash
# Runs a six-target cgo release inside the image and inspects the artefacts, so a
# green run means the whole path works: GoReleaser, the Go toolchain, cgo, and every
# C compiler. test/verify-toolchains.sh proves the compilers; this proves they are
# wired into a release.
#
#   mise run image:release
set -euo pipefail

IMAGE="${IMAGE:-goreleaser-cgo-crossbuild:dev}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# GoReleaser wants a git repository, and the container runtime needs to see the
# directory, so the fixture is copied inside the checkout rather than to /tmp:
# on macOS a /tmp path is not visible to the container VM.
work="$repo/tmp/release-snapshot"
rm -rf "$work"
mkdir -p "$work"
cp -R "$repo/test/fixture/." "$work/"
git -C "$work" init -q
git -C "$work" add -A
git -C "$work" -c user.email=fixture@example.com -c user.name=fixture commit -qm fixture

# The image's central promise is that a repository mounted at /work keeps working,
# including its own tool pins, so pin an older Go and prove that is what ran.
printf '[tools]\ngo = "1.26.6"\n' >"$work/mise.toml"
reported="$(docker run --rm --workdir /work --volume "$work:/work" "$IMAGE" go version)"
case "$reported" in
    *1.26.6*) echo "mounted mise.toml wins: $reported" ;;
    *) echo "expected the mounted mise.toml's Go, got: $reported" >&2; exit 1 ;;
esac

docker run --rm --workdir /work --volume "$work:/work" "$IMAGE" \
    goreleaser release --snapshot --clean

docker run --rm --workdir /work --volume "$work:/work" --volume "$repo/test/check-artifacts.sh:/check-artifacts.sh:ro" \
    "$IMAGE" bash /check-artifacts.sh

# The fixture copy and its ~20 MB of artefacts are only useful while debugging.
if [ "${KEEP:-0}" != "1" ]; then
    rm -rf "$work"
fi
