#!/usr/bin/env bash
set -euo pipefail

# Every target the fixture asks for: static musl ELF for linux, Mach-O for darwin,
# PE for windows. The count is one per target because a missing artefact should
# fail rather than pass silently.
targets=7
static_targets=3

failures=0
failed() { failures=$((failures + 1)); }

report_binaries() {
    local binary description
    descriptions=""

    while IFS= read -r binary; do
        description="$(file -b "$binary")"
        printf '%-40s %s\n' "${binary#dist/}" "$description"
        descriptions+="$description"$'\n'
    done < <(find dist -type f \( -name fixture -o -name fixture.exe \) | sort)
}

check_binary_count() {
    local count
    count="$(grep -c . <<<"$descriptions" || true)"

    if [ "$count" -ne "$targets" ]; then
        echo "expected $targets binaries, found $count" >&2
        failed
    fi
}

check_formats() {
    local want
    while IFS= read -r want; do
        if ! grep -qF "$want" <<<"$descriptions"; then
            echo "no artefact reported: $want" >&2
            failed
        fi
    done <<'WANT'
ELF 64-bit
ELF 32-bit
static
ARM aarch64
Mach-O 64-bit x86_64 executable
Mach-O 64-bit arm64 executable
PE32+ executable (console) x86-64
PE32+ executable (console) Aarch64
WANT

    local static_count
    static_count="$(grep -c 'static' <<<"$descriptions" || true)"
    if [ "$static_count" -ne "$static_targets" ]; then
        echo "expected $static_targets static linux binaries, found $static_count" >&2
        failed
    fi
}

check_archives() {
    local archives=() archive
    mapfile -t archives < <(find dist -type f \( -name '*.tar.gz' -o -name '*.zip' \) | sort)

    if [ "${#archives[@]}" -ne "$targets" ]; then
        echo "expected $targets archives, found ${#archives[@]}" >&2
        failed
    fi

    # Only the tarballs: the image has no unzip, and the checksums below cover the rest.
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
}

check_checksums() {
    local checksums checksum_file
    mapfile -t checksums < <(find dist -maxdepth 1 -type f -name '*checksums.txt')

    if [ "${#checksums[@]}" -ne 1 ]; then
        echo "expected one checksums file, found ${#checksums[@]}" >&2
        failed
        return
    fi

    checksum_file="${checksums[0]}"
    if ! ( cd dist && sha256sum -c "$(basename "$checksum_file")" >/dev/null ); then
        echo "$checksum_file does not match the archives" >&2
        failed
    fi
}

main() {
    report_binaries
    check_binary_count
    check_formats
    check_archives
    check_checksums

    if [ "$failures" -ne 0 ]; then
        echo "$failures check(s) failed"
        exit 1
    fi
    echo "$targets targets built, $static_targets of them static, with verified archives and checksums"
}

main "$@"
