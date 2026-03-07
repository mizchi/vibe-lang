#!/usr/bin/env bash
# P4 gate: lexer.vibe/parser.vibe can be compiled to WASM and run in wasmtime
set -euo pipefail

VIBE="${VIBE_EXE:-_build/native/debug/build/cmd/vibe/vibe.exe}"
TMPDIR="${TMPDIR:-/tmp}"
OUT_DIR="$TMPDIR/p4_gate_$$"
FIXTURE_DIR="vibe/compiler"

mkdir -p "$OUT_DIR"
cleanup() {
  rm -rf "$OUT_DIR"
  rm -f "$FIXTURE_DIR/.tmp_p4_gate_"*.vibe
}
trap cleanup EXIT

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== P4 Gate: lexer.vibe → WASM → wasmtime ==="

# --- MoonBit codegen: compile lexer.vibe imports + assert-based main → WASM → wasmtime ---

# Test 1: token count
cat > "$FIXTURE_DIR/.tmp_p4_gate_count.vibe" << 'EOF'
import ./token.vibe { Token }
import ./lexer.vibe { lex }
let main = () -> Int with { Error } {
  let tokens = lex("42")
  assert(array_length(tokens) == 2)
  0
}
EOF
check "compile: lex(\"42\") count==2" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_count.vibe" -o "$OUT_DIR/count.wasm"
check "run: lex(\"42\") count==2" \
  wasmtime run -W exceptions=y "$OUT_DIR/count.wasm"

# Test 2: TInt value
cat > "$FIXTURE_DIR/.tmp_p4_gate_tint.vibe" << 'EOF'
import ./token.vibe { Token }
import ./lexer.vibe { lex }
let main = () -> Int with { Error } {
  let tokens = lex("42")
  let t = array_get(tokens, 0)
  match t {
    TInt(n) => { assert(n == 42); 0 },
    _ => { assert(false); 1 }
  }
}
EOF
check "compile: lex(\"42\") TInt==42" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_tint.vibe" -o "$OUT_DIR/tint.wasm"
check "run: lex(\"42\") TInt==42" \
  wasmtime run -W exceptions=y "$OUT_DIR/tint.wasm"

# Test 3: multi-token (1 + 2 * 3 => TInt TPlus TInt TStar TInt TEof = 6)
cat > "$FIXTURE_DIR/.tmp_p4_gate_multi.vibe" << 'EOF'
import ./token.vibe { Token }
import ./lexer.vibe { lex }
let main = () -> Int with { Error } {
  let tokens = lex("1 + 2 * 3")
  assert(array_length(tokens) == 6)
  0
}
EOF
check "compile: lex(\"1+2*3\") count==6" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_multi.vibe" -o "$OUT_DIR/multi.wasm"
check "run: lex(\"1+2*3\") count==6" \
  wasmtime run -W exceptions=y "$OUT_DIR/multi.wasm"

# Test 4: string literal (let x = "hello" => TLet TIdent TEq TString TEof = 5)
cat > "$FIXTURE_DIR/.tmp_p4_gate_string.vibe" << 'VIBEEOF'
import ./token.vibe { Token }
import ./lexer.vibe { lex }
let main = () -> Int with { Error } {
  let tokens = lex("let x = \"hello\"")
  assert(array_length(tokens) == 5)
  0
}
VIBEEOF
check "compile: lex(string literal) count==5" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_string.vibe" -o "$OUT_DIR/string.wasm"
check "run: lex(string literal) count==5" \
  wasmtime run -W exceptions=y "$OUT_DIR/string.wasm"

# Test 5: lex function definition
cat > "$FIXTURE_DIR/.tmp_p4_gate_fn.vibe" << 'EOF'
import ./token.vibe { Token }
import ./lexer.vibe { lex }
let main = () -> Int with { Error } {
  let tokens = lex("let add = (a: Int, b: Int) -> Int { a + b }")
  // TLet TIdent TEq TLParen TIdent TColon TIdent TComma TIdent TColon TIdent TRParen TArrow TIdent TLBrace TIdent TPlus TIdent TRBrace TEof
  assert(array_length(tokens) == 20)
  0
}
EOF
check "compile: lex(function def) count==20" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_fn.vibe" -o "$OUT_DIR/fn.wasm"
check "run: lex(function def) count==20" \
  wasmtime run -W exceptions=y "$OUT_DIR/fn.wasm"

# --- parser.vibe: lex + parse → WASM → wasmtime ---
echo ""
echo "--- parser.vibe → WASM → wasmtime ---"

# Test 6: parse simple expression
cat > "$FIXTURE_DIR/.tmp_p4_gate_parse1.vibe" << 'EOF'
import ./token.vibe { Token }
import ./ast.vibe { Expr, Stmt, Pat, TypeExpr }
import ./lexer.vibe { lex }
import ./parser.vibe { parse_program }
let main = () -> Int with { Error } {
  let tokens = lex("1 + 2")
  let stmts = parse_program(tokens)
  assert(array_length(stmts) == 1)
  0
}
EOF
check "compile: parse(\"1+2\") stmts==1" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_parse1.vibe" -o "$OUT_DIR/parse1.wasm"
check "run: parse(\"1+2\") stmts==1" \
  wasmtime run -W exceptions=y "$OUT_DIR/parse1.wasm"

# Test 7: parse let binding
cat > "$FIXTURE_DIR/.tmp_p4_gate_parse2.vibe" << 'EOF'
import ./token.vibe { Token }
import ./ast.vibe { Expr, Stmt, Pat, TypeExpr }
import ./lexer.vibe { lex }
import ./parser.vibe { parse_program }
let main = () -> Int with { Error } {
  let tokens = lex("let x = 42\nlet y = x + 1")
  let stmts = parse_program(tokens)
  assert(array_length(stmts) == 2)
  0
}
EOF
check "compile: parse(let bindings) stmts==2" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_parse2.vibe" -o "$OUT_DIR/parse2.wasm"
check "run: parse(let bindings) stmts==2" \
  wasmtime run -W exceptions=y "$OUT_DIR/parse2.wasm"

# Test 8: parse function definition
cat > "$FIXTURE_DIR/.tmp_p4_gate_parse3.vibe" << 'EOF'
import ./token.vibe { Token }
import ./ast.vibe { Expr, Stmt, Pat, TypeExpr }
import ./lexer.vibe { lex }
import ./parser.vibe { parse_program }
let main = () -> Int with { Error } {
  let tokens = lex("let add = (a: Int, b: Int) -> Int { a + b }")
  let stmts = parse_program(tokens)
  assert(array_length(stmts) == 1)
  // Verify it's a SLet with EFn body
  match array_get(stmts, 0) {
    SLet(_, _, _, _, _) => 0,
    _ => { assert(false); 1 }
  }
}
EOF
check "compile: parse(function def)" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_parse3.vibe" -o "$OUT_DIR/parse3.wasm"
check "run: parse(function def)" \
  wasmtime run -W exceptions=y "$OUT_DIR/parse3.wasm"

# --- Full compiler pipeline: lex + parse + codegen → WASM → wasmtime ---
echo ""
echo "--- Full compiler pipeline (codegen.vibe → WASM → wasmtime) ---"

# Test: selfhost codegen compiles "let main = () -> Int { 42 }" inside WASM
cat > "$FIXTURE_DIR/.tmp_p4_gate_full.vibe" << 'EOF'
import ./token.vibe { Token }
import ./ast.vibe { Expr, Stmt, Pat, TypeExpr }
import ./lexer.vibe { lex }
import ./parser.vibe { parse_program }
import ./codegen.vibe { compile_wasi_module }
let main = () -> Int with { Error } {
  let tokens = lex("let main = () -> Int { 42 }")
  let stmts = parse_program(tokens)
  let bytes = compile_wasi_module(stmts, "main")
  assert(bytes_length(bytes) > 8)
  // WASM magic: \0asm
  assert(bytes_get(bytes, 0) == 0)
  assert(bytes_get(bytes, 1) == 97)
  assert(bytes_get(bytes, 2) == 115)
  assert(bytes_get(bytes, 3) == 109)
  0
}
EOF
check "compile: full pipeline (codegen.vibe)" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_full.vibe" -o "$OUT_DIR/full.wasm"
check "validate: full pipeline" \
  wasm-tools validate "$OUT_DIR/full.wasm"
check "run: full pipeline (WASM generating WASM)" \
  wasmtime run -W exceptions=y "$OUT_DIR/full.wasm"

# Test: codegen with function calls
cat > "$FIXTURE_DIR/.tmp_p4_gate_full2.vibe" << 'EOF'
import ./token.vibe { Token }
import ./ast.vibe { Expr, Stmt, Pat, TypeExpr }
import ./lexer.vibe { lex }
import ./parser.vibe { parse_program }
import ./codegen.vibe { compile_wasi_module }
let main = () -> Int with { Error } {
  let src = "let add = (a: Int, b: Int) -> Int { a + b }\nlet main = () -> Int { add(20, 22) }"
  let tokens = lex(src)
  let stmts = parse_program(tokens)
  let bytes = compile_wasi_module(stmts, "main")
  assert(bytes_length(bytes) > 100)
  0
}
EOF
check "compile: codegen with functions" \
  "$VIBE" compile --wasm "$FIXTURE_DIR/.tmp_p4_gate_full2.vibe" -o "$OUT_DIR/full2.wasm"
check "run: codegen with functions" \
  wasmtime run -W exceptions=y "$OUT_DIR/full2.wasm"

echo ""
echo "=== P4 Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
