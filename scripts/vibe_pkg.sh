#!/usr/bin/env bash
# vibe_pkg.sh — local distribution pipeline (#754, ADR-0065 Phase 4)
# + registry transparency log (#805/#755, ADR-0065 Phase 5 minimal slice).
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
#   vibe_pkg.sh yank <name>@<version>
#       Appends a YANK record to the transparency log (#805). Yank is a
#       marking, never a deletion: the version->hash mapping and the CAS
#       entry stay intact, and existing pinned builds keep working. install
#       refuses a yanked version unless --allow-yanked is passed.
#
#   vibe_pkg.sh update <name> [--store]
#       Re-resolves <name> to the newest non-yanked published version,
#       prints the contract hash change and a textual contract
#       (index.vibei) diff against the installed copy, then materializes
#       the new version. (The canonical contract_surface_lines set diff is
#       not yet reachable from shell — see docs/registry-design.md.)
#
# Transparency log (#805, docs/registry-design.md Phase 1 minimal slice):
# publish/yank append one TSV record to $VIBE_REGISTRY_LOG_DIR/records.tsv
# (default $VIBE_HOME/log) and maintain a Merkle head in .../head. The log
# dir is a plain directory of static files — rsync/HTTP-serve it as-is.
# install/add verify (a) the head commits to the served records (tamper
# check), (b) prefix consistency against the last head this client saw
# (the log may only ever extend), and (c) an RFC6962-style inclusion proof
# for the claimed name@version -> hash record against the head root.
#
# The compiler wasm defaults to the committed seed; override with
# VIBE_PKG_CLI_WASM (e.g. a freshly built stage2). When `vibe pkg` (the
# installed launcher) delegates here it sets VIBE_PKG_RUNNER to its own
# wasmtime runner, so no repo checkout / node host runner is needed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Repo mode keeps the historical repo-root cwd (gate fixtures use repo-relative
# .vibe/store paths). Launcher mode (VIBE_PKG_RUNNER set) stays in the caller's
# cwd so relative package-dir arguments and .vibe/store resolve against the
# user's project, and works without a checkout.
if [ -z "${VIBE_PKG_RUNNER:-}" ]; then
  cd "$ROOT_DIR"
fi
[ -n "${VIBE_PKG_CLI_WASM:-}" ] || bash "$ROOT_DIR/scripts/ensure_seed.sh"
CLI="${VIBE_PKG_CLI_WASM:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
VIBE_HOME="${VIBE_HOME:-$HOME/.vibe}"
CACHE_DIR="$VIBE_HOME/cache"
VERSIONS_TSV="$CACHE_DIR/versions.tsv"
PROVENANCE_TSV="$CACHE_DIR/provenance.tsv"
# Registry transparency log (#805): a directory of static files. The local
# default doubles as the served artifact; point VIBE_REGISTRY_LOG_DIR at a
# synced copy to consume someone else's registry.
LOG_DIR="${VIBE_REGISTRY_LOG_DIR:-$VIBE_HOME/log}"
LOG_RECORDS="$LOG_DIR/records.tsv"
LOG_HEAD="$LOG_DIR/head"

say() { echo "[vibe-pkg] $*"; }
die() { echo "[vibe-pkg] error: $*" >&2; exit 1; }

invoke_cli() {
  # invoke_cli VAR=val ... -- <input> <output>
  # Repo mode (default): node host runner + compiler wasm, preopening the
  # repo root. Launcher mode (VIBE_PKG_RUNNER, set by `vibe pkg`): the
  # installed wasmtime runner executes the toolchain compiler directly, so
  # this script works standalone outside a checkout.
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  if [ -n "${VIBE_PKG_RUNNER:-}" ]; then
    env "${envs[@]}" "$VIBE_PKG_RUNNER" "$CLI" "$1" "$2" __no_entry__ >/dev/null 2>&1 || true
  else
    env "${envs[@]}" VIBE_PREOPEN_DIR="$ROOT_DIR" \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "$CLI" \
      "$1" "$2" __no_entry__ >/dev/null 2>&1 || true
  fi
}

compute_pkg_hashes() {
  # sets PKG_HASH_OUT (pkg:sha1:<40hex>) and CT_HASH_OUT (ct:sha1:<40hex>)
  # for the contract at $1 in ONE compiler invocation.
  local index_path="$1" out pline cline
  out="$(mktemp)"
  invoke_cli VIBE_HASH=1 -- "$index_path" "$out"
  pline="$(grep '^package ' "$out" 2>/dev/null | head -1 || true)"
  cline="$(grep '^contract ' "$out" 2>/dev/null | head -1 || true)"
  if [ -z "$pline" ]; then
    cat "$out.diag" 2>/dev/null >&2 || true
    rm -f "$out" "$out.diag"
    die "hash computation failed for $index_path (CLI: $CLI)"
  fi
  rm -f "$out" "$out.diag"
  # package line is "package #pkg:sha1:<40hex>" — strip the label AND the
  # leading '#' so callers hold the bare "pkg:sha1:<40hex>" form (require
  # pin spelling re-adds the '#').
  pline="${pline#package }"
  PKG_HASH_OUT="${pline#\#}"
  CT_HASH_OUT="${cline#contract }"
}

pkg_hash_of() {
  # prints the package hash (pkg:sha1:<40hex>) of the contract at $1
  compute_pkg_hashes "$1"
  echo "$PKG_HASH_OUT"
}

# --- transparency log (#805): merkle tree over append-only TSV records ------
#
# Record line (one per publish/yank event, TAB-separated):
#   <ordinal>  <op>  <name@version>  <pkg-hash>  <contract-hash>  <source>  <commit>
# op = publish | yank; ordinal = 0-based position in the log (NO wall-clock —
# ordering is the log order itself, so records are reproducible bytes).
# Head file: "<size>\t<root>" where root is the Merkle root over all records.
#
# Hashing: sha256 over ASCII, domain-separated RFC6962-style —
#   leaf = sha256("leaf:" + record-line), node = sha256("node:" + L + ":" + R)
# (hex-string concatenation instead of raw bytes keeps the verifier trivially
# portable in bash; the tree SHAPE — split at the largest power of two — is
# RFC6962, so proofs transfer 1:1 to a future @vibe/core verifier.)

_sha256_stdin() {
  # Probe by RUNNING it, not by `command -v`: a nix-shim `sha256sum` that is on
  # PATH but dies on a glibc mismatch passes an existence check and then fails
  # every call, so the fallback never engages and the caller dies instead.
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | awk '{print $1}'
  fi
}
leaf_hash() { printf 'leaf:%s' "$1" | _sha256_stdin; }
node_hash() { printf 'node:%s:%s' "$1" "$2" | _sha256_stdin; }

merkle_load() {
  # load leaf hashes of $1 (records file) into MERKLE_LEAVES; with $2 = N,
  # only the first N records (prefix consistency recompute).
  MERKLE_LEAVES=()
  local line n=0 limit="${2:-}"
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    if [ -n "$limit" ] && [ "$n" -ge "$limit" ]; then break; fi
    MERKLE_LEAVES+=("$(leaf_hash "$line")")
    n=$((n+1))
  done < "$1"
}

merkle_root_range() {
  # echoes the RFC6962-shaped subtree root over MERKLE_LEAVES[$1..$2)
  local lo="$1" hi="$2"
  local n=$((hi - lo)) k=1
  if [ "$n" -eq 1 ]; then echo "${MERKLE_LEAVES[$lo]}"; return 0; fi
  while [ $((k * 2)) -lt "$n" ]; do k=$((k * 2)); done
  node_hash "$(merkle_root_range "$lo" $((lo + k)))" \
            "$(merkle_root_range $((lo + k)) "$hi")"
}

merkle_root() {
  local n="${#MERKLE_LEAVES[@]}"
  if [ "$n" -eq 0 ]; then printf 'empty' | _sha256_stdin; return 0; fi
  merkle_root_range 0 "$n"
}

merkle_inclusion_proof() {
  # audit path for leaf index $1, leaf-to-root order, one "L|R <hash>" per
  # line: R = sibling is the RIGHT child (combine node(h, sib)), L = left.
  _incl_path "$1" 0 "${#MERKLE_LEAVES[@]}"
}
_incl_path() {
  local m="$1" lo="$2" hi="$3"
  local n=$((hi - lo)) k=1
  [ "$n" -eq 1 ] && return 0
  while [ $((k * 2)) -lt "$n" ]; do k=$((k * 2)); done
  if [ "$m" -lt $((lo + k)) ]; then
    _incl_path "$m" "$lo" $((lo + k))
    echo "R $(merkle_root_range $((lo + k)) "$hi")"
  else
    _incl_path "$m" $((lo + k)) "$hi"
    echo "L $(merkle_root_range "$lo" $((lo + k)))"
  fi
}

merkle_verify_inclusion() {
  # $1 = leaf hash, $2 = expected root, $3 = proof text (from
  # merkle_inclusion_proof). Recomputes the root from the leaf + audit path.
  local h="$1" side sib
  while read -r side sib; do
    [ -n "$side" ] || continue
    if [ "$side" = "R" ]; then h="$(node_hash "$h" "$sib")"; else h="$(node_hash "$sib" "$h")"; fi
  done <<EOF
$3
EOF
  [ "$h" = "$2" ]
}

log_seen_file() {
  # last head this CLIENT saw for the current log dir. Keyed by the log dir
  # path so switching VIBE_REGISTRY_LOG_DIR between unrelated registries
  # cannot cross-fire the consistency check.
  echo "$CACHE_DIR/log-head.seen.$(printf '%s' "$LOG_DIR" | _sha256_stdin | cut -c1-12)"
}

log_verify_self() {
  # the served head must commit to the served records exactly (tamper check).
  # No log at all is fine (phase-0 lane); records without a head, a head that
  # miscounts, or a head whose root does not recompute are all tamper-evident.
  if [ ! -f "$LOG_RECORDS" ] && [ ! -f "$LOG_HEAD" ]; then return 0; fi
  [ -f "$LOG_HEAD" ] || die "tampered log head: $LOG_RECORDS exists but $LOG_HEAD is missing"
  [ -f "$LOG_RECORDS" ] || die "tampered log head: $LOG_HEAD exists but $LOG_RECORDS is missing"
  local size root lines got
  IFS="$(printf '\t')" read -r size root < "$LOG_HEAD"
  lines="$(wc -l < "$LOG_RECORDS" | tr -d '[:space:]')"
  [ "$size" = "$lines" ] || die "tampered log head: head claims $size record(s), records.tsv has $lines"
  merkle_load "$LOG_RECORDS"
  got="$(merkle_root)"
  [ "$got" = "$root" ] || die "tampered log head: head root $root does not match recomputed $got"
}

log_verify_consistency() {
  # append-only guarantee: the head may only ever EXTEND the head this client
  # last saw. With static-file serving the client has the full records file,
  # so consistency is checked by recomputing the old-size prefix root (see
  # docs/registry-design.md — O(log n) consistency proofs come with the
  # remote-proof protocol, not this full-fetch slice). Advances the seen head.
  local seen size root seen_size seen_root prefix_root
  seen="$(log_seen_file)"
  [ -f "$LOG_HEAD" ] || return 0
  IFS="$(printf '\t')" read -r size root < "$LOG_HEAD"
  if [ -f "$seen" ]; then
    IFS="$(printf '\t')" read -r seen_size seen_root < "$seen"
    if [ "$size" -lt "$seen_size" ]; then
      die "log consistency violation: head regressed to $size record(s), this client already saw $seen_size (append-only log was truncated/rewritten)"
    fi
    if [ "$seen_size" -gt 0 ]; then
      merkle_load "$LOG_RECORDS" "$seen_size"
      prefix_root="$(merkle_root)"
      if [ "$prefix_root" != "$seen_root" ]; then
        die "log consistency violation: the first $seen_size record(s) no longer hash to the head this client saw (append-only history was rewritten)"
      fi
    fi
  fi
  mkdir -p "$CACHE_DIR"
  printf '%s\t%s\n' "$size" "$root" > "$seen"
}

log_append() {
  # $1=op $2=name@version $3=pkg-hash $4=contract-hash $5=source $6=commit —
  # append one record, recompute the head, advance this client's seen head.
  local op="$1" key="$2" hash="$3" ct="$4" src="$5" commit="$6" ord size root
  log_verify_self
  log_verify_consistency
  mkdir -p "$LOG_DIR"
  [ -f "$LOG_RECORDS" ] || : > "$LOG_RECORDS"
  ord="$(wc -l < "$LOG_RECORDS" | tr -d '[:space:]')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ord" "$op" "$key" "$hash" "$ct" "$src" "$commit" >> "$LOG_RECORDS"
  merkle_load "$LOG_RECORDS"
  size=$((ord + 1))
  root="$(merkle_root)"
  printf '%s\t%s\n' "$size" "$root" > "$LOG_HEAD"
  mkdir -p "$CACHE_DIR"
  printf '%s\t%s\n' "$size" "$root" > "$(log_seen_file)"
  say "log: $op $key recorded (ordinal $ord, head $size:${root:0:12})"
}

log_has_publish() {
  # does the log contain a publish record for $1 = name@version?
  [ -f "$LOG_RECORDS" ] || return 1
  awk -F'\t' -v k="$1" '$2 == "publish" && $3 == k { found = 1 } END { exit found ? 0 : 1 }' "$LOG_RECORDS"
}

log_client_verify() {
  # client-side lookup verification for $1 = name@version, $2 = the hash the
  # client is about to trust. Sets LOG_STATE to:
  #   absent  — no log / no publish record for the key (phase-0 TOFU lane)
  #   ok      — inclusion proof verified, not yanked
  #   yanked  — inclusion proof verified, a later yank record marks the key
  # Dies on tamper / consistency violation / hash disagreement with the log.
  LOG_STATE=absent
  if [ ! -f "$LOG_RECORDS" ] && [ ! -f "$LOG_HEAD" ]; then return 0; fi
  log_verify_self
  log_verify_consistency
  local idx=-1 rec_hash="" yanked=0 i=0 ord op key hash ct src commit rest
  while IFS="$(printf '\t')" read -r ord op key hash ct src commit rest; do
    if [ "$key" = "$1" ]; then
      case "$op" in
        publish) idx="$i"; rec_hash="$hash"; yanked=0 ;;
        yank) yanked=1 ;;
      esac
    fi
    i=$((i + 1))
  done < "$LOG_RECORDS"
  [ "$idx" -ge 0 ] || return 0
  if [ "$rec_hash" != "$2" ]; then
    die "transparency log says $1 is #$rec_hash, local record says #$2 — rejected (split-view or tampered cache)"
  fi
  local head_size head_root record_line leafh proof
  IFS="$(printf '\t')" read -r head_size head_root < "$LOG_HEAD"
  record_line="$(sed -n "$((idx + 1))p" "$LOG_RECORDS")"
  leafh="$(leaf_hash "$record_line")"
  merkle_load "$LOG_RECORDS"
  proof="$(merkle_inclusion_proof "$idx")"
  if ! merkle_verify_inclusion "$leafh" "$head_root" "$proof"; then
    die "inclusion proof for $1 (record $idx) failed against log head $head_size:${head_root:0:12}"
  fi
  say "log: inclusion verified for $1 (record $idx, head $head_size:${head_root:0:12})"
  if [ "$yanked" = "1" ]; then LOG_STATE=yanked; else LOG_STATE=ok; fi
}

version_is_yanked() {
  # $1 = name@version -> succeeds when the LAST log op for the key is a yank
  [ -f "$LOG_RECORDS" ] || return 1
  local st
  st="$(awk -F'\t' -v k="$1" '$3 == k { s = $2 } END { print s }' "$LOG_RECORDS")"
  [ "$st" = "yank" ]
}
# ---------------------------------------------------------------------------

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
    invoke_cli VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$prev_index" \
      -- "$pkg_dir/index.vibei" "$pub_out"
    if ! grep -q '^ok' "$pub_out" 2>/dev/null; then
      cat "$pub_out.diag" 2>/dev/null >&2 || true
      rm -f "$pub_out" "$pub_out.diag"
      die "publish gate rejected $name $prev_version -> $version"
    fi
    rm -f "$pub_out" "$pub_out.diag"
  fi

  compute_pkg_hashes "$pkg_dir/index.vibei"
  hash="$PKG_HASH_OUT"
  ct_hash="$CT_HASH_OUT"
  key="$name@$version"
  recorded="$(lookup_version "$key")"
  if [ -n "$recorded" ]; then
    if [ "$recorded" = "$hash" ]; then
      # Idempotent — but REPAIR a missing transparency record first: if a
      # prior publish crashed between the versions.tsv append and log_append
      # (unwritable log dir, interruption, full disk), the version would stay
      # mapped without a publish record and every retry would exit here,
      # permanently bypassing transparency + yank handling (Codex review,
      # PR #927).
      if ! log_has_publish "$key"; then
        say "$key is mapped in versions.tsv but has no publish record — repairing the transparency log"
        log_append publish "$key" "$hash" "$ct_hash" "local" "-"
      fi
      say "$key already published as #$hash (idempotent)"
      exit 0
    fi
    die "same-version republish rejected: $key is #$recorded, refusing #$hash (bump the version; version->hash is immutable, ADR-0065)"
  fi
  # a tampered/rewritten log must refuse the publish BEFORE any side effect
  log_verify_self
  log_verify_consistency

  hex="${hash#pkg:sha1:}"
  cas="$CACHE_DIR/pkg/sha1/$hex"
  rm -rf "$cas"
  copy_package_files "$pkg_dir" "$cas"
  # the CAS copy must hash to its own address
  cas_hash="$(pkg_hash_of "$cas/index.vibei")"
  [ "$cas_hash" = "$hash" ] || die "CAS self-check failed: $cas hashes to #$cas_hash, expected #$hash"
  mkdir -p "$CACHE_DIR"
  printf '%s\t%s\n' "$key" "$hash" >> "$VERSIONS_TSV"
  # registry-side transparency record (#805): local publishes carry no
  # source/commit provenance yet (attestation is the Phase 2 signing work)
  log_append publish "$key" "$hash" "$ct_hash" "local" "-"
  say "published $key -> #$hash"
  say "cache: $cas"
  ;;
install)
  shift
  spec=""
  target=""
  allow_yanked=0
  for a in "$@"; do
    case "$a" in
      --store) target="--store" ;;
      --allow-yanked) allow_yanked=1 ;;
      *)
        [ -z "$spec" ] || die "unexpected argument: $a"
        spec="$a"
        ;;
    esac
  done
  case "$spec" in
    @*/*@*) ;;
    *) die "usage: vibe_pkg.sh install @scope/name@x.y.z [--store] [--allow-yanked]" ;;
  esac
  name="${spec%@*}"
  version="${spec##*@}"
  hash="$(lookup_version "$name@$version")"
  [ -n "$hash" ] || die "unknown version: $name@$version (publish it first, or 'vibe_pkg.sh add' it from a git source — #755)"
  # transparency log verification (#805): tamper + consistency + inclusion.
  # A version the log never saw (git-added TOFU) stays on the phase-0 lane.
  log_client_verify "$name@$version" "$hash"
  if [ "$LOG_STATE" = "yanked" ]; then
    if [ "$allow_yanked" = "1" ]; then
      say "WARNING: $name@$version is yanked in the registry log — installing anyway (--allow-yanked)"
    else
      die "$name@$version is yanked in the registry log — refusing to install (pass --allow-yanked to override; existing pins keep working)"
    fi
  fi
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
  # transparency log cross-check (#805): when the registry log knows this
  # name@version, the fetched hash must agree (dies on a split view). Yank is
  # only a warning here — `add` is the explicit-source lane; `install` is the
  # one that refuses.
  log_client_verify "$key" "$hash"
  if [ "$LOG_STATE" = "yanked" ]; then
    say "WARNING: $key is yanked in the registry log"
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
yank)
  spec="${2:-}"
  case "$spec" in
    @*/*@*) ;;
    *) die "usage: vibe_pkg.sh yank @scope/name@x.y.z" ;;
  esac
  name="${spec%@*}"
  version="${spec##*@}"
  key="$name@$version"
  hash="$(lookup_version "$key")"
  [ -n "$hash" ] || die "unknown version: $key (nothing to yank)"
  [ -f "$LOG_RECORDS" ] || die "cannot yank $key: no transparency log at $LOG_DIR (only logged publishes can be yanked — #805)"
  if ! awk -F'\t' -v k="$key" '$2 == "publish" && $3 == k { found = 1 } END { exit !found }' "$LOG_RECORDS"; then
    die "cannot yank $key: no publish record in the transparency log (git-added versions live on the phase-0 lane — #805)"
  fi
  if version_is_yanked "$key"; then
    say "$key is already yanked (idempotent)"
    exit 0
  fi
  # yank is a MARKING: the log only ever appends, versions.tsv and the CAS
  # stay untouched, existing pins keep building (design doc requirement 5)
  log_append yank "$key" "$hash" "-" "-" "-"
  say "yanked $key (append-only marking; version->hash mapping unchanged)"
  ;;
update)
  shift
  name=""
  target=""
  for a in "$@"; do
    case "$a" in
      --store) target="--store" ;;
      *)
        [ -z "$name" ] || die "unexpected argument: $a"
        name="$a"
        ;;
    esac
  done
  case "$name" in
    @*/*@*) die "usage: vibe_pkg.sh update @scope/name [--store] (no @version — update resolves the newest non-yanked one)" ;;
    @*/*) ;;
    *) die "usage: vibe_pkg.sh update @scope/name [--store]" ;;
  esac
  if [ "$target" = "--store" ]; then
    inst_dir=".vibe/store/$name"
  else
    inst_dir="$VIBE_HOME/lib/$name"
  fi
  [ -f "$inst_dir/index.vibei" ] || die "not installed: $name ($inst_dir) — 'vibe_pkg.sh install' it first"
  [ -f "$VERSIONS_TSV" ] || die "no published versions known (empty cache index)"
  # current version = reverse lookup of the installed copy's hash
  compute_pkg_hashes "$inst_dir/index.vibei"
  cur_hash="$PKG_HASH_OUT"
  cur_ct="$CT_HASH_OUT"
  cur_version="$(awk -F'\t' -v n="$name" -v h="$cur_hash" 'index($1, n "@") == 1 && $2 == h { v = substr($1, length(n) + 2) } END { print v }' "$VERSIONS_TSV")"
  # newest non-yanked LOGGED publish (publish order, like latest_version_of).
  # versions.tsv also holds TOFU mappings created by `add github:...` that
  # have no publish record; selecting one of those would let update install
  # a version with LOG_STATE=absent, silently bypassing inclusion + yank
  # verification (Codex review, PR #927) — so candidates are restricted to
  # versions with a publish record in the transparency log.
  best=""
  best_hash=""
  while IFS="$(printf '\t')" read -r k h; do
    case "$k" in "$name@"*) ;; *) continue ;; esac
    log_has_publish "$k" || continue
    version_is_yanked "$k" && continue
    best="${k##*@}"
    best_hash="$h"
  done < "$VERSIONS_TSV"
  [ -n "$best" ] || die "no logged (published) non-yanked version of $name — git-added versions are updated by re-running 'add' with a new ref"
  if [ "$best" = "${cur_version:-}" ]; then
    say "$name is up to date (${cur_version} = #$cur_hash)"
    exit 0
  fi
  # verify the candidate against the transparency log BEFORE showing/switching
  log_client_verify "$name@$best" "$best_hash"
  best_hex="${best_hash#pkg:sha1:}"
  best_index="$CACHE_DIR/pkg/sha1/$best_hex/index.vibei"
  [ -f "$best_index" ] || die "cache is missing $name@$best ($best_hash)"
  compute_pkg_hashes "$best_index"
  best_ct="$CT_HASH_OUT"
  say "update $name: ${cur_version:-<untracked local copy>} -> $best"
  if [ "$cur_ct" = "$best_ct" ]; then
    say "contract surface: unchanged ($cur_ct)"
  else
    say "contract surface: $cur_ct -> $best_ct"
    # CONTRACT SURFACE DIFF, textual approximation: the contract file itself.
    # The canonical set-diff over contract_surface_lines (incl. effect-row
    # capability classification) needs a compiler adapter mode that is not
    # exposed yet — see docs/registry-design.md "実装済みの範囲と既知の gap".
    say "contract diff ($inst_dir/index.vibei -> $name@$best):"
    diff -u "$inst_dir/index.vibei" "$best_index" | sed 's/^/[vibe-pkg]   /' || true
  fi
  materialize_from_cas "$name" "$best" "$best_hash" "$target"
  ;;
*)
  die "usage: vibe_pkg.sh publish <pkg_dir> | install @scope/name@x.y.z [--store] [--allow-yanked] | add <source-spec> [#pkg:sha1:<40hex>] [--store] | yank @scope/name@x.y.z | update @scope/name [--store]"
  ;;
esac
