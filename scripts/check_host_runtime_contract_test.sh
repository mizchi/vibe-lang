#!/usr/bin/env bash
# Red test for scripts/check_host_runtime_contract.vibex (#2248). #3672 ported
# the gate and this suite from Python
# (tests/gates/tooling-accounting/host-runtime/host_runtime_contract_test.py,
# which called the gate's functions in-process).
#
# Each case copies the files the gate reads -- the manifest and the source
# groups of the emitter, viberun, the node runner, the gc backend, and the
# operation ladder -- into a tree under _build/, mutates ONE thing, and asserts
# the gate fails for that mutation's own reason. The unmutated tree must pass
# first, and every mutation is checked for having LANDED (a mutation that
# matches nothing would pass while proving nothing).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_host_runtime_contract.vibex"
# The gate reads only inside the repository, so the trees live under _build/.
WORK="_build/host_runtime_contract_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "host-runtime-contract-test: FAIL: $*" >&2; exit 1; }
pass() { echo "host-runtime-contract-test: ok: $*"; }

# The files the gate reads, at their tree paths.
BASE="$WORK/base"
mkdir -p "$BASE/docs/generated" "$BASE/lib/@vibe/compiler/codegen/wasi" "$BASE/lib/@vibe/compiler/codegen/gc" \
  "$BASE/lib/@vibe/compiler/core" "$BASE/runtime/viberun/src" "$BASE/scripts"
cp docs/generated/host-runtime-contract.json "$BASE/docs/generated/"
cp lib/@vibe/compiler/codegen/wasi/*.vibe "$BASE/lib/@vibe/compiler/codegen/wasi/"
cp lib/@vibe/compiler/codegen/gc/*.vibe "$BASE/lib/@vibe/compiler/codegen/gc/"
cp lib/@vibe/compiler/core/builtin_name.vibe "$BASE/lib/@vibe/compiler/core/"
cp runtime/viberun/src/*.rs "$BASE/runtime/viberun/src/"
cp scripts/wasm_vibe_host_*.js "$BASE/scripts/"

tree() { # <name>: a fresh copy of the base tree
  rm -rf "${WORK:?}/$1"
  cp -R "$BASE" "$WORK/$1"
}

run_gate() { # <tree name>
  bash scripts/vibe_run.sh "$GATE" -- --root "$WORK/$1" >"$WORK/out" 2>&1
}

# <tree> <dir under the tree> <mode> <old> <new>
#   mode `once`: replace the first occurrence of OLD, in the first file of DIR
#   (by name) that holds it; `re`: the same with OLD a Python regex.
# Fails when nothing matched.
mutate() {
  python3 - "$WORK/$1/$2" "$3" "$4" "$5" <<'PYEOF'
import pathlib, re, sys
where, mode, old, new = sys.argv[1:]
paths = [pathlib.Path(where)] if pathlib.Path(where).is_file() else sorted(p for p in pathlib.Path(where).iterdir() if p.is_file())
for path in paths:
    text = path.read_text(encoding="utf-8")
    if mode == "once" and old in text:
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
        sys.exit(0)
    if mode == "re" and re.search(old, text, re.S):
        path.write_text(re.sub(old, new, text, count=1, flags=re.S), encoding="utf-8")
        sys.exit(0)
sys.stderr.write("host-runtime-contract-test: mutation did not land: %r in %s\n" % (old, where))
sys.exit(2)
PYEOF
}

# <case> <tree> <needle>
expect_red() {
  if run_gate "$2"; then
    cat "$WORK/out" >&2
    fail "$1: the gate passed -- it cannot see that defect"
  fi
  grep -qF -- "$3" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "$1 failed, but not for its own reason (wanted: $3)"; }
  pass "$1"
}

MANIFEST="docs/generated/host-runtime-contract.json"
WASI="lib/@vibe/compiler/codegen/wasi"
GC="lib/@vibe/compiler/codegen/gc"
RUST="runtime/viberun/src"
LADDER="lib/@vibe/compiler/core/builtin_name.vibe"

# --- control ------------------------------------------------------------------

tree control
run_gate control || { cat "$WORK/out" >&2; fail "control: the unmutated tree is rejected, so every red case below would prove nothing"; }
# Not merely "did not fail": pin the counts a reader that matched nothing would
# not reach. 24 gc host imports is a deliberate literal: it moves only when a
# host import is really added or removed (22 -> 23 with fs_remove_tree in
# #2758, 23 -> 24 with stdout_write_char).
grep -qF "24 gc host imports" "$WORK/out" || fail "control: the gc import count moved: $(cat "$WORK/out")"
python3 - "$WORK/out" <<'PYEOF' || fail "control: a reader matched far fewer rows than the tree defines: $(cat "$WORK/out")"
import re, sys
text = open(sys.argv[1]).read()
sigs = int(re.search(r"(\d+) viberun signatures", text).group(1))
bindings = int(re.search(r"(\d+) linear builtin bindings", text).group(1))
ops = int(re.search(r"(\d+) operations reach", text).group(1))
sys.exit(0 if sigs >= 40 and bindings >= 70 and ops >= 24 else 1)
PYEOF
pass "control: the copied tree passes, with every reader seeing the tree's rows"

# --- the manifest ---------------------------------------------------------------

tree m1
mutate m1 "$MANIFEST" once '"env-get": "3"' '"env-get": "5"'
expect_red "an import's type id reassigned in the contract" m1 "emitter signature drift: missing=[] extra=[] changed=['env-get']"

tree m2
mutate m2 "$MANIFEST" once '"namesArray": "hf_named_names"' '"namesArray": "hf_other_names"'
expect_red "a dynamic import pattern drifting from the emitter" m2 "dynamic emitter drift"

tree m3
mutate m3 "$MANIFEST" once '"pattern": "host_future_get$<name>"' '"pattern": "host_future_got$<name>"'
expect_red "a dynamic pattern disagreeing with its prefix" m3 "dynamic manifest pattern disagrees with prefix"

tree m4
mutate m4 "$MANIFEST" once '"resolve_path"' '"resolve_path",
    "env-get"'
expect_red "an import in two bands" m4 "imports occur in multiple bands"

tree m5
mutate m5 "$MANIFEST" once '"viberunDebugOnly"' '"viberunDebugOnlyX"'
expect_red "a band key missing" m5 "manifest missing keys: ['viberunDebugOnly']"

tree m6
printf '{"schema": 1,' > "$WORK/m6/$MANIFEST"
expect_red "a manifest that is not JSON" m6 "invalid manifest"

tree m7
mutate m7 "$MANIFEST" once '"3": "(i64) -> i64"' '"33": "(i64) -> i64"'
expect_red "an emitted type index the contract does not describe" m7 "emitter uses undocumented type indices: ['3']"

# --- viberun ------------------------------------------------------------------

# fs_read_file's closure: one real provider, the mutation site below.
anchor="|mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {"

tree r1
mutate r1 "$RUST" re '(linker\.func_wrap\(\s*"vibe",\s*)"compiler_lowering_run"' '\1"missing_lowering_service"'
expect_red "the native lowering service missing from viberun" r1 "viberun lacks native core imports: ['compiler_lowering_run']"

tree r2
mutate r2 "$RUST" once "$anchor" "|mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {"
expect_red "a provider's result type drifting from the emitter" r2 "viberun provider signatures disagree with the emitter"

tree r3
mutate r3 "$RUST" once "$anchor" "|mut caller: Caller<'_, HostState>| -> Result<i64> {"
expect_red "a provider dropping a parameter" r3 "viberun provider signatures disagree with the emitter"

tree r4
mutate r4 "$RUST" once "$anchor" "|mut caller: Caller<'_, HostState>, path: i64, extra: i64| -> Result<i64> {"
expect_red "a provider gaining a parameter" r4 "viberun provider signatures disagree with the emitter"

tree r5
mutate r5 "$RUST" once "$anchor" "|mut caller: Caller<'_, HostState>, path: SomeOpaqueType| -> Result<i64> {"
expect_red "a provider closure the gate cannot read" r5 "viberun provider signatures not understood"

# --- the node runner ----------------------------------------------------------

tree n1
mutate n1 scripts/wasm_vibe_host_runner.js once '["env-get"](nameTagged) {' 'compiler_lowering_run(count) { return count; },
      ["env-get"](nameTagged) {'
expect_red "the native service leaking into the node provider" n1 "native-core-only imports leaked into the node provider"

tree n2
mutate n2 scripts/wasm_vibe_host_runner.js once '["env-get"](nameTagged) {' '["env-gex"](nameTagged) {'
expect_red "the node runner losing a portable import" n2 "node runner lacks portable imports: ['env-get']"

# --- the wasm-gc backend (#2759) ----------------------------------------------

tree g1
mutate g1 "$GC" once '("Console::write_stream", 1, 16, 0)' '("Console::write_stream", 1, 5, 0)'
expect_red "a stdout alias pointing at another index" g1 "must alias Stdout::write_stream"

tree g2
mutate g2 "$GC" once ' || Map::has_key(used_builtins, key = "Fs::is_dir")' ''
expect_red "use_host losing a builtin" g2 "gc use_host/host_defs drift"

tree g3
mutate g3 "$GC" once '("Fs::exists", 1, 5, 1)' '("Fs::exists", 1, 9, 1)'
expect_red "a host_defs index out of order" g3 "repeats import index 9"

tree g4
mutate g4 "$GC" once '      ("fs_exists", 3),
' ''
expect_red "host_imports losing an entry" g4 "gc host_imports has 23 entries for 24 host imports"

# hbo is an OFFSET: corrupting it leaves every name present. Mutating it alone
# is also caught by the header check, so move hbo AND the header together --
# the realistic desync, and the one only `hbo == len(host_defs)` sees.
tree g5
mutate g5 "$GC" re '(let hbo = if use_host \{\s*\n\s*)24' '\g<1>23'
mutate g5 "$GC" re '(bytebuf_push_vec_header\(buf = imp_content,\s*count = )25' '\g<1>24'
expect_red "hbo desynced from host_defs, header moved with it" g5 "gc hbo is 23 for 24 host imports"

tree g6
mutate g6 "$GC" re '(bytebuf_push_vec_header\(buf = imp_content,\s*count = )25' '\g<1>24'
expect_red "the import vector header off by one" g6 "gc import vector header is 24, expected hbo + 1 = 25"

tree g7
mutate g7 "$GC" once '("fs_exists", 3)' '("fs_exists_typo", 3)'
expect_red "a host_imports name renamed on one side" g7 "gc host_imports[5] is 'fs_exists_typo', expected 'fs_exists'"

# Import ORDER fixes the wasm function indices, so swapping two entries of the
# same ABI type validates and calls the wrong host function (Codex on #2765).
tree g8
mutate g8 "$GC" once '      ("fs_is_dir", 3),
      ("fs_is_file", 3),' '      ("fs_is_file", 3),
      ("fs_is_dir", 3),'
expect_red "two same-typed host imports swapped" g8 "gc host_imports["

tree g9
mutate g9 "$GC" once '("fs_exists", 3)' '("fs_exists", 5)'
expect_red "a host import's ABI type disagreeing with the contract" g9 "gc host_imports 'fs_exists' declares ABI type 5, but the contract says 3"

# An APPEND only the count can catch: the positional check stops at the
# shorter list. The name is one the contract knows.
tree g10
mutate g10 "$GC" re '(let host_imports = \[.*?)(\n    \])' '\1,\n      ("fs_exists", 3)\2'
expect_red "host_imports gaining an entry" g10 "gc host_imports has 25 entries for 24 host imports"

# Renamed consistently across the three gc lists: only band membership sees it.
tree g11
mutate g11 "$GC" once 'Map::has_key(used_builtins, key = "Fs::exists")' 'Map::has_key(used_builtins, key = "Fs::invented")'
mutate g11 "$GC" once '("Fs::exists", 1, 5, 1)' '("Fs::invented", 1, 5, 1)'
mutate g11 "$GC" once '("fs_exists", 3)' '("fs_invented", 3)'
expect_red "an import the contract's bands do not know" g11 "gc host_imports names absent from the host-runtime contract: ['fs_invented']"

tree g12
mutate g12 "$GC" once '("Fs::exists", 1, 5, 1)' '("Fs::exists", 0, 5, 1)'
expect_red "a host_def's arity drifting from its import's signature" g12 "gc host_defs 'Fs::exists' declares 0 param(s)/ret=1"

tree g13
mutate g13 "$GC" once '("Fs::exists", 1, 5, 1)' '("Fs::exists", 1, 5, 0)'
expect_red "a host_def's return drifting from its import's signature" g13 "gc host_defs 'Fs::exists' declares 1 param(s)/ret=0"

# --- the linear lane's operation identity (#1962) ------------------------------

# The swap the set comparison could not see: both are type 3.
tree l1
mutate l1 "$WASI" once '"Fs::is_dir" => fs_is_dir_idx,' '@@A@@'
mutate l1 "$WASI" once '"Fs::is_file" => fs_is_file_idx,' '"Fs::is_file" => fs_is_dir_idx,'
mutate l1 "$WASI" once '@@A@@' '"Fs::is_dir" => fs_is_file_idx,'
expect_red "two same-typed builtin bindings swapped" l1 'linear lane: `Fs::is_dir` is bound to vibe.fs_is_file, expected vibe.fs_is_dir'

tree l2
python3 - "$WORK/l2/$WASI/linked_compile_module_sections.vibe" <<'PYEOF' || fail "the emission-order mutation did not land"
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
start = s.index('  if fs_is_dir_import_idx >= 0 {\n    emit_name(buf = import_content, name = "vibe")')
end = s.index('  if fs_is_file_import_idx >= 0 {\n    emit_name(buf = import_content, name = "vibe")')
block, rest = s[start:end], s[end:]
close = rest.index("\n  }\n") + len("\n  }\n")
open(path, "w", encoding="utf-8").write(s[:start] + rest[:close] + block + rest[close:])
PYEOF
expect_red "imports emitted out of their reservation order" l2 "imports are emitted in a different order from their index reservation"

# ADR-0120: the readers canonicalize ONLY the label each helper's slot carries.
# A wrong label is left in place, so the row it spells is not read.
tree w1
mutate w1 "$WASI" once 'emit_name(buf = import_content, name = "vibe")' 'emit_name(other = import_content, name = "vibe")'
expect_red "an emitter argument under a wrong label" w1 "emitter signature drift: missing=['env-get']"

tree w2
mutate w2 "$GC" re '(bytebuf_push_vec_header\(buf = imp_content,\s*)count = 25' '\g<1>size = 25'
expect_red "the gc import vector header count under a wrong label" w2 "could not find the gc backend's import vector header"

tree l3
mutate l3 "$LADDER" once '"Fs::IsDir" => "Fs::is_dir",' '"Fs::IsDir" => "Fs::is_file",'
expect_red "an operation ladder row renamed" l3 'operation ladder: `Fs::IsDir` maps to `Fs::is_file`, expected `Fs::is_dir`'

tree l4
mutate l4 "$WASI" once '"Fs::is_dir" => fs_is_dir_idx,' ''
expect_red "an operation whose builtin binds no import" l4 'operation ladder: `Fs::IsDir` -> `Fs::is_dir` reaches no vibe import'

# Renamed to the builtin whose mechanical import IS the one it is bound to
# (`vibe.sleep`), so every binding still checks and only the exception goes
# stale.
tree l5
mutate l5 "$WASI" once '"sleep_blocking" =>' '"sleep" =>'
expect_red "a stale import-name exception" l5 "linear_exceptions() in scripts/check_host_runtime_contract.vibex names builtins with no binding: ['sleep_blocking']"

# --- the strict ABI signature parser ------------------------------------------
#
# Codex on #2768: a parser that split on `->` and inferred the rest gave every
# malformed form a shape. Codex on #2770: a value-type class of `[a-z][a-z0-9]*`
# accepted `(i65) -> i64` and `(string) -> bool`. Every accepted form is listed
# with its shape, every rejected one must say REJECT.
cat > "$WORK/signatures" <<'EOF'
(i64) -> i64
() -> ()
(i64, i64) -> ()
() -> i64
(i32, i32) -> ()
(i64, i64, i64, i64) -> i64
(f64) -> f32
()
(i64)
i64 -> i64

(i64) => i64
(i64) ->
(,) -> i64
(i64 i64) -> i64
(i65) -> i64
(string) -> bool
(zzz) -> qqq
(i64) -> i65
(I64) -> i64
(i64, i65) -> ()
EOF
cat > "$WORK/signatures.want" <<'EOF'
1 1
0 0
2 0
0 1
2 0
4 1
1 1
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
REJECT
EOF
bash scripts/vibe_run.sh "$GATE" -- --check-signatures "$WORK/signatures" >"$WORK/signatures.got" 2>"$WORK/signatures.err" \
  || { cat "$WORK/signatures.err" >&2; fail "--check-signatures failed"; }
diff "$WORK/signatures.want" "$WORK/signatures.got" >&2 \
  || fail "the signature parser accepted or rejected the wrong forms"
pass "the signature parser accepts the 7 ABI forms and rejects the 14 that are not"

echo "host-runtime-contract-test: ok (control + 34 red cases + the signature parser)"
