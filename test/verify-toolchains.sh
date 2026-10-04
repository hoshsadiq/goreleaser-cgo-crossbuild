#!/usr/bin/env bash
# Compiles hello-world with each of the six toolchains and inspects the result,
# so an image build proves the toolchains work rather than only that they unpack.
# Run it inside the image: see the image:verify mise task.
set -euo pipefail

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat >"$workdir/hello.c" <<'EOF'
#include <stdio.h>

int main(void) {
    puts("hello");
    return 0;
}
EOF

failures=0
failed() { failures=$((failures + 1)); }

# One row per target: label, compiler, extra compiler flags, output extension,
# then the strings `file` is expected to report. Quotes in the expectations are
# matched literally, so they may contain spaces and commas. The windows rows
# need the extension because the mingw driver appends .exe to whatever -o says.
#
#   linux/amd64|gcc|-static||ELF 64-bit,x86-64,statically linked
while IFS='|' read -r label compiler flags extension expectations; do
    [ -n "$label" ] || continue

    if ! command -v "$compiler" >/dev/null 2>&1; then
        printf 'FAIL  %-14s %s is not on PATH\n' "$label" "$compiler"
        failed
        continue
    fi

    binary="$workdir/${label//\//-}$extension"
    # shellcheck disable=SC2086 # flags is a deliberate word list
    if ! "$compiler" $flags -O2 -o "$binary" "$workdir/hello.c" >"$binary.log" 2>&1; then
        printf 'FAIL  %-14s could not compile:\n' "$label"
        sed 's/^/        /' "$binary.log" | head -10
        failed
        continue
    fi

    described="$(file -b "$binary")"
    printf 'ok    %-14s %s\n' "$label" "$described"

    while IFS= read -r want; do
        if ! printf '%s' "$described" | grep -qF "$want"; then
            printf 'FAIL  %-14s expected "%s" in: %s\n' "$label" "$want" "$described"
            failed
        fi
    done < <(printf '%s\n' "$expectations" | tr ',' '\n')
done <<'TARGETS'
linux/amd64|x86_64-linux-musl-gcc|-static||ELF 64-bit,x86-64,statically linked
linux/arm64|aarch64-linux-musl-gcc|-static||ELF 64-bit,ARM aarch64,statically linked
darwin/amd64|o64-clang|||Mach-O 64-bit,x86_64
darwin/arm64|oa64-clang|||Mach-O 64-bit,arm64
windows/amd64|x86_64-w64-mingw32-gcc||.exe|PE32+ executable,x86-64
windows/arm64|aarch64-w64-mingw32-gcc||.exe|PE32+ executable,Aarch64
TARGETS

echo
# goreleaser spells it --version; the rest take a version subcommand.
for tool in mise go goreleaser cosign syft; do
    args=(version)
    [ "$tool" = goreleaser ] && args=(--version)

    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'FAIL  %-14s not on PATH\n' "$tool"
        failed
        continue
    fi

    # All of these print an ASCII banner before the version, so take the first
    # line that looks like a version rather than the first line.
    reported="$("$tool" "${args[@]}" 2>&1 | grep -m1 -E '[0-9]+\.[0-9]+' | sed 's/^ *//' | cut -c1-60)" || true
    printf 'ok    %-14s %s\n' "$tool" "${reported:-present, no version line}"
done

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all toolchains usable"
