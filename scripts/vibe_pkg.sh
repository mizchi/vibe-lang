#!/usr/bin/env bash
# vibe_pkg.sh — local distribution pipeline (#754, ADR-0065 Phase 4).
#
#   vibe_pkg.sh publish <pkg_dir>
#       The package's index.vibei MUST carry a `version x.y.z` directive.
#       Runs the semver publish gate against the previously published version
#       of the same name (when one exists in the cache index), computes the
#       package hash, and stores the package files in the fetch cache:
#
#           $VIBE_HOME/cache/pkg/sha1/<40hex>/   (passive CAS — never a
#                                                 resolution root)
#           $VIBE_HOME/cache/versions.tsv        (name@version -> #pkg:sha1:…)
#
#       version->hash is an IMMUTABLE mapping: republishing a known
#       name@version with a different hash is rejected (same hash is an
#       idempotent no-op). This file doubles as the client-side record that
#       rejects upstream hash changes for known versions (#755 keeps the
#       registry-side log).
#
#   vibe_pkg.sh install <name>@<version> [--store]
#       Looks the version up in the cache index, MATERIALIZES the package
#       from the CAS into $VIBE_HOME/lib/<name>/ (the default VIBE_LIB root,
#       #751) — or into the workspace .vibe/store/<name>/ with --store for
#       the pinned lane — and re-verifies the materialized copy's hash
#       against the recorded one.
#
#   vibe_pkg.sh add <source-spec> [#pkg:sha1:<40hex>] [--store]
#       Registry-less resolution (#755 Phase 0): fetch a package DIRECTLY
#       from a git host, verify it by content hash, and install it. Specs:
#
#           github:owner/repo[/sub/dir]@<ref>
#           git:<url>@<ref>[#<sub/dir>]
#
#       The ref is resolved to a COMMIT and fetched with git; the package
#       hash is computed locally over the fetched sources, so the transport
#       is untrusted by construction. With an expected pin argument the
#       fetch is rejected on mismatch BEFORE anything is installed; without
#       one this is trust-on-first-use — the hash is printed and recorded,
#       and any later fetch of the same name@version with different content
#       is rejected (version->hash immutability). The resolved
#       (source, commit) pair is appended to $VIBE_HOME/cache/provenance.tsv
#       so third parties can re-fetch and re-hash (source-only provenance).
#
# The compiler wasm defaults to the committed seed; override with
# VIBE_PKG_CLI_WASM (e.g. a freshly built stage2 — required while the seed
# predates the version directive).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${VIBE_PKG_CLI_WASM:-bootstrap/seed/selfhost_compiler.wasm}"
VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
CACHE_DIR="$VIBE_HOME/cache"
VERSIONS_TSV="$CACHE_DIR/versions.tsv"
PROVENANCE_TSV="$CACHE_DIR/provenance.tsv"

say() { echo "[vibe-pkg] $*"; }
die() { echo "[vibe-pkg] error: $*" >&2; exit 1; }

pkg_hash_of() {
  # prints the package hash (#pkg:sha1:<40hex>) of the contract at $1
  local index_path="$1" out
  out="$(mktemp)"
  VIBE_HASH=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI" \
    "$index_path" "$out" __no_entry__ >/dev/null 2>&1 || true
  local line
  line="$(grep '^package ' "$out" 2>/dev/null | head -1 || true)"
  if [ -z "$line" ]; then
    cat "$out.diag" 2>/dev/null >&2 || true
    rm -f "$out" "$out.diag"
    die "hash computation failed for $index_path (CLI: $CLI)"
  fi
  rm -f "$out" "$out.diag"
  # output line is "package #pkg:sha1:<40hex>" — strip the label AND the
  # leading '#' so callers hold the bare "pkg:sha1:<40hex>" form (require
  # pin spelling re-adds the '#').
  line="${line#package }"
  echo "${line#\#}"
}

version_directive_of() {
  # the leading-directive region only: stop at the first ordinary line
  awk '
    /^[[:space:]]*version[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$/ { print $2; exit }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*require / { next }
    { exit }
  ' "$1"
}

lookup_version() {
  # $1 = name@version -> prints recorded hash or nothing
  [ -f "$VERSIONS_TSV" ] || return 0
  awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$VERSIONS_TSV"
}

latest_version_of() {
  # $1 = name -> prints the most recently PUBLISHED version (file order)
  [ -f "$VERSIONS_TSV" ] || return 0
  awk -F'\t' -v n="$1" 'index($1, n "@") == 1 { v = substr($1, length(n) + 2) } END { if (v != "") print v }' "$VERSIONS_TSV"
}

copy_package_files() {
  # $1 = src dir, $2 = dest dir. Package files = contract + impl .vibe files
  # (tests/benches stay behind), mirroring vibe_core_install.sh.
  mkdir -p "$2"
  cp "$1/index.vibei" "$2/"
  local f base
  for f in "$1"/*.vibe; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *_test.vibe|*_bench.vibe) ;;
      *) cp "$f" "$2/" ;;
    esac
  done
}

materialize_from_cas() {
  # $1=name $2=version $3=hash(pkg:sha1:…) $4=target ("--store" or "")
  local name="$1" version="$2" hash="$3" target="$4" hex cas dest got
  hex="${hash#pkg:sha1:}"
  cas="$CACHE_DIR/pkg/sha1/$hex"
  [ -f "$cas/index.vibei" ] || die "cache is missing $name@$version ($hash) at $cas"
  if [ "$target" = "--store" ]; then
    dest=".vibe/store/$name"
  else
    dest="$VIBE_HOME/lib/$name"
  fi
  rm -rf "$dest"
  copy_package_files "$cas" "$dest"
  # verify the MATERIALIZED copy against the recorded hash (tamper/bit-rot
  # and known-version immutability in one check)
  got="$(pkg_hash_of "$dest/index.vibei")"
  if [ "$got" != "$hash" ]; then
    rm -rf "$dest"
    die "materialized copy of $name@$version hashes to #$got, recorded #$hash — rejected (version->hash is immutable)"
  fi
  say "installed $name@$version -> $dest (#$hash)"
  say "pin line: require $name $version = #$hash"
}

cmd="${1:-}"
case "$cmd" in
publish)
  pkg_dir="${2:-}"
  [ -n "$pkg_dir" ] && [ -f "$pkg_dir/index.vibei" ] || die "usage: vibe_pkg.sh publish <pkg_dir> (with index.vibei)"
  # package name = @scope/name from the directory layout (…/@scope/name)
  name="$(basename "$(dirname "$pkg_dir")")/$(basename "$pkg_dir")"
  case "$name" in
    @*/*) ;;
    *) die "package directory must be laid out as …/@scope/name (got: $name)" ;;
  esac
  version="$(version_directive_of "$pkg_dir/index.vibei")"
  [ -n "$version" ] || die "publish requires a \`version x.y.z\` directive in $pkg_dir/index.vibei (#754)"

  # semver gate against the previously published version of this name
  prev_version="$(latest_version_of "$name")"
  if [ -n "$prev_version" ] && [ "$prev_version" != "$version" ]; then
    prev_hash="$(lookup_version "$name@$prev_version")"
    prev_hex="${prev_hash#pkg:sha1:}"
    prev_index="$CACHE_DIR/pkg/sha1/$prev_hex/index.vibei"
    [ -f "$prev_index" ] || die "cache is missing the previous release $name@$prev_version ($prev_hash)"
    pub_out="$(mktemp)"
    VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$prev_index" \
      VIBE_PREOPEN_DIR="$ROOT_DIR" \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI" \
      "$pkg_dir/index.vibei" "$pub_out" __no_entry__ >/dev/null 2>&1 || true
    if ! grep -q '^ok' "$pub_out" 2>/dev/null; then
      cat "$pub_out.diag" 2>/dev/null >&2 || true
      rm -f "$pub_out" "$pub_out.diag"
      die "publish gate rejected $name $prev_version -> $version"
    fi
    rm -f "$pub_out" "$pub_out.diag"
  fi

  hash="$(pkg_hash_of "$pkg_dir/index.vibei")"
  key="$name@$version"
  recorded="$(lookup_version "$key")"
  if [ -n "$recorded" ]; then
    if [ "$recorded" = "$hash" ]; then
      say "$key already published as #$hash (idempotent)"
      exit 0
    fi
    die "same-version republish rejected: $key is #$recorded, refusing #$hash (bump the version; version->hash is immutable, ADR-0065)"
  fi

  hex="${hash#pkg:sha1:}"
  cas="$CACHE_DIR/pkg/sha1/$hex"
  rm -rf "$cas"
  copy_package_files "$pkg_dir" "$cas"
  # the CAS copy must hash to its own address
  cas_hash="$(pkg_hash_of "$cas/index.vibei")"
  [ "$cas_hash" = "$hash" ] || die "CAS self-check failed: $cas hashes to #$cas_hash, expected #$hash"
  mkdir -p "$CACHE_DIR"
  printf '%s\t%s\n' "$key" "$hash" >> "$VERSIONS_TSV"
  say "published $key -> #$hash"
  say "cache: $cas"
  ;;
install)
  spec="${2:-}"
  target="${3:-}"
  case "$spec" in
    @*/*@*) ;;
    *) die "usage: vibe_pkg.sh install @scope/name@x.y.z [--store]" ;;
  esac
  name="${spec%@*}"
  version="${spec##*@}"
  hash="$(lookup_version "$name@$version")"
  [ -n "$hash" ] || die "unknown version: $name@$version (publish it first, or 'vibe_pkg.sh add' it from a git source — #755)"
  materialize_from_cas "$name" "$version" "$hash" "$target"
  ;;
add)
  shift
  spec=""
  expected=""
  target=""
  for a in "$@"; do
    case "$a" in
      --store) target="--store" ;;
      \#pkg:sha1:*) expected="${a#\#}" ;;
      pkg:sha1:*) expected="$a" ;;
      *)
        [ -z "$spec" ] || die "unexpected argument: $a"
        spec="$a"
        ;;
    esac
  done
  [ -n "$spec" ] || die "usage: vibe_pkg.sh add github:owner/repo[/sub/dir]@<ref> [#pkg:sha1:<40hex>] [--store]"

  subdir=""
  case "$spec" in
    github:*)
      rest="${spec#github:}"
      ref="${rest##*@}"
      path="${rest%@*}"
      [ "$ref" != "$rest" ] && [ -n "$ref" ] || die "github spec needs @<ref>: $spec"
      owner="${path%%/*}"
      rr="${path#*/}"
      repo="${rr%%/*}"
      case "$rr" in
        */*) subdir="${rr#*/}" ;;
      esac
      [ -n "$owner" ] && [ -n "$repo" ] || die "malformed github spec: $spec"
      url="https://github.com/$owner/$repo.git"
      ;;
    git:*)
      rest="${spec#git:}"
      case "$rest" in
        *"#"*)
          subdir="${rest##*#}"
          rest="${rest%#*}"
          ;;
      esac
      ref="${rest##*@}"
      url="${rest%@*}"
      [ "$ref" != "$rest" ] && [ -n "$url" ] || die "git spec needs <url>@<ref>: $spec"
      ;;
    *)
      die "unknown source spec (github:owner/repo[/dir]@ref | git:<url>@<ref>[#<dir>]): $spec"
      ;;
  esac

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  git init -q "$work/checkout"
  if ! git -C "$work/checkout" fetch -q --depth 1 "$url" "$ref" 2>"$work/fetch.log"; then
    # servers that refuse shallow/SHA fetches get one full-fetch retry
    git -C "$work/checkout" fetch -q "$url" "$ref" 2>>"$work/fetch.log" \
      || { cat "$work/fetch.log" >&2; die "git fetch failed: $url @ $ref"; }
  fi
  commit="$(git -C "$work/checkout" rev-parse FETCH_HEAD)"
  git -C "$work/checkout" -c advice.detachedHead=false checkout -q FETCH_HEAD
  src="$work/checkout${subdir:+/$subdir}"
  [ -f "$src/index.vibei" ] || die "fetched source has no index.vibei at '${subdir:-.}' ($spec)"
  name="$(basename "$(dirname "$src")")/$(basename "$src")"
  case "$name" in
    @*/*) ;;
    *) die "fetched package directory must be laid out as …/@scope/name (got: $name)" ;;
  esac
  version="$(version_directive_of "$src/index.vibei")"
  [ -n "$version" ] || die "fetched package has no \`version x.y.z\` directive in index.vibei (#754)"

  # hash is computed LOCALLY over the fetched sources — the transport is
  # untrusted. An expected pin rejects BEFORE any cache/install side effect.
  hash="$(pkg_hash_of "$src/index.vibei")"
  if [ -n "$expected" ] && [ "$hash" != "$expected" ]; then
    die "hash mismatch for $name@$version from $spec: fetched #$hash, expected #$expected — rejected"
  fi
  key="$name@$version"
  recorded="$(lookup_version "$key")"
  if [ -n "$recorded" ] && [ "$recorded" != "$hash" ]; then
    die "known version $key is #$recorded but $spec serves #$hash — rejected (version->hash is immutable, ADR-0065)"
  fi

  hex="${hash#pkg:sha1:}"
  cas="$CACHE_DIR/pkg/sha1/$hex"
  rm -rf "$cas"
  copy_package_files "$src" "$cas"
  cas_hash="$(pkg_hash_of "$cas/index.vibei")"
  [ "$cas_hash" = "$hash" ] || die "CAS self-check failed: $cas hashes to #$cas_hash, expected #$hash"
  mkdir -p "$CACHE_DIR"
  if [ -z "$recorded" ]; then
    printf '%s\t%s\n' "$key" "$hash" >> "$VERSIONS_TSV"
    if [ -z "$expected" ]; then
      say "TRUST-ON-FIRST-USE: recorded $key -> #$hash (re-run with the pin to verify a fresh fetch)"
    fi
  fi
  prov_line="$(printf '%s\t%s\t%s\t%s' "$key" "$hash" "$spec" "$commit")"
  if ! grep -qxF "$prov_line" "$PROVENANCE_TSV" 2>/dev/null; then
    printf '%s\n' "$prov_line" >> "$PROVENANCE_TSV"
  fi
  say "fetched $key from $spec @ $commit"
  materialize_from_cas "$name" "$version" "$hash" "$target"
  ;;
*)
  die "usage: vibe_pkg.sh publish <pkg_dir> | install @scope/name@x.y.z [--store] | add <source-spec> [#pkg:sha1:<40hex>] [--store]"
  ;;
esac
