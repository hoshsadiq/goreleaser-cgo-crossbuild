#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-goreleaser-cgo-crossbuild:dev}"

# Inside the checkout, not /tmp: on macOS the container VM cannot see /tmp.
work="$repo/tmp/release-snapshot"

run_in_image() {
    docker run --rm --workdir /work --volume "$work:/work" \
        --volume "$repo/test/check-artifacts.sh:/check-artifacts.sh:ro" \
        "$IMAGE" "$@"
}

prepare_fixture() {
    rm -rf "$work"
    mkdir -p "$work"
    cp -R "$repo/test/fixture/." "$work/"

    git -C "$work" init -q
    git -C "$work" add -A
    git -C "$work" -c user.email=fixture@example.com -c user.name=fixture commit -qm fixture
}

check_mounted_pin() {
    local reported
    printf '[tools]\ngo = "1.26.6"\n' >"$work/mise.toml"

    reported="$(run_in_image go version)"
    case "$reported" in
        *1.26.6*) echo "mounted mise.toml wins: $reported" ;;
        *) echo "expected the mounted mise.toml's Go, got: $reported" >&2; exit 1 ;;
    esac
}

cleanup() {
    [ "${KEEP:-0}" = "1" ] && return 0
    # GoReleaser writes as root in the container, so its output is root-owned here
    # and the host cannot remove it. Clear the mount from inside first, then the
    # directory itself; a failure to tidy up must not fail the run.
    run_in_image sh -c 'rm -rf /work/* /work/.[!.]*' >/dev/null 2>&1 || true
    rm -rf "$work" 2>/dev/null || true
}

main() {
    prepare_fixture
    check_mounted_pin
    run_in_image goreleaser release --snapshot --clean
    run_in_image bash /check-artifacts.sh
    cleanup
}

main "$@"
