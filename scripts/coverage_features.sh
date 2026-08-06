#!/usr/bin/env bash
# Feature-program coverage (#cov): compile a spread of small but feature-diverse
# programs (traits/impls, structs/records, mut captures, assign-ops, nested/guard/
# struct/or patterns, pipes, effects+handlers, suberror, derive, builders, loops,
# let*) with the instrumented compiler_cov.wasm and union each run's bitmap into
# the corpus acc.json. Targets the parser (parse_impl_block/parse_postfix/
# parse_type_impl/parse_pattern), checker (check_expr/analyze_calls/
# namespace_private_value_stmts), and codegen (compile_call/compile_expr/
# compile_match/compile_lambda/emit_assignop_op) clusters the bulk corpus leaves
# dark. Reuses the corpus's instrumented compiler; no full corpus re-run needed.
set -uo pipefail
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
OUT="_build/coverage/selfhost-corpus"
COMP="$OUT/compiler_cov.wasm"
ACC="$OUT/acc.json"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
RUN_JSON="$OUT/feat_run.json"
[ -s "$COMP" ] || { echo "features: instrumented compiler not found; run corpus first" >&2; exit 1; }
[ -s "$ACC" ] || { echo "features: corpus acc not found" >&2; exit 1; }
D="_build/covfeat"; rm -rf "$D"; mkdir -p "$D"

acc_run() { # mode file entry
  rm -f "$RUN_JSON"
  local env_pfx="VIBE_FS_COMPILE=1"
  [ "$1" = "rc" ] && env_pfx="VIBE_RC=1"
  [ "$1" = "norm" ] && env_pfx="VIBE_NORMALIZE=1"
  env $env_pfx VIBE_COV_OUT="$RUN_JSON" VIBE_COV_RAW=1 VIBE_IMPORT_ABI=raw \
    VIBE_PREOPEN_DIR="$ROOT" bash "$RUNNER" --invoke cli_main "$COMP" "$2" "$D/out" "$3" >/dev/null 2>&1 || true
  [ -s "$RUN_JSON" ] && bash scripts/coverage_acc_tool_run.sh merge "$ACC" "$RUN_JSON" || true
}
base=$(bash scripts/coverage_acc_tool_run.sh stat "$ACC" | cut -d' ' -f1)

emit() { cat > "$D/$1.vibe"; }

emit traits <<'EOF'
trait Show { show: (Self) -> String }
impl Show for Int { show: (self) -> String = (self) -> { Int::to_string(self) } }
struct Box { v: Int } derive(Eq)
impl Show for Box { show: (self) -> String = (self) -> { Int::to_string(self.v) } }
let render: [T: Show](T) -> String = (x) -> { show(x) }
export let main: () -> Int = () -> {
  let b = Box::{ v: 7 }
  String::length(render(b)) + String::length(render(3))
}
EOF

emit patterns <<'EOF'
enum Tree { Leaf(Int); Node(Tree, Tree) }
struct P { x: Int; y: Int }
let sum: (Tree) -> Int = (t) -> {
  match t {
    Leaf(n) => if n > 10 { n * 2 } else { n },
    Node(Leaf(0), r) => sum(r),
    Node(l, r) => sum(l) + sum(r)
  }
}
let classify: (Int, Int) -> Int = (a, b) -> {
  match (a, b) {
    (0, 0) => 1,
    (0, _) => 2,
    (_, 0) => 3,
    (x, y) => x + y
  }
}
let proj: (P) -> Int = (p) -> { let P::{ x, y } = p; x + y }
export let main: () -> Int = () -> {
  sum(Node(Leaf(11), Node(Leaf(0), Leaf(3)))) + classify(0, 5) + proj(P::{ x: 1, y: 2 })
}
EOF

emit mutclosure <<'EOF'
export let main: () -> Int = () -> {
  let mut acc = 0
  let bump = (n: Int) -> Int { acc = acc + n; acc }
  let mut i = 0
  while i < 5 { acc = acc + i; i = i + 1 }
  acc = acc * 2
  let r = bump(10) + bump(20)
  let xs = [1, 2, 3, 4]
  for x in xs { acc = acc + x }
  acc + r
}
EOF

emit assignops <<'EOF'
export let main: () -> Int = () -> {
  let mut a = 10
  a = a + 3
  a = a - 1
  a = a * 2
  a = a / 4
  let mut b = 0xFF
  b = b & 0x0F
  b = b | 0x30
  b = b ^ 0x05
  b = b << 2
  b = b >> 1
  a + b
}
EOF

emit pipes <<'EOF'
let inc: (Int) -> Int = (x) -> { x + 1 }
let dbl: (Int) -> Int = (x) -> { x * 2 }
export let main: () -> Int = () -> {
  let r = 5 |> inc |> dbl |> inc
  let xs = [1, 2, 3] |> Array::map(_ * 3)
  r + Array::length(xs)
}
EOF

emit effects <<'EOF'
effect Logger { log: (String) -> Unit }
let greet: (String) -> Int with Logger = (name) -> {
  Logger::log(name)
  String::length(name)
}
suberror MyErr(Int)
let risky: (Int) -> Int with Exception = (x) -> {
  if x < 0 { throw(MyErr(x)) } else { x * 2 }
}
export let main: () -> Int = () -> {
  let n = handle { greet("world") } with Logger { Log(_, k) => k(()) }
  let v = handle { risky(-1) } with Exception { Throw(_) => 99 }
  n + v
}
EOF

emit records <<'EOF'
export let main: () -> Int = () -> {
  let r = record { name: "vibe", ver: 3 }
  let t = (1, "two", true)
  let m = Map::from_pairs([("k", 42)])
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 10)
  ArrayBuilder::push(b, 20)
  let arr = ArrayBuilder::freeze(b)
  String::length(r.name) + r.ver + t.0 + m["k"] + Array::length(arr)
}
EOF

emit generics <<'EOF'
enum Opt2[T] { Non; Som(T) }
let map_opt: [A, B](Opt2[A], (A) -> B) -> Opt2[B] = (o, f) -> {
  match o { Non => Non, Som(x) => Som(f(x)) }
}
let or_else: [T](Opt2[T], T) -> T = (o, d) -> {
  match o { Non => d, Som(x) => x }
}
export let main: () -> Int = () -> {
  let a = map_opt(Som(5), (x: Int) -> Int { x + 1 })
  or_else(a, 0) + or_else(Non, 7)
}
EOF

emit strings <<'EOF'
export let main: () -> Int = () -> {
  let s = String::concat("foo", "bar")
  let n = String::length(s)
  let c = String::char_code_at(s, 0)
  let sub = s[1:4]
  let cmp = if "abc" < "abd" { 1 } else { 0 }
  n + c + String::length(sub) + cmp
}
EOF

emit letstar <<'EOF'
let parse: (Int) -> Result[Int, String] = (x) -> {
  if x > 0 { Ok(x) } else { Err("neg") }
}
let chain: (Int) -> Result[Int, String] = (x) -> {
  let* a = parse(x)
  let* b = parse(a + 1)
  Ok(a + b)
}
export let main: () -> Int = () -> {
  match chain(5) { Ok(v) => v, Err(_) => -1 }
}
EOF

emit guards <<'EOF'
let sign: (Int) -> Int = (x) -> {
  if x > 0 { 1 } else if x < 0 { 0 - 1 } else { 0 }
}
let cat: (Int) -> Int = (n) -> {
  match n {
    0 => 100,
    1 => 101,
    _ => if n > 100 { 200 } else { n }
  }
}
export let main: () -> Int = () -> {
  let mut total = 0
  let mut i = 0 - 3
  loop {
    if i > 3 { break }
    total = total + sign(i) + cat(i)
    i = i + 1
  }
  total
}
EOF

emit nestedfn <<'EOF'
export let main: () -> Int = () -> {
  let outer = (n: Int) -> Int {
    let helper = (x: Int) -> Int { x * x }
    let mut s = 0
    let mut i = 0
    while i < n { s = s + helper(i); i = i + 1 }
    s
  }
  outer(4) + outer(2)
}
EOF

i=0
for f in traits patterns mutclosure assignops pipes effects records generics strings letstar guards nestedfn; do
  [ -f "$D/$f.vibe" ] || continue
  i=$((i+1))
  acc_run fs   "$D/$f.vibe" main
  acc_run rc   "$D/$f.vibe" main
  acc_run norm "$D/$f.vibe" main
done
rm -f _build/vibe_selfhost_* 2>/dev/null || true

read -r now tot < <(bash scripts/coverage_acc_tool_run.sh stat "$ACC")
scaled=$(( (now * 10000 + tot / 2) / tot ))
pct="$((scaled / 100)).$(printf '%02d' $((scaled % 100)))"
echo "[features] $i programs; corpus branches: $base -> $now/$tot ($pct%)  (+$((now-base)))"
