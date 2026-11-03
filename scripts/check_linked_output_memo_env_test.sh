#!/usr/bin/env bash
# Self-test for check_linked_output_memo_env.vibex (#2825). Each rule is proved
# Red on a tree built to violate it, and the real tree is proved Red once its
# memo key loses a variable the compiler reads, so the gate cannot quietly stop
# checking (#2248).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# The gate reads only inside the repository, so the trees live under _build/.
WORK_REL="_build/linked_output_memo_env_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
MEMO_REL="lib/@vibe/compiler/entry/compiler/file_compile/linked_output_memo.vibe"
gate() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_linked_output_memo_env.vibex -- "$@"; }
fails=0

# $1 = expected exit, $2 = what it proves, $3 = substring the output must have,
# then the gate's arguments.
expect() {
  local want="$1" what="$2" needle="$3" out rc
  shift 3
  out="$(gate "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "linked-output-memo-env self-test: FAIL: $what -- exit $rc, wanted $want"; echo "$out" | sed 's/^/    /'
    fails=$((fails + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "linked-output-memo-env self-test: FAIL: $what -- output did not mention '$needle'"; echo "$out" | sed 's/^/    /'
    fails=$((fails + 1)); return
  fi
  echo "  ok: $what"
}

# A tree with a memo file that keys ten names and exempts one.
fresh() {
  rm -rf "$WORK/t"
  mkdir -p "$WORK/t/lib/@vibe/x" "$WORK/t/lib/@vibe/x/tests"
  {
    echo 'export fn linked_output_memo_env_names() -> Array[String] {'
    echo '  ['
    for n in 0 1 2 3 4 5 6 7 8 9; do echo "    \"VIBE_K$n\","; done
    echo '  ]'
    echo '}'
    echo 'export fn linked_output_memo_env_exempt() -> Array[String] {'
    echo '  ['
    echo '    "VIBE_OUT"'
    echo '  ]'
    echo '}'
  } > "$WORK/t/memo.vibe"
  printf 'fn f() -> String with Env {\n  Env::get("VIBE_K0") + Env::get("VIBE_OUT")\n}\n' > "$WORK/t/lib/@vibe/x/a.vibe"
}
run() { expect "$1" "$2" "$3" --root "$WORK_REL/t" --memo "$WORK_REL/t/memo.vibe"; }

fresh
run 0 "a tree whose every variable is classified passes" "ok"

fresh
printf 'fn g() -> String with Env {\n  Env::get("VIBE_NEW")\n}\n' > "$WORK/t/lib/@vibe/x/b.vibe"
run 1 "a variable in neither list fails, by name and file" "VIBE_NEW (mentioned in $WORK_REL/t/lib/@vibe/x/b.vibe)"

fresh
printf 'fn g() -> String with Env {\n  read_env(name = "HOME")\n}\n' > "$WORK/t/lib/@vibe/x/b.vibe"
run 1 "a labeled read_env argument is a read too" "HOME (mentioned in"

fresh
printf 'let flags = ["VIBE_LISTED"]\n' > "$WORK/t/lib/@vibe/x/b.vibe"
run 1 "a VIBE_ literal outside a call counts (names passed to a wrapper)" "VIBE_LISTED"

fresh
sed -i.bak 's/"VIBE_OUT"/"VIBE_K3"/' "$WORK/t/memo.vibe" && rm -f "$WORK/t/memo.vibe.bak"
grep -qF '"VIBE_K3"' "$WORK/t/memo.vibe" || { echo "linked-output-memo-env self-test: FAIL: the both-lists mutation did not land"; fails=$((fails + 1)); }
printf 'fn g() -> String with Env {\n  Env::get("VIBE_K3")\n}\n' > "$WORK/t/lib/@vibe/x/b.vibe"
run 1 "a variable both keyed and exempt fails" "VIBE_K3 is both part of the key and exempt"

fresh
printf 'fn g(x: String) -> String with Env {\n  Env::get("VIBE_" + x)\n}\n' > "$WORK/t/lib/@vibe/x/b.vibe"
run 1 "a name assembled at run time fails" "built at run time"

fresh
printf '// Env::get("VIBE_IN_COMMENT")\n/// "VIBE_DOC"\nfn g() -> Int {\n  0\n}\n' > "$WORK/t/lib/@vibe/x/b.vibe"
run 0 "a name only in a comment is not a read" "ok"

fresh
printf 'fn g() -> String with Env {\n  Env::get("VIBE_ONLY_IN_TESTS")\n}\n' > "$WORK/t/lib/@vibe/x/tests/b_test.vibe"
printf 'fn g() -> String with Env {\n  Env::get("VIBE_ONLY_IN_BUNDLE")\n}\n' > "$WORK/t/lib/@vibe/x/compiler_sources_bundle.vibe"
run 0 "tests and generated bundles are not scanned" "ok"

fresh
printf 'fn g() -> Int {\n  0\n}\n' > "$WORK/t/memo.vibe"
run 1 "a memo file whose lists cannot be read fails" "could not read the two variable lists"

# The real tree: green as committed, Red once the key drops a variable the
# compiler really reads.
expect 0 "the committed tree passes" "ok"
mkdir -p "$WORK/real"
sed '/^    "VIBE_RC",$/d' "$MEMO_REL" > "$WORK/real/memo.vibe"
if grep -q '^    "VIBE_RC",$' "$WORK/real/memo.vibe" || ! grep -q '^    "VIBE_RC",$' "$MEMO_REL"; then
  echo "linked-output-memo-env self-test: FAIL: the VIBE_RC deletion did not land"; fails=$((fails + 1))
else
  expect 1 "the real tree fails once the key drops VIBE_RC" "VIBE_RC (mentioned in" --memo "$WORK_REL/real/memo.vibe"
fi

if [ "$fails" -ne 0 ]; then
  echo "linked-output-memo-env self-test: $fails failure(s)"
  exit 1
fi
echo "linked-output-memo-env self-test: ok"
