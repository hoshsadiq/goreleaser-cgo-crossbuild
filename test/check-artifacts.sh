#!/usr/bin/env bash
# Runs inside the image, after test/release-snapshot.sh has produced dist/. Checks
# that the snapshot release produced all six targets and that each one is the format
# it should be: static musl for Linux, Mach-O for Darwin, PE for Windows.
set -euo pipefail

descriptions=""
for binary in $(find dist -type f \( -name fixture -o -name fixture.exe \) | sort); do
    description="$(file -b "$binary")"
    printf '%-40s %s\n' "${binary#dist/}" "$description"
    descriptions="${descriptions}${description}"$'\n'
done

count="$(printf '%s' "$descriptions" | grep -c . || true)"
if [ "$count" -ne 6 ]; then
    echo "expected 6 binaries, found $count" >&2
    exit 1
fi

while IFS= read -r want; do
    if ! printf '%s' "$descriptions" | grep -qF "$want"; then
        echo "no artefact reported: $want" >&2
        exit 1
    fi
done <<'WANT'
ELF 64-bit
static
ARM aarch64
Mach-O 64-bit x86_64 executable
Mach-O 64-bit arm64 executable
PE32+ executable (console) x86-64
PE32+ executable (console) Aarch64
WANT

static="$(printf '%s' "$descriptions" | grep -c 'static' || true)"
if [ "$static" -ne 2 ]; then
    echo "expected the two linux binaries to be static, found $static" >&2
    exit 1
fi

echo "six targets built, two of them static musl"
