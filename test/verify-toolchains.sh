#!/usr/bin/env bash
# Compiles a hello-world with every toolchain the image promises, in C and C++,
# and inspects the results. Run it inside the image: an image build proves the
# toolchains unpack, this proves they compile, link and find their own headers.
#
#   mise run image:verify
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

cat >"$workdir/hello.cc" <<'EOF'
#include <cstdio>
#include <string>

int main() {
    std::string greeting = "hello";
    std::printf("%s\n", greeting.c_str());
    return 0;
}
EOF

failures=0
failed() { failures=$((failures + 1)); }

# compile <label> <compiler> <source> <output> [flags...]
compile() {
    local label="$1" compiler="$2" source="$3" output="$4"
    shift 4

    if [ ! -x "$compiler" ]; then
        printf 'FAIL  %-16s %s is not an executable file\n' "$label" "$compiler"
        failed
        return 1
    fi

    # shellcheck disable=SC2086 # the flags argument is a deliberate word list
    if ! "$compiler" "$@" -O2 -o "$output" "$source" >"$output.log" 2>&1; then
        printf 'FAIL  %-16s could not compile:\n' "$label"
        # head first, so sed never sees a closed pipe under pipefail.
        head -10 "$output.log" | sed 's/^/        /'
        failed
        return 1
    fi
}

# check <label> <binary> <expectation>...
# Every expectation must appear in `file`'s description of the binary. A row with
# no expectations is a failure, not a free pass.
check() {
    local label="$1" binary="$2" described
    shift 2

    if [ "$#" -eq 0 ]; then
        printf 'FAIL  %-16s the table row lists no expectations\n' "$label"
        failed
        return
    fi

    described="$(file -b "$binary")"
    printf 'ok    %-16s %s\n' "$label" "$described"

    local want
    for want in "$@"; do
        [ -n "$want" ] || continue
        if ! printf '%s' "$described" | grep -qF "$want"; then
            printf 'FAIL  %-16s expected "%s" in: %s\n' "$label" "$want" "$described"
            failed
        fi
    done
}

# One row per target: label, C compiler, C++ compiler, flags, output extension,
# then the strings `file` is expected to report. The paths are the ones README.md
# documents, so a wrong install prefix fails here rather than in a consumer. The
# windows rows need the extension because the mingw driver appends .exe to
# whatever -o says.
#
# The linux rows expect "static" rather than "statically linked": these toolchains
# default to PIE, so -static produces `static-pie linked`. That is an ordinary
# static binary, and it is what musl toolchains ship, but the wording differs.
while IFS='|' read -r label cc cxx flags extension expectations; do
    [ -n "$label" ] || continue

    expect=()
    while IFS= read -r want; do
        [ -n "$want" ] && expect+=("$want")
    done < <(printf '%s\n' "$expectations" | tr ',' '\n')

    # The flags column is a word list, so split it rather than globbing it.
    flag_args=()
    read -ra flag_args <<<"$flags"

    c_binary="$workdir/${label//\//-}$extension"
    cxx_binary="$workdir/${label//\//-}-cxx$extension"

    if compile "$label (c)" "$cc" "$workdir/hello.c" "$c_binary" ${flag_args[@]+"${flag_args[@]}"}; then
        check "$label (c)" "$c_binary" ${expect[@]+"${expect[@]}"}
    fi

    if compile "$label (c++)" "$cxx" "$workdir/hello.cc" "$cxx_binary" ${flag_args[@]+"${flag_args[@]}"}; then
        check "$label (c++)" "$cxx_binary" ${expect[@]+"${expect[@]}"}
    fi
done <<'TARGETS'
linux/amd64|/usr/local/bin/x86_64-linux-musl-gcc|/usr/local/bin/x86_64-linux-musl-g++|-static||ELF 64-bit,x86-64,static
linux/arm64|/usr/local/bin/aarch64-linux-musl-gcc|/usr/local/bin/aarch64-linux-musl-g++|-static||ELF 64-bit,ARM aarch64,static
darwin/amd64|/usr/local/osxcross/bin/o64-clang|/usr/local/osxcross/bin/o64-clang++|||Mach-O 64-bit,x86_64
darwin/arm64|/usr/local/osxcross/bin/oa64-clang|/usr/local/osxcross/bin/oa64-clang++|||Mach-O 64-bit,arm64
windows/amd64|/llvm-mingw/bin/x86_64-w64-mingw32-gcc|/llvm-mingw/bin/x86_64-w64-mingw32-g++||.exe|PE32+ executable,x86-64
windows/arm64|/llvm-mingw/bin/aarch64-w64-mingw32-gcc|/llvm-mingw/bin/aarch64-w64-mingw32-g++||.exe|PE32+ executable,Aarch64
TARGETS

# A musl compiler that found the host's glibc headers would still link a
# hello-world and still pass the rows above, so check the include search list
# itself: it must reach into the toolchain's own sysroot and must not reach the
# host's /usr/include. This is the check that catches a sysroot that did not
# survive the move from the builder's output directory into /usr/local.
for triple in x86_64-linux-musl aarch64-linux-musl; do
    cc="/usr/local/bin/${triple}-gcc"
    sysroot="$("$cc" -print-sysroot 2>/dev/null || true)"

    if [ -z "$sysroot" ] || [ ! -d "$sysroot" ]; then
        printf 'FAIL  %-16s sysroot "%s" does not exist\n' "$triple" "$sysroot"
        failed
        continue
    fi

    search="$("$cc" -E -Wp,-v -xc /dev/null 2>&1 | sed -n '/search starts here:/,/End of search list/p')"

    if ! printf '%s' "$search" | grep -q "$triple"; then
        printf 'FAIL  %-16s include search list never mentions %s:\n' "$triple" "$triple"
        printf '%s\n' "$search" | head -10 | sed 's/^/        /'
        failed
    # gcc indents every path in that list, so an anchored match needs the spaces.
    elif printf '%s' "$search" | grep -qE '^[[:space:]]*/usr/(local/)?include(/|$)'; then
        printf 'FAIL  %-16s include search list reaches the host glibc headers at /usr/include:\n' "$triple"
        printf '%s\n' "$search" | head -10 | sed 's/^/        /'
        failed
    else
        printf 'ok    %-16s sysroot %s, host headers not on the search list\n' "$triple" "$sysroot"
    fi
done

echo
# The Dockerfile records what it pinned in this file, so the versions are asserted
# rather than merely printed: a pin that stopped being honoured would otherwise pass.
versions_file=/etc/goreleaser-cgo-crossbuild-versions
if [ ! -r "$versions_file" ]; then
    printf 'FAIL  %-16s %s is missing\n' pins "$versions_file"
    failed
else
    while IFS='=' read -r tool pin; do
        [ -n "$tool" ] || continue

        # goreleaser spells it --version; the rest take a version subcommand.
        args=(version)
        [ "$tool" = goreleaser ] && args=(--version)

        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'FAIL  %-16s not on PATH\n' "$tool"
            failed
            continue
        fi

        # These tools print an ASCII banner before the version, and some spell the
        # pin with a leading v, so match on the version without it.
        reported="$("$tool" "${args[@]}" 2>&1 || true)"
        if printf '%s' "$reported" | grep -qF "${pin#v}"; then
            printf 'ok    %-16s %s (pinned %s)\n' "$tool" "$(printf '%s' "$reported" | grep -m1 -E '[0-9]+\.[0-9]+' | sed 's/^ *//' | cut -c1-44)" "$pin"
        else
            printf 'FAIL  %-16s pinned %s but reports: %s\n' "$tool" "$pin" "$(printf '%s' "$reported" | head -2 | tr '\n' ' ' | cut -c1-70)"
            failed
        fi
    done <"$versions_file"
fi

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all toolchains usable"
