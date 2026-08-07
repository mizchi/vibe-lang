#!/usr/bin/env bash
# Generate a diverse corpus of error-triggering and feature-exercising .vibe
# programs for branch coverage (#cov). The compiler's diagnostic functions
# (tk_name, type_to_string, serialize_type, __to_string, unify/types_equal
# error arms) only fire when the compiler EMITS an error, and dump-on-abort now
# captures coverage from a failed compile. So a broad set of deliberately
# ill-typed / mis-parsed programs lights up the diagnostic branches that no
# well-formed corpus file ever reaches. Feature programs (well-formed) exercise
# the breadth of check/codegen arms (operators, builtins, loops, traits).
#
#   scripts/coverage_gen_errcorpus.sh [out-dir]   # default: _build/errcorpus
set -euo pipefail
OUT="${1:-_build/errcorpus}"
mkdir -p "$OUT"

emit() { printf '%s\n' "$2" > "$OUT/$1.vibe"; }

# ---- type-mismatch programs (parse OK, fail in checker -> type_to_string,
#      unify, types_equal, serialize_type, type_name_prefix, __to_string) ----
emit t_int_str       'export let main: () -> Int = () -> { let x: Int = "s"; 0 }'
emit t_str_int       'export let main: () -> Int = () -> { let x: String = 1; 0 }'
emit t_float_int     'export let main: () -> Int = () -> { let x: Float = 1; 0 }'
emit t_bool_int      'export let main: () -> Int = () -> { let x: Bool = 1; 0 }'
emit t_int_bool      'export let main: () -> Int = () -> { let x: Int = true; 0 }'
emit t_unit_int      'export let main: () -> Int = () -> { let x: Int = (); 0 }'
emit t_tuple_mis     'export let main: () -> Int = () -> { let x: (Int, Int) = (1, "a"); 0 }'
emit t_tuple_arity   'export let main: () -> Int = () -> { let x: (Int, Int) = (1, 2, 3); 0 }'
emit t_arr_elem      'export let main: () -> Int = () -> { let x: Array[Int] = ["a"]; 0 }'
emit t_arr_scalar    'export let main: () -> Int = () -> { let x: Array[Int] = 1; 0 }'
emit t_fn_ret        'export let f: () -> Int = () -> { "s" }'
emit t_fn_arg        'let f: (Int) -> Int = (n) -> { n }
export let main: () -> Int = () -> { f("s") }'
emit t_fn_arity      'let f: (Int, Int) -> Int = (a, b) -> { a + b }
export let main: () -> Int = () -> { f(1) }'
emit t_call_nonfn    'export let main: () -> Int = () -> { let x = 1; x(2) }'
emit t_if_branches   'export let main: () -> Int = () -> { if true { 1 } else { "s" } }'
emit t_if_cond       'export let main: () -> Int = () -> { if 1 { 2 } else { 3 } }'
emit t_while_cond    'export let main: () -> Int = () -> { while 1 { () }; 0 }'
emit t_add_strint    'export let main: () -> Int = () -> { 1 + "s" }'
emit t_cmp_mismatch  'export let main: () -> Bool = () -> { 1 < "s" }'
emit t_and_nonbool   'export let main: () -> Bool = () -> { 1 && true }'
emit t_neg_str       'export let main: () -> Int = () -> { -"s" }'
emit t_unknown_var   'export let main: () -> Int = () -> { y }'
emit t_unknown_fn    'export let main: () -> Int = () -> { nope(1) }'
emit t_match_arms    'enum E { A; B }
export let main: () -> Int = () -> { match A { A => 1, B => "s" } }'
emit t_match_scrut   'enum E { A; B }
export let main: () -> Int = () -> { match 1 { A => 1, B => 2 } }'
emit t_ctor_arity    'enum E { A(Int) }
export let main: () -> Int = () -> { match A(1) { A => 1 } }'
emit t_struct_field  'struct P { x: Int; y: Int }
export let main: () -> Int = () -> { let p = P { x: 1, y: "s" }; p.x }'
emit t_struct_miss   'struct P { x: Int; y: Int }
export let main: () -> Int = () -> { let p = P { x: 1 }; p.x }'
emit t_struct_nofld  'struct P { x: Int }
export let main: () -> Int = () -> { let p = P { x: 1 }; p.z }'
emit t_generic_mis   'let id: (a) -> a = (x) -> { x }
export let main: () -> Int = () -> { let s: String = id(1); 0 }'
emit t_ret_unit      'export let main: () -> Int = () -> { () }'
emit t_option_mis    'export let main: () -> Int = () -> { let x: Option[Int] = Some("s"); 0 }'
emit t_result_mis    'export let main: () -> Int = () -> { let x: Result[Int, String] = Ok("s"); 0 }'
emit t_index_nonarr  'export let main: () -> Int = () -> { let x = 1; Array::get(x, 0) }'
emit t_let_annot     'export let main: () -> Int = () -> { let x: Foo = 1; 0 }'
emit t_dup_let       'export let main: () -> Int = () -> { let x = 1; let x = 2; x }'

# ---- parse-error programs (fail in parser -> tk_name "expected X got TOKEN",
#      parse_stmt / parse_postfix / parse_impl defensive arms) ----
emit p_unexp_plus    'export let main: () -> Int = () -> { + }'
emit p_unexp_star    'export let main: () -> Int = () -> { * 1 }'
emit p_unexp_rparen  'export let main: () -> Int = () -> { ) }'
emit p_unexp_rbrace  'export let main: () -> Int = () -> } }'
emit p_unexp_comma   'export let main: () -> Int = () -> { , }'
emit p_unexp_eq      'export let main: () -> Int = () -> { = 1 }'
emit p_unexp_arrow   'export let main: () -> Int = () -> { => 1 }'
emit p_unexp_colon   'export let main: () -> Int = () -> { : Int }'
emit p_unexp_dcolon  'export let main: () -> Int = () -> { :: }'
emit p_unexp_pipe    'export let main: () -> Int = () -> { |> }'
emit p_unexp_dot     'export let main: () -> Int = () -> { .foo }'
emit p_unexp_dotdot  'export let main: () -> Int = () -> { .. }'
emit p_unexp_semi    'export let main: () -> Int = () -> { ; ; }'
emit p_unexp_in      'export let main: () -> Int = () -> { in }'
emit p_unexp_then    'export let main: () -> Int = () -> { else }'
emit p_unexp_q       'export let main: () -> Int = () -> { ? }'
emit p_unexp_lt      'export let main: () -> Int = () -> { < }'
emit p_unexp_amp     'export let main: () -> Int = () -> { && }'
emit p_unexp_bang    'export let main: () -> Int = () -> { != 1 }'
emit p_unexp_hash    'export let main: () -> Int = () -> { # }'
emit p_unexp_tilde   'export let main: () -> Int = () -> { ~ }'
emit p_unexp_eof     'export let main: () -> Int = () -> {'
emit p_let_noeq      'export let main: () -> Int = () -> { let x 1; x }'
emit p_match_noarrow 'export let main: () -> Int = () -> { match 1 { 1 2 } }'
emit p_fn_nobody     'export let main: () -> Int = () ->'
emit p_enum_nobrace  'enum E A; B'
emit p_struct_nobrace 'struct P x: Int'
emit p_import_bad    'import { }'
emit p_type_bad      'type = Int'
emit p_unclosed_str  'export let main: () -> Int = () -> { let s = "abc; 0 }'
emit p_unclosed_par  'export let main: () -> Int = () -> { (1 + 2 }'
emit p_unclosed_brk  'export let main: () -> Int = () -> { [1, 2 }'

# ---- feature programs (well-formed; exercise breadth of check/codegen:
#      operators, builtins, loops, pipe, traits, derive, effects) ----
emit f_arith   'export let main: () -> Int = () -> {
  let a = 7 + 3 - 2 * 4 / 2 % 3
  let b = (a << 2) | (a >> 1) & 6 ^ 3
  let c = if a > b { a } else { b }
  let d = if a >= b && b <= c || a != c { 1 } else { 0 }
  a + b + c + d }'
emit f_pipe    'let inc: (Int) -> Int = (x) -> { x + 1 }
let dbl: (Int) -> Int = (x) -> { x * 2 }
export let main: () -> Int = () -> { 3 |> inc |> dbl |> inc }'
emit f_strops  'export let main: () -> Int = () -> {
  let s = String::concat("ab", "cd")
  let n = String::length(s)
  let c = String::char_code_at(s, 0)
  n + c + Int::to_string(n) |> String::length }'
emit f_arrayops 'export let main: () -> Int = () -> {
  let xs = [1, 2, 3, 4]
  let ys = Array::slice(xs, 1, 3)
  Array::push(ys, 9)
  Array::length(ys) + Array::get(xs, 0) }'
emit f_loops   'export let main: () -> Int = () -> {
  let mut acc = 0
  for x in [1, 2, 3] { acc = acc + x }
  let mut i = 0
  while i < 5 { acc = acc + i; i = i + 1 }
  let r = loop { if acc > 100 { break acc } else { acc = acc + 10 } }
  r }'
emit f_match   'enum Shape { Circle(Int); Rect(Int, Int); Dot }
let area: (Shape) -> Int = (s) -> {
  match s { Circle(r) => r * r * 3, Rect(w, h) => w * h, Dot => 0 } }
export let main: () -> Int = () -> { area(Circle(2)) + area(Rect(3, 4)) + area(Dot) }'
emit f_tuple   'export let main: () -> Int = () -> {
  let t = (1, "a", true)
  let (n, s, b) = t
  n + String::length(s) + (if b { 1 } else { 0 }) }'
emit f_nested  'export let main: () -> Int = () -> {
  let xs = [(1, [2, 3]), (4, [5])]
  let mut acc = 0
  for p in xs { let (n, ys) = p; acc = acc + n; for y in ys { acc = acc + y } }
  acc }'
emit f_closure 'export let main: () -> Int = () -> {
  let base = 10
  let add: (Int) -> Int = (x) -> { x + base }
  let apply: ((Int) -> Int, Int) -> Int = (f, v) -> { f(v) }
  apply(add, 5) + apply((x: Int) -> Int { x * 2 }, 3) }'
emit f_option  'export let main: () -> Int = () -> {
  let a: Option[Int] = Some(5)
  let b: Option[Int] = None
  match a { Some(x) => x, None => 0 } + match b { Some(x) => x, None => 99 } }'
emit f_result  'let safe: (Int) -> Result[Int, String] = (n) -> {
  if n > 0 { Ok(n) } else { Err("neg") } }
export let main: () -> Int = () -> {
  match safe(5) { Ok(v) => v, Err(_) => -1 } }'
emit f_rec     'let rec fib: (Int) -> Int = (n) -> {
  if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }
export let main: () -> Int = () -> { fib(10) }'
emit f_string_interp 'export let main: () -> Int = () -> {
  let n = 42
  let s = "value=${n} done"
  String::length(s) }'
emit f_bool    'export let main: () -> Bool = () -> {
  let a = true && false
  let b = true || false
  let c = !a
  a || b && c }'

# ---- multi-module sets (#cov): compiling a FS-mode entry that imports modules
#      with PRIVATE enums/structs/type-aliases/suberrors/lets/nested-modules
#      drives the namespace pass (namespace_private_value_stmts,
#      rewrite_private_type_ctor_expr, collect_private_{value,type,ctor}_renames)
#      and the import-alias rewrites — ~130 branches a single-file compile never
#      reaches. Each set is its own subdir (entry imports the siblings); the
#      corpus driver finds every *.vibe recursively and FS-compiles the entry. ----
mkfile() { mkdir -p "$OUT/$(dirname "$1")"; printf '%s\n' "$2" > "$OUT/$1"; }

# Set 1: private enum/struct/type-alias/suberror used by exported API.
mkfile mod_kitchen/lib.vibe 'enum PColor { PRed; PGreen; PBlue(Int) }
let pmk: () -> PColor = () -> { PBlue(5) }
let puse: (PColor) -> Int = (c) -> { match c { PRed => 1, PGreen => 2, PBlue(n) => n } }
struct PPoint { x: Int; y: Int }
let pmkpt: () -> PPoint = () -> { PPoint::{ x: 1, y: 2 } }
let pgetx: (PPoint) -> Int = (p) -> { p.x + p.y }
type PInts = Array[Int]
let psum: (PInts) -> Int = (xs) -> { let mut s = 0; for x in xs { s = s + x }; s }
export let compute: () -> Int = () -> { puse(pmk()) + pgetx(pmkpt()) + psum([1, 2, 3]) }
export enum PubColor { URed; UGreen }
export let pubmk: () -> PubColor = () -> { URed }'
mkfile mod_kitchen/main.vibe 'import ./lib.vibe { compute, PubColor, pubmk }
export let main: () -> Int = () -> { compute() + match pubmk() { URed => 1, UGreen => 2 } }'

# Set 2: aliased imports (`X as Y`) drive collision-def + alias rewrite paths.
mkfile mod_alias/lib.vibe 'export enum Status { Active; Idle(Int) }
export let make: (Int) -> Status = (n) -> { if n > 0 { Idle(n) } else { Active } }
export let label: (Status) -> Int = (s) -> { match s { Active => 0, Idle(n) => n } }'
mkfile mod_alias/main.vibe 'import ./lib.vibe { Status as St, make as mk, label as lbl }
export let main: () -> Int = () -> { lbl(mk(7)) + match mk(0) { Active => 100, Idle(_) => 0 } }'

# Set 3: re-export facade (export ./mod { ... }) + shared private helpers.
mkfile mod_reexport/core.vibe 'export enum Tok { TNum(Int); TStr(String) }
export let tnum: (Int) -> Tok = (n) -> { TNum(n) }
export let tval: (Tok) -> Int = (t) -> { match t { TNum(n) => n, TStr(s) => String::length(s) } }'
mkfile mod_reexport/facade.vibe 'export ./core { Tok, tnum, tval }
export { Tok, tnum, tval }'
mkfile mod_reexport/main.vibe 'import ./facade.vibe { Tok, tnum, tval }
export let main: () -> Int = () -> { tval(tnum(42)) + tval(TStr("hi")) }'

# Set 4: private nested module + private lets used by exported function.
mkfile mod_nested/lib.vibe 'module Helpers {
  let bump: (Int) -> Int = (n) -> { n + 1 }
  export let twice: (Int) -> Int = (n) -> { bump(bump(n)) }
}
let secret: Int = 41
let derive: (Int) -> Int = (n) -> { n + secret }
export let go: (Int) -> Int = (n) -> { Helpers::twice(derive(n)) }'
mkfile mod_nested/main.vibe 'import ./lib.vibe { go }
export let main: () -> Int = () -> { go(0) }'

# Set 5: diamond imports (two modules importing a shared base) + struct fields.
mkfile mod_diamond/base.vibe 'export struct Cfg { width: Int; height: Int }
export let area: (Cfg) -> Int = (c) -> { c.width * c.height }
export let mkcfg: (Int, Int) -> Cfg = (w, h) -> { Cfg::{ width: w, height: h } }'
mkfile mod_diamond/left.vibe 'import ./base.vibe { Cfg, area, mkcfg }
export let wide: () -> Int = () -> { area(mkcfg(100, 2)) }'
mkfile mod_diamond/right.vibe 'import ./base.vibe { Cfg, area, mkcfg }
export let tall: () -> Int = () -> { area(mkcfg(2, 100)) }'
mkfile mod_diamond/main.vibe 'import ./left.vibe { wide }
import ./right.vibe { tall }
export let main: () -> Int = () -> { wide() + tall() }'

# ---- feature breadth (#cov): well-formed programs exercising parser + codegen
#      arms (impl blocks, traits, generics, effects, bit ops, nested patterns,
#      labeled args, pipes, early return) the type-error corpus never reaches. ----
emit f_suberror 'suberror PBad(String)
let pfail: (Int) -> Int = (n) -> {
  handle { if n < 0 { throw(PBad("neg")) } else { n } } with Exception { Throw(_) => 0 } }
export let main: () -> Int = () -> { pfail(-1) + pfail(7) }'
emit f_generic 'let id: [T](T) -> T = (x) -> { x }
let pair: [A, B](A, B) -> (A, B) = (a, b) -> { (a, b) }
export let main: () -> Int = () -> { let (x, _) = pair(id(5), id("s")); x }'
emit f_bitops 'export let main: () -> Int = () -> {
  let a = 0xFF & 0x0F
  let b = 1 << 4
  let c = 255 >> 2
  let d = 5 ^ 3
  (a + b + c + d) | 1 }'
emit f_nested_pat 'enum Tree { Leaf(Int); Node(Tree, Tree) }
let rec depth: (Tree) -> Int = (t) -> {
  match t {
    Leaf(_) => 1,
    Node(Leaf(_), Leaf(_)) => 2,
    Node(l, r) => 1 + (if depth(l) > depth(r) { depth(l) } else { depth(r) })
  } }
export let main: () -> Int = () -> { depth(Node(Node(Leaf(1), Leaf(2)), Leaf(3))) }'
emit f_lit_pat 'enum Cmd { Op(Int, Bool) }
let run: (Cmd) -> Int = (c) -> {
  match c { Op(0, true) => 1, Op(0, false) => 2, Op(n, true) => n + 10, Op(n, false) => n } }
export let main: () -> Int = () -> { run(Op(0, true)) + run(Op(5, false)) + run(Op(3, true)) }'
emit f_string_ops 'export let main: () -> Int = () -> {
  let s = "hello world"
  let n = String::length(s)
  let parts = String::split(s, " ")
  n + Array::length(parts) }'
emit f_pipe 'let inc: (Int) -> Int = (n) -> { n + 1 }
let dbl: (Int) -> Int = (n) -> { n * 2 }
export let main: () -> Int = () -> { 5 |> inc |> dbl |> inc }'
emit f_early_ret 'let classify: (Int) -> Int = (n) -> {
  if n < 0 { return 0 }
  if n == 0 { return 1 }
  n + 100 }
export let main: () -> Int = () -> { classify(-1) + classify(0) + classify(5) }'

echo "[gen] wrote $(find "$OUT" -name '*.vibe' | wc -l) programs to $OUT"
