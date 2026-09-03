#!/usr/bin/env bash
# fetch.sh — download, VERIFY, and extract the pinned corvid FFI release
# for this host (macOS/Linux). Windows: fetch.ps1.
#
# Binding rules (docs/PLAN.md):
#   - the engine pin is EXACT and lives in ONE variable: CORVID_VERSION;
#   - artifacts come only from the tag's GitHub release and are sha256-
#     verified against the release's checksums.txt before extraction;
#   - deps/ is gitignored — no vendored binaries, ever;
#   - the vendored golden/*.txt fixtures must match the release's copies
#     byte for byte — a mismatch is a hard failure (artifact finding,
#     never a patch-here).
#
# Deterministic + idempotent: re-running with the same pin is a no-op;
# stale engine versions (extracted dirs and old tarballs) are always
# discarded.

set -euo pipefail

CORVID_VERSION="v0.4.1"          # THE pin. Bump here and nowhere else.
REPO="corvid-db/corvid"

cd "$(dirname "$0")"
ROOT="$(pwd)"
DL="$ROOT/deps/dl"

# ---- host platform → release target ------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS:$ARCH" in
    Darwin:arm64)  TARGET="aarch64-apple-darwin" ;;
    Darwin:x86_64) TARGET="x86_64-apple-darwin" ;;
    Linux:aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
    Linux:x86_64)  TARGET="x86_64-unknown-linux-gnu" ;;
    *) echo "fetch.sh: unsupported host $OS/$ARCH (use fetch.ps1 on Windows)" >&2; exit 1 ;;
esac

ARCHIVE="corvid-ffi-${CORVID_VERSION}-${TARGET}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${CORVID_VERSION}"
EXTRACTED="$ROOT/deps/corvid-ffi-${CORVID_VERSION}-${TARGET}"

echo "fetch: corvid ${CORVID_VERSION} for ${TARGET}"

mkdir -p "$DL" "$ROOT/deps"

# ---- stale-version cleanup: always discard anything not the current pin --
# build.zig's configure error tells the user to re-run fetch because "it
# discards stale versions and keeps exactly one" — so actually do that on
# every run, not only when we're about to download. Old release tarballs
# in deps/dl are pruned too, so they don't accumulate across pin bumps.
find "$ROOT/deps" -maxdepth 1 -type d -name 'corvid-ffi-*' \
    ! -name "corvid-ffi-${CORVID_VERSION}-${TARGET}" -exec rm -rf {} +
find "$DL" -maxdepth 1 -type f -name 'corvid-ffi-*.tar.gz' \
    ! -name "$ARCHIVE" -exec rm -f {} +

# ---- download checksums + (if needed) the archive ----------------------
curl -fsSL -o "$DL/checksums.txt" "$BASE_URL/checksums.txt"

if [ -d "$EXTRACTED" ]; then
    echo "fetch: $EXTRACTED already present — verifying stamp only"
else
    curl -fsSL -o "$DL/$ARCHIVE" "$BASE_URL/$ARCHIVE"

    # ---- verify: sha256 against the release's checksums.txt ------------
    EXPECTED="$(awk -v f="$ARCHIVE" '$2 == f { print $1 }' "$DL/checksums.txt")"
    if [ -z "$EXPECTED" ]; then
        echo "fetch: $ARCHIVE is not listed in the release checksums.txt" >&2
        exit 1
    fi
    if command -v shasum >/dev/null 2>&1; then
        ACTUAL="$(shasum -a 256 "$DL/$ARCHIVE" | awk '{ print $1 }')"
    elif command -v sha256sum >/dev/null 2>&1; then
        ACTUAL="$(sha256sum "$DL/$ARCHIVE" | awk '{ print $1 }')"
    else
        echo "fetch: need shasum (macOS) or sha256sum (Linux) to verify" >&2
        exit 1
    fi
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "fetch: sha256 MISMATCH for $ARCHIVE" >&2
        echo "  expected $EXPECTED" >&2
        echo "  actual   $ACTUAL" >&2
        exit 1
    fi
    echo "fetch: sha256 ok ($ACTUAL)"

    # ---- extract --------------------------------------------------------
    tar xzf "$DL/$ARCHIVE" -C "$ROOT/deps"
fi

# Required: corvid.h always; plus the cdylib for this platform (dylib on
# macOS, .so on Linux). Parentheses matter — without them && binds tighter
# than || and the corvid.h check goes inert on Linux.
# shellcheck disable=SC2235  # the parens are the point (see above)
if [ ! -f "$EXTRACTED/corvid.h" ] || ([ ! -f "$EXTRACTED/libcorvid.dylib" ] && [ ! -f "$EXTRACTED/libcorvid.so" ]); then
    echo "fetch: $EXTRACTED is missing corvid.h / the cdylib — bad archive?" >&2
    exit 1
fi
ls "$EXTRACTED"/golden/*.txt >/dev/null || {
    echo "fetch: $EXTRACTED/golden holds no fixtures" >&2; exit 1;
}

# ---- the vendored golden fixtures must match the release's byte for byte --
# golden/ is committed here so the golden suite replays an exact, reviewable
# contract; fetch refuses to proceed if the pinned release's copies differ.
for f in "$ROOT"/golden/*.txt; do
    name="$(basename "$f")"
    if ! cmp -s "$f" "$EXTRACTED/golden/$name"; then
        echo "fetch: vendored golden/$name differs from the release's copy — artifact finding, not a patch-here" >&2
        exit 1
    fi
done

# ---- normalize into deps/current (what build.zig points at) --------------
# A stable directory name keeps the build platform-independent: corvid.h
# plus the platform cdylib (the MSVC import lib keeps its corvid.dll.lib
# name; build.zig picks what to link per target).
CUR="$ROOT/deps/current"
rm -rf "$CUR"
mkdir -p "$CUR"
cp "$EXTRACTED/corvid.h" "$CUR/"
if [ -f "$EXTRACTED/libcorvid.dylib" ]; then cp "$EXTRACTED/libcorvid.dylib" "$CUR/"; fi
if [ -f "$EXTRACTED/libcorvid.so" ]; then cp "$EXTRACTED/libcorvid.so" "$CUR/"; fi

# ---- the stamp build.zig reads (single source of truth for the version) ----
printf '%s\n' "$CORVID_VERSION" > "$ROOT/deps/version.txt"
echo "fetch: deps/current ready (corvid.h, cdylib) — pin $CORVID_VERSION"
