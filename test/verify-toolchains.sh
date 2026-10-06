#!/usr/bin/env bash
set -euo pipefail

failures=0
workdir=""

fail() {
    local label="$1"
    shift
    printf 'FAIL  %-16s %s\n' "$label" "$*"
    failures=$((failures + 1))
}

pass() {
    local label="$1"
    shift
    printf 'ok    %-16s %s\n' "$label" "$*"
}

cleanup() {
    [ -n "$workdir" ] && rm -rf "$workdir"
}

write_sources() {
    workdir="$(mktemp -d)"
    trap cleanup EXIT

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
}

# compile <label> <compiler> <source> <output> [flags...]
compile() {
    local label="$1" compiler="$2" source="$3" output="$4"
    shift 4

    if [ ! -x "$compiler" ]; then
        fail "$label" "$compiler is not an executable file"
        return 1
    fi

    # shellcheck disable=SC2086 # the flags argument is a word list
    if ! "$compiler" "$@" -O2 -o "$output" "$source" >"$output.log" 2>&1; then
        fail "$label" "could not compile"
        head -10 "$output.log" | sed 's/^/        /'
        return 1
    fi
}

# check_binary <label> <binary> <expected substring>...
check_binary() {
    local label="$1" binary="$2" described want
    shift 2

    if [ "$#" -eq 0 ]; then
        fail "$label" "the table row lists no expectations"
        return
    fi

    described="$(file -b "$binary")"

    local missing=()
    for want in "$@"; do
        [ -n "$want" ] || continue
        printf '%s' "$described" | grep -qF "$want" || missing+=("$want")
    done

    if [ "${#missing[@]}" -ne 0 ]; then
        fail "$label" "$described (missing: ${missing[*]})"
        return
    fi
    pass "$label" "$described"
}

split_expectations() {
    local expectations="$1"
    tr ',' '\n' <<<"$expectations" | grep -v '^$' || true
}

# check_target <label> <cc> <cxx> <flags> <extension> <expectations>
check_target() {
    local label="$1" cc="$2" cxx="$3" flags="$4" extension="$5" expectations="$6"
    local flags_list=() expectations_list=()

    read -ra flags_list <<<"$flags"
    mapfile -t expectations_list < <(split_expectations "$expectations")

    local stem="${label//\//-}"
    if compile "$label (c)" "$cc" "$workdir/hello.c" "$workdir/$stem$extension" ${flags_list[@]+"${flags_list[@]}"}; then
        check_binary "$label (c)" "$workdir/$stem$extension" ${expectations_list[@]+"${expectations_list[@]}"}
    fi

    if compile "$label (c++)" "$cxx" "$workdir/hello.cc" "$workdir/$stem-cxx$extension" ${flags_list[@]+"${flags_list[@]}"}; then
        check_binary "$label (c++)" "$workdir/$stem-cxx$extension" ${expectations_list[@]+"${expectations_list[@]}"}
    fi
}

check_targets() {
    # label|cc|cxx|flags|extension|expected substrings
    while IFS='|' read -r label cc cxx flags extension expectations; do
        [ -n "$label" ] || continue
        check_target "$label" "$cc" "$cxx" "$flags" "$extension" "$expectations"
    done <<'TARGETS'
linux/amd64|/usr/local/bin/x86_64-linux-musl-gcc|/usr/local/bin/x86_64-linux-musl-g++|-static||ELF 64-bit,x86-64,static
linux/arm64|/usr/local/bin/aarch64-linux-musl-gcc|/usr/local/bin/aarch64-linux-musl-g++|-static||ELF 64-bit,ARM aarch64,static
linux/386|/usr/local/bin/i686-linux-musl-gcc|/usr/local/bin/i686-linux-musl-g++|-static||ELF 32-bit,Intel 80386,static
darwin/amd64|/usr/local/osxcross/bin/o64-clang|/usr/local/osxcross/bin/o64-clang++|||Mach-O 64-bit,x86_64
darwin/arm64|/usr/local/osxcross/bin/oa64-clang|/usr/local/osxcross/bin/oa64-clang++|||Mach-O 64-bit,arm64
windows/amd64|/llvm-mingw/bin/x86_64-w64-mingw32-gcc|/llvm-mingw/bin/x86_64-w64-mingw32-g++||.exe|PE32+ executable,x86-64
windows/arm64|/llvm-mingw/bin/aarch64-w64-mingw32-gcc|/llvm-mingw/bin/aarch64-w64-mingw32-g++||.exe|PE32+ executable,Aarch64
TARGETS
}

# A musl compiler that reached the host's glibc headers would still link a
# hello-world, so the search list is checked directly, indentation and all.
check_sysroots() {
    local triple cc sysroot search

    for triple in x86_64-linux-musl aarch64-linux-musl i686-linux-musl; do
        cc="/usr/local/bin/${triple}-gcc"
        sysroot="$("$cc" -print-sysroot 2>/dev/null || true)"

        if [ -z "$sysroot" ] || [ ! -d "$sysroot" ]; then
            fail "$triple" "sysroot \"$sysroot\" does not exist"
            continue
        fi

        search="$("$cc" -E -Wp,-v -xc /dev/null 2>&1 | sed -n '/search starts here:/,/End of search list/p')"

        if ! printf '%s' "$search" | grep -q "$triple"; then
            fail "$triple" "include search list never mentions $triple"
            printf '%s\n' "$search" | head -10 | sed 's/^/        /'
        elif printf '%s' "$search" | grep -qE '^[[:space:]]*/usr/(local/)?include(/|$)'; then
            fail "$triple" "include search list reaches the host's headers"
            printf '%s\n' "$search" | head -10 | sed 's/^/        /'
        else
            pass "$triple" "sysroot $sysroot, host headers not on the search list"
        fi
    done
}

# Asserted, not printed: a pin the image stopped honouring would otherwise pass.
check_tools() {
    local versions_file=/etc/goreleaser-cgo-crossbuild-versions
    local tool pin args reported

    if [ ! -r "$versions_file" ]; then
        fail pins "$versions_file is missing"
        return
    fi

    while IFS='=' read -r tool pin; do
        [ -n "$tool" ] || continue

        args=(version)
        [ "$tool" = goreleaser ] && args=(--version)

        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "$tool" "not on PATH"
            continue
        fi

        reported="$("$tool" "${args[@]}" 2>&1 || true)"
        if printf '%s' "$reported" | grep -qF "${pin#v}"; then
            pass "$tool" "$(printf '%s' "$reported" | grep -m1 -E '[0-9]+\.[0-9]+' | sed 's/^ *//' | cut -c1-44) (pinned $pin)"
        else
            fail "$tool" "pinned $pin but reports: $(printf '%s' "$reported" | head -2 | tr '\n' ' ' | cut -c1-70)"
        fi
    done <"$versions_file"
}

main() {
    write_sources
    check_targets
    check_sysroots
    echo
    check_tools
    echo

    if [ "$failures" -ne 0 ]; then
        echo "$failures check(s) failed"
        exit 1
    fi
    echo "all toolchains usable"
}

main "$@"
