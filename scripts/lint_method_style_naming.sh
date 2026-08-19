#!/usr/bin/env bash
# vibe-lang naming-consistency lint (#1189, ADR-0081 "wave 2"): every
# package-owned type X's exported "recv-shaped" function --
# `fn name(recv: X, ...) -> ...` -- should have a `Type::name` qualified
# companion. That's what a `recv.name(...)` dot call resolves to
# (desugar_trait_dict.vibe) and what `vibe normalize` rewrites bare dot
# calls back to (#1194): a bare-only name is invisible to both.
#
# Scope: lib/@vibe/*/index.vpkg and lib/@vibex/*/index.vpkg, EXCLUDING
# lib/@vibe/compiler/ and lib/@vibe/cli/. Those two pervasively thread a
# big internal ctx/dispatch-state struct as a first parameter across
# hundreds of functions that are compiler-internal plumbing, not public
# "UFCS-style" API -- flagging those would be almost entirely false
# positives, so this lint doesn't look at compiler-internal code at all
# rather than trying to distinguish ctx params heuristically (the blocker
# named in #1189's "残作業" note).
#
# Only index.vpkg CONTRACT files are scanned, not raw impl .vibe sources:
# each package's index.vpkg is its authoritative, single-line-per-fn public
# surface listing, so it's both the right scope (only PUBLIC API matters
# for dot-call discoverability) and a far more regular format to parse
# reliably than arbitrary source spread across many impl files.
#
# This is a RATCHET, same shape as check_vibe_fmt.sh /
# vibe_fmt_allowlist.txt: scripts/method_style_naming_allowlist.txt
# grandfathers today's gaps (this lint was added well after most of the
# stdlib existed -- it is not this PR's job to fix 80+ pre-existing gaps
# across the tree). New gaps that aren't in the allowlist fail the gate.
#
# Known heuristic limitation (documented, not "fixed" -- see the allowlist
# comments for real examples): the companion name is assumed to be
# `Type::exact_same_name`. Some existing bare names use a different lowercase
# prefix than the type name itself (`set_union` -> `StringSet::union`, not
# `StringSet::set_union`), or the semantically correct qualifier isn't the
# first parameter's type at all (@vibe/json's `stringify_error(id: RpcId,
# ...)` is intentionally `RpcMessage::stringify_error`, not
# `RpcId::stringify_error`, since RpcId isn't what's being serialized). Both
# read as heuristic "violations" here; they're allowlisted with a note
# rather than taught to the regex, which would trade one hard-coded
# assumption for another.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_METHOD_NAMING_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
ALLOWLIST_FILE="${VIBE_METHOD_NAMING_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/method_style_naming_allowlist.txt}"
cd "$PROJECT_ROOT"

is_allowed() {
  local rel_path="$1"
  local fn_name="$2"
  [ -f "$ALLOWLIST_FILE" ] || return 1
  awk -F '\t' -v path="$rel_path" -v fn="$fn_name" '
    $0 == "" || $1 ~ /^#/ { next }
    $1 == path && $2 == fn { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$ALLOWLIST_FILE"
}

mapfile -t vpkgs < <(git ls-files 'lib/@vibe/*/index.vpkg' 'lib/@vibex/*/index.vpkg' \
  | grep -v '^lib/@vibe/compiler/' | grep -v '^lib/@vibe/cli/' | sort)

if [ "${#vpkgs[@]}" -eq 0 ]; then
  echo "method-style-naming lint: no index.vpkg files found under lib/@vibe or lib/@vibex" >&2
  exit 1
fi

new_violations=()
stale_allowlist=()
checked=0
known_debt=0

for vpkg in "${vpkgs[@]}"; do
  # 1. package-owned type names (bare, generics stripped by the char class),
  #    minus the language's own primitives. A contract may re-declare
  #    `type Int` / `type String` / ... so it reads as a self-contained
  #    surface -- @vibe/builtin does, under the comment "compiler-provided
  #    declarations intentionally exposed by this package" -- but re-declaring
  #    a name is not owning it: the `Int::` / `String::` namespaces belong to
  #    builtin_registry.vibe, and no package can add to them. Counting them as
  #    owned made every `fn f(s: String, ...)` in prelude a gap wanting a
  #    `String::f` companion, which is not a function anyone can write; 39 of
  #    the 49 violations this lint reported were that. `Byte`, `Parser`,
  #    `StringView` and the rest of prelude's types are genuinely its own and
  #    stay in scope, as does @vibe/wit_runtime's own `export enum Result`.
  mapfile -t types < <(grep -oE '^(export )?(opaque )?(type|struct|enum) [A-Z][A-Za-z0-9_]*' "$vpkg" \
    | sed -E 's/^(export )?(opaque )?(type|struct|enum) //' \
    | grep -vxE 'Int|Float|Double|Bool|String|Char|Unit|Bytes|Array|Option')
  [ "${#types[@]}" -eq 0 ] && continue
  type_alt="$(IFS='|'; echo "${types[*]}")"

  # 2. Type::method names already declared in this package's contract
  mapfile -t qualified < <(grep -oE "^fn (${type_alt})::[a-zA-Z_][a-zA-Z0-9_]*" "$vpkg" \
    | sed -E 's/^fn //')

  # 3. bare recv-shaped fns: `fn name(recv: OwnType[...]?, ...)`
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    fn_name="$(echo "$line" | sed -E 's/^fn ([a-zA-Z_][a-zA-Z0-9_]*)\(.*/\1/')"
    recv_type="$(echo "$line" | sed -E 's/^fn [a-zA-Z_][a-zA-Z0-9_]*\([a-zA-Z_][a-zA-Z0-9_]*: ([A-Z][A-Za-z0-9_]*).*/\1/')"
    # already Type::-prefixed (checker builtin ctors etc.) -- not a gap
    case "$fn_name" in
      *::*) continue ;;
    esac
    checked=$((checked + 1))
    is_gap=1
    for want in "${qualified[@]}"; do
      if [ "$want" = "${recv_type}::${fn_name}" ]; then
        is_gap=0
        break
      fi
    done
    if [ "$is_gap" -eq 1 ]; then
      if is_allowed "$vpkg" "$fn_name"; then
        known_debt=$((known_debt + 1))
      else
        new_violations+=("$vpkg: $fn_name(recv: $recv_type, ...)")
      fi
    else
      if is_allowed "$vpkg" "$fn_name"; then
        stale_allowlist+=("$vpkg $fn_name")
      fi
    fi
  done < <(grep -E "^fn [a-zA-Z_][a-zA-Z0-9_]*\([a-zA-Z_][a-zA-Z0-9_]*: (${type_alt})(\[[^]]*\])?(,|\))" "$vpkg")
done

status=0

if [ "${#stale_allowlist[@]}" -gt 0 ]; then
  echo "method-style-naming lint: note -- these allowlist entries now have a Type::method companion; remove them from $ALLOWLIST_FILE to shrink the ratchet:" >&2
  printf '  %s\n' "${stale_allowlist[@]}" >&2
fi

if [ "${#new_violations[@]}" -gt 0 ]; then
  echo "method-style-naming lint: found ${#new_violations[@]} new function(s) without a Type::method companion:" >&2
  printf '  %s\n' "${new_violations[@]}" >&2
  echo "method-style-naming lint: add an export fn Type::name(recv, ...) companion, or a justified entry in $ALLOWLIST_FILE" >&2
  status=1
fi

echo "method-style-naming lint: checked $checked recv-shaped fn(s) across ${#vpkgs[@]} package(s) ($known_debt known debt, ${#new_violations[@]} new violations)"
exit "$status"
