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
emit t_struct_field  'struct P { x: Int, y: Int }
export let main: () -> Int = () -> { let p = P { x: 1, y: "s" }; p.x }'
emit t_struct_miss   'struct P { x: Int, y: Int }
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

echo "[gen] wrote $(ls "$OUT"/*.vibe | wc -l) programs to $OUT"
