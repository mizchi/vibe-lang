#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  echo "selfhost-portable-boundary: $*" >&2
  exit 1
}

require_line() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Eq "$pattern" "$ROOT_DIR/$file"; then
    fail "missing expected pure boundary: $label ($file)"
  fi
}

# A doc comment naming a native entry point is a REFERENCE, not a leak: the
# whole point of these files is to explain how they differ from the FS lane, so
# `-- see compile_file_fs_mode's comment` is exactly the prose we want. The scan
# strips `///` and `//` comment lines before matching. Code is what leaks
# capability; prose about code does not.
#
# It strips whole comment LINES only, not trailing comments after code -- a
# stripped tail would let `let x = 1 // perform Fs::read_file` hide a real call
# on the same line if the two were ever reordered. A comment line is the one
# shape that cannot execute.
forbid_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -vE '^[[:space:]]*(///?|//#)' "$ROOT_DIR/$file" \
    | grep -En "$pattern" >/tmp/vibe_portable_boundary_hits.$$; then
    cat /tmp/vibe_portable_boundary_hits.$$ >&2
    rm -f /tmp/vibe_portable_boundary_hits.$$
    fail "native capability leaked into portable boundary: $label ($file)"
  fi
  rm -f /tmp/vibe_portable_boundary_hits.$$
}

native_effect_pattern='with \{[^}]*(Fs|Process|Socket|Net)|perform (Fs|Process|Socket|Http)::|compile_file_fs|session-http|daemon'

# The `with \{...\}` alternative above matches the HANDLER syntax
# (`try ... with { Exception::Throw(e) => ... }`), which is a different
# construct from an effect row. An effect ROW is unbraced and `+`-separated:
# `with Fs`, `with Exception + Fs`, `with Exception + Fs + Env`. Nothing
# matched that, so a boundary implementation could declare `with Fs` outright
# and this gate printed `ok` -- measured, not inferred.
#
# The row check below is an ALLOW-LIST, and that is the point. A deny-list of
# capability names is a proxy for "is this effect native", and it failed twice
# in a row: first it knew only the braced spelling (`with Fs` passed), then,
# rewritten as `Fs|Process|Socket|Net|Http`, it still passed `with Env` and
# `with Console` -- both capability builtins (AGENTS.md). Each fix closed the
# hole someone happened to look at. Enumerating what these boundaries MAY carry
# cannot silently miss a capability that does not exist yet: a new effect is
# rejected until someone decides it belongs, which is the safe direction.
#
# Exception is what the contract requires. Async is admitted because it is
# already used here (2 rows in preprocess_compile.vibe) and grants no host
# access by itself -- it is a scheduling effect, not a capability. Adding to
# this list is a deliberate act; that is the property being enforced.
PORTABLE_ALLOWED_EFFECTS='Exception|Async'

# Reject any effect row on a pure boundary that names something outside the
# allow-list. Comment lines are stripped first, as in forbid_pattern.
#
# Comments are dropped to end of line and the file flattened to one line before
# matching, for the same reason as forbid_capability_authority below: a row may
# be split after `+`. Measured -- this compiles, and a line-by-line scan matched
# `with Exception`, accepted it, and never associated the `Fs`:
#
#   fn probe() -> String with Exception +
#     Fs { ... }
forbid_foreign_effect_rows() { # <file> <label>
  local file="$1" label="$2" bad
  # An effect item may carry type arguments -- `parse_effect_item`
  # (lib/@vibe/parser/parser_base.vibe) accepts `Exception[String] + Fs`, and it
  # compiles. Matching bare identifiers stopped at the `[`, recorded the allowed
  # `Exception`, and never saw the `Fs`. The argument is dropped BEFORE the row
  # is split on `+`, so an argument that itself contains `+` cannot fragment
  # into pieces that match nothing and read as leaks.
  bad="$(sed 's://.*::' "$ROOT_DIR/$file" \
    | tr '\n' ' ' \
    | grep -oE 'with +[A-Z][A-Za-z0-9_]*(\[[^]]*\])?( *\+ *[A-Z][A-Za-z0-9_]*(\[[^]]*\])?)*' \
    | sed 's/^with  *//' \
    | sed 's/\[[^]]*\]//g' \
    | tr '+' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -vE "^($PORTABLE_ALLOWED_EFFECTS)$" \
    | sort -u)" || true
  if [ -n "$bad" ]; then
    echo "selfhost-portable-boundary: non-portable effect row in $label ($file)" >&2
    echo "$bad" | sed 's/^/  effect: /' >&2
    echo "  This boundary must stay in-memory. Drop the effect, or move the" >&2
    echo "  work behind a caller that already carries it. If the effect is" >&2
    echo "  genuinely portable, add it to PORTABLE_ALLOWED_EFFECTS with a" >&2
    echo "  reason -- deliberately, not to make this message go away." >&2
    exit 1
  fi
}

# The effect row is not the only way to reach a capability. `allows` grants
# capability AUTHORITY in the signature, separately from the row (ADR-0075/0084,
# #1961), and the granted operation is then called plainly -- not through
# `perform`:
#
#   fn main() -> String with () allows Fs::read_file { Fs::read_file("x") }
#
# so it matched neither the row allow-list nor `perform (Fs|...)::`, and the
# gate exited 0. Measured on preprocess_compile.vibe before this check.
#
# Neither pure boundary uses `allows` at all, so the allowed set here is empty:
# any capability authority is a leak by definition on a boundary whose contract
# is "stays in-memory". A capability name is CamelCase, which is what separates
# a real clause from English prose ("allows them to ..."); comment lines are
# stripped first regardless.
#
# The capability need not be adjacent to the keyword. Both of these compile
# (measured on a stage2 built from this checkout, `vibe test`):
#
#   fn probe() -> String with Exception allows
#     Fs::read_file { ... }              # newline
#   fn probe() -> String with Exception allows // note
#     Fs::read_file { ... }              # trailing comment, then newline
#
# so requiring adjacency on one line missed both. Comments are removed to end
# of line and the file is flattened to a single line before matching, which
# makes the check insensitive to whitespace and to anything commented out
# between the keyword and the capability. `/* ... */` needs no handling: vibe
# has no block comments, and that spelling does not parse at all
# (`expected an effect name in the effect row after 'with'`).
forbid_capability_authority() { # <file> <label>
  local file="$1" label="$2"
  if sed 's://.*::' "$ROOT_DIR/$file" \
    | tr '\n' ' ' \
    | grep -oE '\ballows +[A-Z][A-Za-z0-9_:]*' >/tmp/vibe_portable_authority_hits.$$; then
    echo "selfhost-portable-boundary: capability authority granted in $label ($file)" >&2
    sed 's/^/  granted: /' /tmp/vibe_portable_authority_hits.$$ >&2
    rm -f /tmp/vibe_portable_authority_hits.$$
    # Matching happens on the flattened file, so the match itself carries no
    # position. Point at every line holding the keyword, which is where the
    # edit goes.
    grep -nE '\ballows\b' "$ROOT_DIR/$file" | sed 's/^/  at /' >&2 || true
    echo '  An `allows` clause hands this boundary host authority, which is' >&2
    echo "  what it must not have. Move the capability to a caller that is" >&2
    echo "  allowed to hold it and pass the result in." >&2
    exit 1
  fi
  rm -f /tmp/vibe_portable_authority_hits.$$
}

# The boundary is declared in the package CONTRACT (`index.vpkg`, ADR-0070),
# not in an `index.vibe` facade -- and its effect row is spelled `with
# Exception`, not `with { Error }` (ADR-0085). This gate asserted the older
# form at the older path for long enough that both had gone: it reported
# "missing expected pure boundary" for files that no longer exist, while every
# boundary it names was intact in the contract beside them. Nothing caught it
# because the gate runs in no CI job (#2577).
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source\(source: String\) -> Bytes with Exception$' \
  "compile_source stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source_wasi\(source: String, entry_name: String\) -> Bytes with Exception$' \
  "compile_source_wasi stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/index.vpkg" \
  '^fn compile_source_wasi_mode\(source: String, entry_name: String, mode: String\) -> Bytes with Exception$' \
  "compile_source_wasi_mode stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  '^export fn compile_source_wasi_only\(source: String, entry_name: String\) -> Bytes with Exception' \
  "compile_source_wasi_only stays in-memory"
require_line \
  "lib/@vibe/compiler/entry/compiler/fs_compile/index.vpkg" \
  '^fn compile_with_closure_sources_wasi_mode_uncached\(main_source: String, main_path: String, sources: Array\[\(String, String\)\], entry_name: String, mode: String\) -> Bytes with Exception$' \
  "direct component closure compile stays in-memory"

forbid_pattern \
  "lib/@vibe/compiler/cli_direct_component_entry.vibe" \
  "$native_effect_pattern" \
  "direct component entry"
forbid_pattern \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "$native_effect_pattern" \
  "source compile API"
forbid_pattern \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "$native_effect_pattern" \
  "wasi source compile API"

# The row allow-list, on the two boundaries whose contract is "stays
# in-memory". Not applied to cli_direct_component_entry.vibe: that is the entry
# that DOES file IO and carries `with Exception + Fs` / `with Fs` legitimately
# at lines 304/322, so an allow-list there would fail the gate on correct code.
# It keeps forbid_pattern above, which bans the direct `perform Fs::` and the
# FS compile lane rather than the row.
forbid_foreign_effect_rows \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "source compile API"
forbid_foreign_effect_rows \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "wasi source compile API"

forbid_capability_authority \
  "lib/@vibe/compiler/entry/source_compile/source_compile.vibe" \
  "source compile API"
forbid_capability_authority \
  "lib/@vibe/compiler/entry/source_compile/wasi_only/preprocess_compile.vibe" \
  "wasi source compile API"

echo "selfhost portable boundary: ok"
