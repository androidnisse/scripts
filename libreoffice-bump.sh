#!/usr/bin/env bash
# Copyright (c) 2026, androidnisse; SPDX-License-Identifier: BSD-2-Clause
set -uo pipefail
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_YML="${SCRIPT_DIR}/package.yml"
DW_BASE="https://download.documentfoundation.org/libreoffice/src"
GH_RAW="https://raw.githubusercontent.com/LibreOffice/core"
DEP_HOST='dev-www\.libreoffice\.org'
 
if [[ ! -f "$PACKAGE_YML" ]]; then
    echo "Error: package.yml not found at ${PACKAGE_YML}"
    exit 1
fi
 
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
 
CHANGED=0
declare -A LST_TAR=() LST_SHA=()
 
# ---------------------------------------------------------------- helpers
 
esc() { sed -e 's/[]\/$*.^|[&]/\\&/g' <<<"$1"; }
 
current_version() { grep -oP '^version\s*:\s*\K\S+' "$PACKAGE_YML"; }
current_release() { grep -oP '^release\s*:\s*\K[0-9]+' "$PACKAGE_YML"; }
 
bump_release() {
    local cur new
    cur=$(current_release)
    new=$((cur + 1))
    sed -i "s/^release\s*:.*$/release    : ${new}/" "$PACKAGE_YML"
    echo "Release ${cur} -> ${new}"
}
 
# Normalise a tarball name to a version-independent key:
#   pdfium-8073.tar.bz2 -> pdfium, <md5>-xsltml_2.1.2.zip -> xsltml
stem() {
    local n="${1##*/}"
    n="${n,,}"
    n=$(sed -E \
        -e 's/^[0-9a-f]{32,64}-//' \
        -e 's/\.(tar\.[a-z0-9]+|tgz|zip|jar|ttf)$//' \
        -e 's/[-_]m?[0-9].*$//' <<<"$n")
    echo "$n"
}
 
# sha256 of a DocumentFoundation tarball: use the published .sha256 file,
# fall back to downloading + hashing.
fetch_sha() {
    local url=$1 s
    s=$(curl -fsSL "${url}.sha256" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ $s =~ ^[a-f0-9]{64}$ ]]; then
        echo "$s"
        return 0
    fi
    curl -fsSL "$url" | sha256sum | awk '{print $1}'
}
 
# Load download.lst for a given LibreOffice version into LST_TAR / LST_SHA
load_lst() {
    local ver=$1 f="$TMP/download.lst" line k s
    local -A kt=() ks=()
    LST_TAR=(); LST_SHA=()
 
    echo "Fetching download.lst for libreoffice-${ver}..."
    if ! curl -fsSL "${GH_RAW}/libreoffice-${ver}/download.lst" -o "$f" 2>/dev/null; then
        echo "  GitHub tag not found, extracting from source tarball (big download)..."
        curl -fsSL "${DW_BASE}/${ver%.*}/libreoffice-${ver}.tar.xz" \
            | tar -xJO "libreoffice-${ver}/download.lst" >"$f" || {
            echo "Error: could not obtain download.lst"
            return 1
        }
    fi
 
    while IFS= read -r line; do
        if [[ $line =~ ^(export[[:space:]]+)?([A-Z0-9_]+)_SHA256SUM[[:space:]]*:=[[:space:]]*([a-f0-9]{64}) ]]; then
            ks[${BASH_REMATCH[2]}]=${BASH_REMATCH[3]}
        elif [[ $line =~ ^(export[[:space:]]+)?([A-Z0-9_]+)_(TARBALL|JAR)[[:space:]]*:=[[:space:]]*([^[:space:]]+) ]]; then
            kt[${BASH_REMATCH[2]}]=${BASH_REMATCH[4]}
        fi
    done <"$f"
 
    for k in "${!kt[@]}"; do
        [[ -n ${ks[$k]:-} ]] || continue
        s=$(stem "${kt[$k]}")
        LST_TAR[$s]=${kt[$k]}
        LST_SHA[$s]=${ks[$k]}
    done
 
    if ((${#LST_TAR[@]} == 0)); then
        echo "Error: could not parse any entries from download.lst"
        return 1
    fi
}
 
# ---------------------------------------------------------------- actions
 
update_lo() {
    local cur_ver cur_minor cur_rel new_ver new_minor new_rel base f sha
    cur_ver=$(current_version)
    cur_minor=$(cut -d. -f1-3 <<<"$cur_ver")
    cur_rel=$(current_release)
 
    echo "Current version: ${cur_ver}"
    echo "Current release: ${cur_rel}"
    read -rp "Enter new version: " new_ver
    if [[ ! $new_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: version must look like 26.8.4.1"
        return 1
    fi
 
    new_minor=$(cut -d. -f1-3 <<<"$new_ver")
    new_rel=$((cur_rel + 1))
    base="${DW_BASE}/${new_minor}"
 
    local files=(
        "libreoffice-${new_ver}.tar.xz"
        "libreoffice-dictionaries-${new_ver}.tar.xz"
        "libreoffice-help-${new_ver}.tar.xz"
        "libreoffice-translations-${new_ver}.tar.xz"
    )
 
    # Fetch all hashes (in parallel) BEFORE touching package.yml
    echo "Fetching checksums..."
    for f in "${files[@]}"; do
        ( fetch_sha "${base}/${f}" >"$TMP/$f.sha" 2>/dev/null || touch "$TMP/$f.fail" ) &
    done
    wait
 
    for f in "${files[@]}"; do
        if [[ -e "$TMP/$f.fail" ]] || [[ ! $(cat "$TMP/$f.sha" 2>/dev/null) =~ ^[a-f0-9]{64}$ ]]; then
            echo "Error: could not get checksum for ${f}; package.yml untouched"
            return 1
        fi
    done
 
    echo "Bumping ${cur_ver} -> ${new_ver}, release ${cur_rel} -> ${new_rel}"
    sed -i "s/^version\s*:.*$/version    : ${new_ver}/" "$PACKAGE_YML"
    sed -i "s/^release\s*:.*$/release    : ${new_rel}/" "$PACKAGE_YML"
    sed -i "s/$(esc "$cur_ver")/${new_ver}/g" "$PACKAGE_YML"
    sed -i "s/$(esc "$cur_minor")/${new_minor}/g" "$PACKAGE_YML"
 
    for f in "${files[@]}"; do
        sha=$(<"$TMP/$f.sha")
        echo "  ${f}: ${sha}"
        sed -i "s|\(.*$(esc "$f").*: \)[a-f0-9]*|\1${sha}|" "$PACKAGE_YML"
    done
    echo "LibreOffice version updated."
}
 
# Sync every dev-www.libreoffice.org source in package.yml against download.lst
sync_deps() {
    local ver=$1 line url sha old_name dir s new_name new_sha
    local -A seen=()
    CHANGED=0
 
    load_lst "$ver" || return 1
 
    local -a lines
    mapfile -t lines < <(grep -P "^\s+- https://${DEP_HOST}/\S+ : [a-f0-9]{64}\s*$" "$PACKAGE_YML")
 
    for line in "${lines[@]}"; do
        url=$(awk '{print $2}' <<<"$line")
        s=$(stem "$url")
        seen[$s]=$(( ${seen[$s]:-0} + 1 ))
    done
 
    for line in "${lines[@]}"; do
        url=$(awk '{print $2}' <<<"$line")
        sha=$(awk '{print $4}' <<<"$line")
        old_name=${url##*/}
        dir=${url%/*}
        s=$(stem "$url")
 
        if ((${seen[$s]} > 1)); then
            echo "  SKIP  ${old_name} (several entries share stem '${s}', handle manually)"
            continue
        fi
        if [[ -z ${LST_TAR[$s]:-} ]]; then
            echo "  ??    ${old_name} (not in download.lst, maybe removed upstream)"
            continue
        fi
 
        new_name=${LST_TAR[$s]}
        new_sha=${LST_SHA[$s]}
        if [[ $new_name == "$old_name" && $new_sha == "$sha" ]]; then
            continue
        fi
 
        echo "  UPD   ${old_name} -> ${new_name}"
        sed -i "s|$(esc "${dir}/${old_name} : ${sha}")|$(esc "${dir}/${new_name} : ${new_sha}")|" "$PACKAGE_YML"
        CHANGED=$((CHANGED + 1))
    done
 
    echo "${CHANGED} dependency source(s) updated."
}
 
# Add a source that is missing entirely (e.g. from a "No rule to make target" error)
add_source() {
    local ver name s tar sha last
    ver=$(current_version)
    read -rp "Tarball name (from the error, e.g. pdfium-8073.tar.bz2): " name
    name=${name##*/}
    [[ -n $name ]] || { echo "Error: nothing entered"; return 1; }
 
    load_lst "$ver" || return 1
    s=$(stem "$name")
    tar=${LST_TAR[$s]:-}
    if [[ -z $tar ]]; then
        echo "Error: '${name}' (stem '${s}') not found in download.lst"
        return 1
    fi
    [[ $tar == "$name" ]] || echo "Note: download.lst lists ${tar}, using that instead"
    sha=${LST_SHA[$s]}
 
    if grep -qF "$tar" "$PACKAGE_YML"; then
        echo "${tar} already in package.yml"
        return 0
    fi
 
    last=$(grep -nP "https://${DEP_HOST}/" "$PACKAGE_YML" | tail -1 | cut -d: -f1)
    sed -i "${last}a\\    - https://dev-www.libreoffice.org/src/${tar} : ${sha}" "$PACKAGE_YML"
    echo "Added ${tar} : ${sha}"
    CHANGED=1
}
 
# ---------------------------------------------------------------- menu
 
echo "LibreOffice $(current_version), release $(current_release)"
echo
echo "  1) Update LibreOffice only"
echo "  2) Sync bundled dependencies only (from download.lst)"
echo "  3) Update LibreOffice + sync dependencies"
echo "  4) Add a missing source by tarball name"
echo "  q) Quit"
read -rp "Choice: " CHOICE
 
case "$CHOICE" in
    1)
        update_lo
        ;;
    2)
        sync_deps "$(current_version)" && ((CHANGED > 0)) && bump_release
        ;;
    3)
        update_lo && sync_deps "$(current_version)"
        ;;
    4)
        add_source && ((CHANGED > 0)) && bump_release
        ;;
    q|Q)
        exit 0
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac
 
echo "Done."
