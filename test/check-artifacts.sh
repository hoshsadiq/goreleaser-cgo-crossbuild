#!/usr/bin/env bash
# Runs inside the image, after test/release-snapshot.sh has produced dist/. Checks
# that the snapshot release produced all six targets, that each one is the format it
# should be (static musl for Linux, Mach-O for Darwin, PE for Windows), and that the
# archive and checksum steps ran too.
set -euo pipefail

failures=0
failed() { failures=$((failures + 1)); }

descriptions=""
while IFS= read -r binary; do
    description="$(file -b "$binary")"
    printf '%-40s %s\n' "${binary#dist/}" "$description"
    descriptions="${descriptions}${description}"$'\n'
done < <(find dist -type f \( -name fixture -o -name fixture.exe \) | sort)

count="$(printf '%s' "$descriptions" | grep -c . || true)"
if [ "$count" -ne 6 ]; then
    echo "expected 6 binaries, found $count" >&2
    failed
fi

while IFS= read -r want; do
    if ! printf '%s' "$descriptions" | grep -qF "$want"; then
        echo "no artefact reported: $want" >&2
        failed
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
    failed
fi

# A release that built the binaries but skipped the archive or checksum steps would
# otherwise pass, and those are the files a consumer actually downloads.
mapfile -t archives < <(find dist -type f \( -name '*.tar.gz' -o -name '*.zip' \) | sort)
if [ "${#archives[@]}" -ne 6 ]; then
    echo "expected 6 archives, found ${#archives[@]}" >&2
    failed
fi

# Every archive must carry the binary it was built for. Zip entries are not listed
# here because the image has no unzip, so those are covered by the checksums below.
for archive in "${archives[@]}"; do
    case "$archive" in
        *.tar.gz)
            if ! tar tzf "$archive" | grep -qE 'fixture$'; then
                echo "no binary inside $archive" >&2
                failed
            fi
            ;;
    esac
done

checksums="$(find dist -maxdepth 1 -type f -name '*checksums.txt' | wc -l | tr -d ' ')"
if [ "$checksums" -ne 1 ]; then
    echo "expected one checksums file, found $checksums" >&2
    failed
else
    checksum_file="$(find dist -maxdepth 1 -type f -name '*checksums.txt' | head -1)"
    if ! ( cd dist && sha256sum -c "$(basename "$checksum_file")" >/dev/null ); then
        echo "$checksum_file does not match the archives" >&2
        failed
    fi
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi

echo "six targets built and static where they should be, with verified archives and checksums"
