#!/usr/bin/env python3
"""Seeded random vibe program generator for differential fuzzing.

Generates a deterministic, well-typed, trap-free-by-construction vibe
program from an integer seed. The same seed also yields an FS-linked
split (defs.vibe + main.vibe) so single-file and multi-module lanes can
be diffed against each other.

Design notes:
- Differential oracle: the harness (run_fuzz.sh) diffs the program's
  result across bump / RC / wasm-gc backends and the FS-linked lane.
  Any divergence, compile diagnostic, trap, or hang on a generated
  program is a finding. With --extended (#2979) the program also prints
  generation-known values that are compared against expected.txt, which
  catches a wrong answer every lane shares.
- Trap freedom: every arithmetic result is masked (`& 1048575`) so values
  stay small and deterministic; divisors/shift-counts are forced into
  safe ranges; array indexes go through `expr % len` on masked (hence
  non-negative) operands; loops have literal bounds.
- Bug-class biases (kept deliberately hot): structs with same-named
  fields at DIFFERENT slots (#722), bare/ctor record construction with
  shuffled literal field order, `mut` struct fields, mutable captures in
  closures, for-in comprehensions (#538), nested ctor patterns, string
  interpolation, tuple projections.
- Liveness-aware generation (#765, opt-out via --classic): a per-seed
  probability (`Gen.liveness_bias`) additionally biases statement
  generation toward shapes that stress the RC/Perceus dup-drop
  accounting -- deep def-use chains threaded through helper calls, alias
  bindings (`let b = a` then use of both), conditional moves (a value
  consumed in only one branch of an `if`), cross-scope closure capture
  (closure literal defined inside one `if`-branch, capturing an outer
  `let`/`mut` binding, invoked after the `if` resolves), and bounded
  tail-resume-shaped recursion (a struct threaded untouched through many
  stack frames, consumed only at the base case). These are pure biases
  layered on top of the existing statement generator (see
  `Gen.liveness_bias` / `gen_def_use_chain` / `gen_alias_stmts` /
  `gen_conditional_move` / `gen_cross_scope_capture` / the `recursors`
  helpers) -- they do not replace any existing generation path, and keep
  the same trap-free-by-construction discipline (masked arithmetic,
  bounded recursion depth via a literal argument cap).

Usage: gen_program.py SEED OUTDIR [--classic] [--liveness-bias=X] [--extended]
  --classic          disable the liveness-aware bias (legacy behavior)
  --liveness-bias=X  force the bias probability to X (0.0..1.0), instead
                      of the seed-derived default; mostly for testing.
  --extended         add the #2979 productions (effects, handlers,
                      exceptions, nested containers, builtins inside
                      interpolation, labeled args, generics, traits) and
                      the lane-independent oracle (see ExtGen).
Writes OUTDIR/single.vibe, OUTDIR/defs.vibe, OUTDIR/main.vibe; with
--extended also OUTDIR/expected.txt and, when the program uses a construct
some lane cannot compile (none today, see README "Known lane gaps"),
OUTDIR/skip_lanes.
"""
import random
import sys

MASK = 1048575  # 2^20 - 1: keeps every intermediate small + non-negative

# Per-seed liveness bias is drawn from this range so different seeds apply
# different amounts of pressure (some mild, some heavy) while never being
# fully off unless --classic is passed.
LIVENESS_MIN_BIAS = 0.12
LIVENESS_MAX_BIAS = 0.55

FIELD_POOL = ["name", "kind", "v", "x", "y", "w", "tagf", "size"]
STR_POOL = ["alpha", "beta", "route", "k", "", "nested"]


# ---------- extended productions + lane-independent oracle (#2979) ----------
#
# Opt-in via `--extended`. The classic/liveness generator above produces
# ints, strings, structs, closures, loops and enum matches -- and none of the
# constructs where the 2026-09 audit found its bugs. This section adds them:
#
#   * user effects: `effect` / `perform` / `handle` / `resume`, including arms
#     that LEAVE instead of resuming (`return`, `throw`);
#   * exceptions: `throw` / `handle .. with Exception[K]`, `Exception[K]` and
#     `effectset` rows, `suberror` and `derive(Show)` enum kinds;
#   * nested containers: `Option[Option[T]]`, `Array[Option[T]]`,
#     `Option[Array[T]]` and deeper, annotated and self-describing;
#   * builtin calls directly inside a `"\{..}"` interpolation;
#   * labeled arguments, generics (unbounded and trait-bounded), traits with
#     impls, shift counts outside 0..62.
#
# Every function the section generates carries an effect ROW (`self.rows`),
# and `_start` discharges each row with nested handles before the entry, so
# `_start` itself needs only `Stdout` (checked in `discharge`).
#
# The ORACLE: each production whose value is known at generation time prints
# one line `<ID>|<text>` and records the text it must print in
# `expected.txt`. The ID's first letter names the oracle -- R (render),
# T (throw), C (continuation) -- and the harness maps a wrong line to
# ORACLE_RENDER / ORACLE_THROW / ORACLE_CONT. The expected text is computed by
# a small Python model of exactly the shapes generated here (masked integer
# arithmetic, the renderer's container spelling, the handler semantics of
# ADR-0114); it is deliberately NOT a second evaluator for the whole
# language, which is why only these productions carry an oracle line.

EXT_STR_POOL = ["alpha", "beta", "", "ab", "route", "a b", "nest"]


class Leave(Exception):
    """A handler arm that left instead of resuming (`return v`)."""

    def __init__(self, value):
        super().__init__(value)
        self.value = value


class Thrown(Exception):
    """A `throw(K(..))` in the Python model: (kind name, rendered payload,
    constructor, int payload or None)."""

    def __init__(self, kind, ctor, payload):
        super().__init__(kind)
        self.kind = kind
        self.ctor = ctor
        self.payload = payload


def render_val(v):
    tag = v[0]
    if tag == "int":
        return str(v[1])
    if tag == "str":
        return v[1]
    if tag == "bool":
        return "true" if v[1] else "false"
    if tag == "some":
        return f"Some({render_val(v[1])})"
    if tag == "none":
        return "None"
    if tag == "arr":
        return "[" + ", ".join(render_val(x) for x in v[1]) + "]"
    raise ValueError(v)


def lit_val(v):
    tag = v[0]
    if tag == "int":
        return str(v[1])
    if tag == "str":
        return f'"{v[1]}"'
    if tag == "bool":
        return "true" if v[1] else "false"
    if tag == "some":
        return f"Some({lit_val(v[1])})"
    if tag == "none":
        return "None"
    if tag == "arr":
        return "[" + ", ".join(lit_val(x) for x in v[1]) + "]"
    raise ValueError(v)


def ty_str(t):
    if isinstance(t, str):
        return t
    return f"{t[0]}[{ty_str(t[1])}]"


def self_describing(v):
    """Can the checker infer this literal's type from its own syntax? A
    `None` or `[]` alone says nothing; an array is typed by its first
    element, which the others must unify with."""
    tag = v[0]
    if tag in ("int", "str", "bool"):
        return True
    if tag == "some":
        return self_describing(v[1])
    if tag == "none":
        return False
    if tag == "arr":
        return bool(v[1]) and self_describing(v[1][0])
    return False


def ext_substring(s, i, j):
    n = len(s.encode())
    i = max(0, min(i, n))
    j = max(0, min(j, n))
    if j < i:
        return ""
    return s.encode()[i:j].decode()


class ExtGen:
    def __init__(self, g, rng):
        self.g = g
        self.r = rng
        # Trait impls and bounded generics run on every lane since #3069
        # (the flat single-source linear lane used to refuse them).
        self.traits = rng.random() < 0.35
        self.effects = []             # effect names; ops are Ask(Int)->Int, Tell(Int)->Unit
        self.kinds = []               # (name, style, ctors [(cname, arity)])
        self.effectsets = []          # (name, [labels])
        self.efuncs = {}              # name -> spec dict
        self.rows = {}                # function name -> frozenset of row labels
        self.decls = []               # top-level declaration texts, in order
        self.exports = []             # names main.vibe must import
        self.expected = []            # (id, text)
        self.counter = {"R": 0, "T": 0, "C": 0}
        self.trait_info = None
        # Helpers some production has called. Every effect / throwing helper
        # is called at least once: the gc backend refuses a program whose
        # uncalled function performs a user effect (`GC codegen: unsupported
        # perform`, tests/fuzz/README.md "Known lane gaps"), and an uncalled
        # helper measures nothing anyway.
        self.used = set()

    def fresh(self, p):
        return self.g.fresh(p)

    def skip_lanes(self):
        """Lanes that cannot compile a construct this program uses TODAY,
        each tied to a compiler defect found while building this generator
        (see tests/fuzz/README.md, "Known lane gaps"). A skipped lane is
        reported as `skipped` in every verdict, never silently dropped."""
        skip = []
        return skip

    def oid(self, tag):
        self.counter[tag] += 1
        return f"{tag}{self.counter[tag]}"

    def emit(self, lines, tag, interp, expected_text):
        """Print one oracle line. `interp` is the interpolation body (already
        valid inside a string literal); `expected_text` what it must print."""
        i = self.oid(tag)
        lines.append(f'println("{i}|{interp}")')
        self.expected.append((i, expected_text))

    # ----- declarations -----

    def gen_decls(self):
        r = self.r
        for i in range(r.randint(1, 2)):
            name = f"Ef{i}"
            self.effects.append(name)
            self.decls.append(
                f"export effect {name} {{\n  Ask(Int) -> Int;\n  Tell(Int) -> Unit\n}}")
            self.exports.append(name)
        for i in range(r.randint(1, 2)):
            if r.random() < 0.7:
                name = f"Kd{i}"
                ctors = [(f"{name}A", 1), (f"{name}B", 0)]
                self.kinds.append((name, "enum", ctors))
                self.decls.append(
                    f"export enum {name} {{ {name}A(Int); {name}B }} derive(Show)")
            else:
                name = f"Sb{i}"
                self.kinds.append((name, "suberror", [(name, 1)]))
                self.decls.append(f"export suberror {name}(Int)")
            self.exports.append(name)
        # effect helpers (row: {Ef})
        for _ in range(r.randint(2, 3)):
            self.gen_eff_fn(r.choice(self.effects))
        # throwing helpers (row: {Exception[K]})
        for _ in range(r.randint(1, 3)):
            self.gen_thr_fn(r.choice(self.kinds))
        # mixed rows, optionally spelled through an effectset
        for _ in range(r.randint(1, 2)):
            self.gen_mix_fn()
        self.gen_labeled()
        self.gen_generic_id()
        if self.traits:
            self.gen_traits()

    def gen_eff_fn(self, eff):
        r = self.r
        name = self.fresh("eff")
        steps = []
        nask = r.randint(1, 3)
        for k in range(nask):
            if r.random() < 0.4:
                steps.append(("tell",))
            steps.append(("ask", r.randint(1, 5), r.randint(0, 20)))
        if r.random() < 0.3:
            steps.append(("tell",))
        coefs = [r.randint(1, 4) for _ in range(nask)]
        body = []
        prev = "n"
        asks = []
        for st in steps:
            if st[0] == "ask":
                a = self.fresh("a")
                body.append(
                    f"let {a} = perform {eff}::Ask((({prev} * {st[1]} + {st[2]}) & {MASK}))")
                asks.append(a)
                prev = a
            else:
                body.append(f"perform {eff}::Tell({prev})")
        tail = " + ".join(f"{a} * {c}" for a, c in zip(asks, coefs))
        body.append(f"(({tail} + n) & {MASK})")
        txt = "\n".join("  " + l for l in body)
        self.decls.append(f"export fn {name}(n: Int) -> Int with {eff} {{\n{txt}\n}}")
        self.exports.append(name)
        self.efuncs[name] = {"kind": "eff", "eff": eff, "steps": steps, "coefs": coefs}
        self.rows[name] = frozenset([eff])

    def gen_thr_fn(self, kind):
        r = self.r
        kname, style, ctors = kind
        name = self.fresh("thr")
        thresh = r.randint(1, 12)
        cname, arity = r.choice(ctors)
        c = r.randint(0, 9)
        m = r.randint(1, 7)
        k = r.randint(0, 30)
        payload = f"(((n + {c}) & {MASK}))" if arity else ""
        self.decls.append(
            f"export fn {name}(n: Int) -> Int with Exception[{kname}] {{\n"
            f"  if n > {thresh} {{ throw({cname}{payload}) }}\n"
            f"  ((n * {m} + {k}) & {MASK})\n}}")
        self.exports.append(name)
        self.efuncs[name] = {"kind": "thr", "kname": kname, "thresh": thresh,
                             "ctor": cname, "arity": arity, "c": c, "m": m, "k": k}
        self.rows[name] = frozenset([f"Exception[{kname}]"])

    def gen_mix_fn(self):
        r = self.r
        effs = [n for n, s in self.efuncs.items() if s["kind"] == "eff"]
        thrs = [n for n, s in self.efuncs.items() if s["kind"] == "thr"]
        ef, th = r.choice(effs), r.choice(thrs)
        name = self.fresh("mix")
        row = self.rows[ef] | self.rows[th]
        labels = sorted(row)
        if r.random() < 0.5:
            es = self.fresh("Es")
            self.effectsets.append((es, labels))
            self.decls.append(f"export effectset {es} = {{ {', '.join(labels)} }}")
            self.exports.append(es)
            spelled = es
        else:
            spelled = " + ".join(labels)
        mask_k = r.choice([7, 15])
        self.decls.append(
            f"export fn {name}(n: Int) -> Int with {spelled} {{\n"
            f"  let a = {ef}(n)\n"
            f"  let b = {th}((a & {mask_k}))\n"
            f"  ((a + b * 3) & {MASK})\n}}")
        self.exports.append(name)
        self.efuncs[name] = {"kind": "mix", "ef": ef, "th": th, "mask": mask_k}
        self.rows[name] = row

    def gen_labeled(self):
        r = self.r
        name = self.fresh("lab")
        ca, cb, cc = r.randint(1, 5), r.randint(1, 5), r.randint(1, 5)
        self.decls.append(
            f"export fn {name}(a~: Int, b~: Int, c~: Int) -> Int {{\n"
            f"  ((a * {ca} - b * {cb} + c * {cc}) & {MASK})\n}}")
        self.exports.append(name)
        self.lab = (name, ca, cb, cc)
        self.rows[name] = frozenset()

    def gen_generic_id(self):
        name = self.fresh("gid")
        self.decls.append(f"export fn {name}[T](x: T) -> T {{ x }}")
        self.exports.append(name)
        self.gid = name
        self.rows[name] = frozenset()

    def gen_traits(self):
        r = self.r
        tr = self.fresh("Tr")
        st = self.fresh("Tp")
        m1, k1 = r.randint(1, 5), r.randint(0, 9)
        m2, k2 = r.randint(1, 5), r.randint(0, 9)
        self.decls.append(f"export trait {tr} {{\n  mz(Self) -> Int\n}}")
        self.decls.append(f"export struct {st} {{\n  p: Int;\n  q: Int\n}}")
        self.decls.append(
            f"impl {tr} for Int {{\n  mz(a: Int) -> Int {{ ((a * {m1} + {k1}) & {MASK}) }}\n}}")
        self.decls.append(
            f"impl {tr} for {st} {{\n  mz(a: {st}) -> Int {{ ((a.p * {m2} - a.q + {k2}) & {MASK}) }}\n}}")
        g1 = self.fresh("gm")
        ufcs = r.random() < 0.5
        call = "v.mz()" if ufcs else f"T::mz(v)"
        self.decls.append(f"export fn {g1}[T: {tr}](v: T) -> Int {{ {call} }}")
        g2 = self.fresh("gm")
        self.decls.append(
            f"export fn {g2}[T: {tr}](a: T, b: T) -> Int {{ ((T::mz(a) * 2 - T::mz(b)) & {MASK}) }}")
        self.exports += [tr, st, g1, g2]
        self.trait_info = (tr, st, g1, g2, m1, k1, m2, k2)
        for n in (g1, g2):
            self.rows[n] = frozenset()

    # ----- Python model of the generated helpers -----

    def eval_fn(self, name, n, handlers):
        """handlers: effect name -> callable(op, arg) returning the resumed
        value (or raising Leave / Thrown)."""
        s = self.efuncs[name]
        if s["kind"] == "eff":
            h = handlers[s["eff"]]
            prev = n
            asks = []
            for st in s["steps"]:
                if st[0] == "ask":
                    v = h("Ask", (prev * st[1] + st[2]) & MASK)
                    asks.append(v)
                    prev = v
                else:
                    h("Tell", prev)
            return (sum(a * c for a, c in zip(asks, s["coefs"])) + n) & MASK
        if s["kind"] == "thr":
            if n > s["thresh"]:
                p = ((n + s["c"]) & MASK) if s["arity"] else None
                raise Thrown(s["kname"], s["ctor"], p)
            return (n * s["m"] + s["k"]) & MASK
        a = self.eval_fn(s["ef"], n, handlers)
        b = self.eval_fn(s["th"], a & s["mask"], handlers)
        return (a + b * 3) & MASK

    # ----- handler construction -----

    def resume_handler(self, eff, lines_state):
        """A resuming handler for `eff`: Ask(x) => resume(((x * m + k) & MASK)),
        Tell(y) => accumulate into a `let mut` counter, resume(())."""
        r = self.r
        m, k = r.randint(1, 4), r.randint(0, 50)
        tc = self.fresh("tc")
        arms = (f"  {eff}::Ask(x) => resume(((x * {m} + {k}) & {MASK}))\n"
                f"  {eff}::Tell(y) => {{\n"
                f"    {tc} = (({tc} * 3 + y) & {MASK})\n"
                f"    resume(())\n  }}")
        state = {"tc": 0}

        def h(op, arg):
            if op == "Ask":
                return (arg * m + k) & MASK
            state["tc"] = (state["tc"] * 3 + arg) & MASK
            return None
        lines_state.append(f"let mut {tc} = 0")
        return arms, h, (tc, state)

    def discharge(self, call, row, pre, exc_arm):
        """Wrap `call` in handles for every label of `row` (user effects
        innermost, the exception outermost). Returns (expr, handlers, tcs).
        `exc_arm(kname) -> (arm_text, py_fn)` builds the exception arm."""
        handlers = {}
        tcs = []
        expr = call
        for lab in sorted(row):
            if lab.startswith("Exception["):
                continue
            arms, h, tc = self.resume_handler(lab, pre)
            handlers[lab] = h
            tcs.append(tc)
            expr = f"handle {{ {expr} }} with {{\n{arms}\n}}"
        exc = None
        for lab in sorted(row):
            if lab.startswith("Exception["):
                kname = lab[len("Exception["):-1]
                arm, fn = exc_arm(kname)
                expr = f"handle {{ {expr} }} with {{ Exception[{kname}]::Throw(e) => {arm} }}"
                exc = fn
        assert all(l.startswith("Exception[") or l in handlers for l in row), row
        return expr, handlers, tcs, exc

    # ----- oracle statements for _start -----

    def kind_of(self, kname):
        for k in self.kinds:
            if k[0] == kname:
                return k
        raise KeyError(kname)

    def render_thrown(self, t):
        if t.payload is None:
            return t.ctor
        return f"{t.ctor}({t.payload})"

    def int_exc_arm(self, kname):
        """An exception arm producing an Int from the payload by `match`."""
        r = self.r
        _, style, ctors = self.kind_of(kname)
        bias = r.randint(100, 900)
        parts = []
        table = {}
        for cname, arity in ctors:
            if arity:
                parts.append(f"{cname}(p) => ((p + {bias}) & {MASK})")
                table[cname] = ("p", bias)
            else:
                v = r.randint(0, 99)
                parts.append(f"{cname} => {v}")
                table[cname] = ("c", v)
        arm = f"match e {{ {', '.join(parts)} }}"

        def fn(t):
            kind, v = table[t.ctor]
            return (t.payload + v) & MASK if kind == "p" else v
        return arm, fn

    def str_exc_arm(self, kname):
        """An exception arm producing a String that renders the payload --
        the throw oracle proper. Three spellings, because they do not all
        agree today: interpolating the kinded binder directly, rebinding it
        with an annotation first, and matching on it."""
        r = self.r
        _, style, ctors = self.kind_of(kname)
        pick = r.random()
        if style == "enum" and pick < 0.4:
            return '"caught \\{e}"', lambda t: f"caught {self.render_thrown(t)}"
        if style == "enum" and pick < 0.7:
            kb = self.fresh("kb")
            return (f'{{\n    let {kb}: {kname} = e\n    "caught \\{{{kb}}}"\n  }}',
                    lambda t: f"caught {self.render_thrown(t)}")
        parts = []
        for cname, arity in ctors:
            if arity:
                parts.append(f'{cname}(p) => "caught {cname} \\{{p}}"')
            else:
                parts.append(f'{cname} => "caught {cname}"')

        def fn(t):
            if t.payload is None:
                return f"caught {t.ctor}"
            return f"caught {t.ctor} {t.payload}"
        return f"match e {{ {', '.join(parts)} }}", fn

    def oracle_stmts(self, acc):
        r = self.r
        lines = []
        prods = [self.o_render, self.o_render, self.o_match, self.o_builtins,
                 self.o_labeled, self.o_shift, self.o_cont_resume,
                 self.o_cont_leave, self.o_cont_throw, self.o_throw_str,
                 self.o_throw_int, self.o_mix]
        if self.traits:
            prods.append(self.o_traits)
        # every production at least once, then a random extra handful
        order = list(prods) + [r.choice(prods) for _ in range(r.randint(2, 6))]
        r.shuffle(order)
        for p in order:
            p(lines, acc)
        for f in list(self.efuncs):
            if f in self.used:
                continue
            kind = self.efuncs[f]["kind"]
            if kind == "eff":
                self.o_cont_resume(lines, acc, f)
            elif kind == "thr":
                self.o_throw_int(lines, acc, f)
            else:
                self.o_mix(lines, acc, f)
        return lines

    def rand_type(self, depth):
        r = self.r
        if depth <= 0:
            return r.choice(["Int", "Int", "String", "Bool"])
        hot = r.random()
        if hot < 0.2:
            return ("Option", ("Option", self.rand_type(depth - 2)))
        if hot < 0.4:
            return ("Array", ("Option", self.rand_type(depth - 2)))
        if hot < 0.6:
            return ("Option", ("Array", self.rand_type(depth - 2)))
        if hot < 0.8:
            return (r.choice(["Option", "Array"]), self.rand_type(depth - 1))
        return self.rand_type(0)

    def rand_val(self, t, depth=3):
        r = self.r
        if t == "Int":
            return ("int", r.randint(-9, 99))
        if t == "String":
            return ("str", r.choice(EXT_STR_POOL))
        if t == "Bool":
            return ("bool", r.random() < 0.5)
        head, inner = t
        if head == "Option":
            if r.random() < 0.3:
                return ("none",)
            return ("some", self.rand_val(inner, depth - 1))
        n = r.randint(0, 3) if depth > 0 else 0
        return ("arr", [self.rand_val(inner, depth - 1) for _ in range(n)])

    def o_render(self, lines, acc):
        t = self.rand_type(self.r.randint(1, 4))
        v = self.rand_val(t)
        name = self.fresh("rv")
        if self_describing(v) and self.r.random() < 0.5:
            lines.append(f"let {name} = {lit_val(v)}")
        else:
            lines.append(f"let {name}: {ty_str(t)} = {lit_val(v)}")
        self.emit(lines, "R", f"\\{{{name}}}", render_val(v))
        # Int::parse: a builtin whose Option result is known from its literal
        if self.r.random() < 0.4:
            s = self.r.choice(["42", "0", "-7", "4x", "", "12a", "100"])
            pv = self.fresh("pv")
            lines.append(f'let {pv}: Option[Int] = Int::parse("{s}")')
            try:
                exp = f"Some({int(s)})" if s.lstrip("-").isdigit() else "None"
            except ValueError:
                exp = "None"
            self.emit(lines, "R", f"\\{{{pv}}}", exp)

    def o_match(self, lines, acc):
        r = self.r
        c, k1, k2 = r.randint(0, 9), r.randint(100, 199), r.randint(200, 299)
        if r.random() < 0.5:
            v = self.rand_val(("Option", ("Option", "Int")))
            name = self.fresh("oo")
            lines.append(f"let {name}: Option[Option[Int]] = {lit_val(v)}")
            mv = self.fresh("mo")
            lines.append(
                f"let {mv} = match {name} {{ Some(Some(x)) => ((x + {c}) & {MASK}), "
                f"Some(None) => {k1}, None => {k2} }}")
            if v[0] == "none":
                exp = k2
            elif v[1][0] == "none":
                exp = k1
            else:
                exp = (v[1][1][1] + c) & MASK
        else:
            elems = [self.rand_val(("Option", "Int")) for _ in range(r.randint(1, 4))]
            name = self.fresh("ao")
            lines.append(f"let {name}: Array[Option[Int]] = {lit_val(('arr', elems))}")
            idx = r.randrange(len(elems))
            mv = self.fresh("mo")
            lines.append(
                f"let {mv} = match Array::get({name}, {idx}) {{ Some(x) => ((x + {c}) & {MASK}), "
                f"None => {k1} }}")
            e = elems[idx]
            exp = k1 if e[0] == "none" else (e[1][1] + c) & MASK
        self.emit(lines, "R", f"\\{{{mv}}}", str(exp))
        lines.append(f"{acc} = (({acc} * 31 + {mv}) & {MASK})")

    def o_builtins(self, lines, acc):
        r = self.r
        parts = []
        exps = []
        for _ in range(r.randint(1, 4)):
            a, b = r.choice(EXT_STR_POOL), r.choice(EXT_STR_POOL)
            pick = r.randrange(7)
            if pick == 0:
                parts.append(f'\\{{String::length("{a}")}}')
                exps.append(str(len(a.encode())))
            elif pick == 1:
                xs = [r.randint(0, 9) for _ in range(r.randint(0, 5))]
                parts.append(f"\\{{Array::length([{', '.join(map(str, xs))}])}}"
                             if xs else "\\{Array::length([0])}")
                exps.append(str(len(xs) if xs else 1))
            elif pick == 2:
                parts.append(f'\\{{String::concat("{a}", "{b}")}}')
                exps.append(a + b)
            elif pick == 3:
                i, j = r.randint(-1, 6), r.randint(-1, 6)
                parts.append(f'\\{{String::substring("{a}", {i}, {j})}}')
                exps.append(ext_substring(a, i, j))
            elif pick == 4:
                parts.append(f'\\{{String::contains("{a}", "{b}")}}')
                exps.append("true" if b in a else "false")
            elif pick == 5:
                parts.append(f'\\{{String::starts_with("{a}", "{b}")}}')
                exps.append("true" if a.startswith(b) else "false")
            else:
                parts.append(f'\\{{String::ends_with("{a}", "{b}")}}')
                exps.append("true" if a.endswith(b) else "false")
        self.emit(lines, "R", ",".join(parts), ",".join(exps))

    def o_labeled(self, lines, acc):
        r = self.r
        name, ca, cb, cc = self.lab
        vals = {"a": r.randint(0, 50), "b": r.randint(0, 50), "c": r.randint(0, 50)}
        order = ["a", "b", "c"]
        r.shuffle(order)
        lv = self.fresh("lv")
        lines.append(f"let {lv} = {name}({', '.join(f'{k}={vals[k]}' for k in order)})")
        exp = (vals["a"] * ca - vals["b"] * cb + vals["c"] * cc) & MASK
        self.emit(lines, "R", f"\\{{{lv}}}", str(exp))
        lines.append(f"{acc} = (({acc} * 31 + {lv}) & {MASK})")
        # an unbounded generic at two instantiations
        s = r.choice(EXT_STR_POOL)
        n = r.randint(0, 99)
        self.emit(lines, "R", f'\\{{{self.gid}({n})}} \\{{{self.gid}("{s}")}}', f"{n} {s}")

    def o_shift(self, lines, acc):
        r = self.r
        parts = []
        exps = []
        for _ in range(r.randint(1, 3)):
            x = r.randint(-40, 200)
            xs = f"(0 - {-x})" if x < 0 else str(x)
            if r.random() < 0.6:
                n = r.choice([63, 64, 65, 70, 100, -1, -5])
            else:
                n = r.randint(0, 40)
            if r.random() < 0.5:
                parts.append(f"\\{{({xs} << {n})}}")
                exps.append(str(0 if (n >= 63 or n < 0) else x << n))
            else:
                parts.append(f"\\{{({xs} >> {n})}}")
                exps.append(str((0 if x >= 0 else -1) if (n >= 63 or n < 0) else x >> n))
        self.emit(lines, "R", " ".join(parts), " ".join(exps))

    def eff_names(self):
        return [n for n, s in self.efuncs.items() if s["kind"] == "eff"]

    def o_cont_resume(self, lines, acc, f=None):
        """A resuming handler over an effect helper: the answer and the Tell
        counter are both known."""
        r = self.r
        f = f or r.choice(self.eff_names())
        self.used.add(f)
        n = r.randint(0, 40)
        cv = self.fresh("cv")
        pre = []
        expr, handlers, tcs, _ = self.discharge(f"{f}({n})", self.rows[f], pre, None)
        lines += pre
        lines.append(f"let {cv} = {expr}")
        exp = self.eval_fn(f, n, handlers)
        tc, st = tcs[0]
        self.emit(lines, "C", f"\\{{{cv}}} \\{{{tc}}}", f"{exp} {st['tc']}")
        lines.append(f"{acc} = (({acc} * 31 + {cv}) & {MASK})")

    def o_cont_leave(self, lines, acc):
        """An arm that does NOT resume: `return` leaves the enclosing
        function with the arm's value (ADR-0114). The perform is either in
        the handle body itself or inside a called helper."""
        r = self.r
        f = r.choice(self.eff_names())
        s = self.efuncs[f]
        eff = s["eff"]
        k = r.randint(0, 60)
        w = self.fresh("leave")
        direct = r.random() < 0.4
        if direct:
            m, c = r.randint(1, 5), r.randint(0, 9)
            body = f"perform {eff}::Ask(((n * {m} + {c}) & {MASK})) + 1"
            first_ask = lambda n: (n * m + c) & MASK  # noqa: E731
        else:
            body = f"{f}(n) + 1"
            self.used.add(f)

            def first_ask(n):
                try:
                    def h(op, arg):
                        if op == "Ask":
                            raise Leave(arg)
                        return None
                    self.eval_fn(f, n, {eff: h})
                except Leave as lv:
                    return lv.value
                raise AssertionError("eff helper never asked")
        self.decls.append(
            f"export fn {w}(n: Int) -> Int {{\n"
            f"  let r = handle {{ {body} }} with {{\n"
            f"    {eff}::Ask(x) => return ((x + {k}) & {MASK})\n"
            f"    {eff}::Tell(y) => resume(())\n"
            f"  }}\n"
            f"  ((r * 3 + 1) & {MASK})\n}}")
        self.exports.append(w)
        self.rows[w] = frozenset()
        n = r.randint(0, 40)
        exp = (first_ask(n) + k) & MASK
        lv = self.fresh("lc")
        lines.append(f"let {lv} = {w}({n})")
        self.emit(lines, "C", f"\\{{{lv}}}", str(exp))
        lines.append(f"{acc} = (({acc} * 31 + {lv}) & {MASK})")

    def o_cont_throw(self, lines, acc):
        """An arm that leaves by throwing: the outer kinded handle sees the
        first Ask's argument as the payload."""
        r = self.r
        cands = [k for k in self.kinds if any(a for _, a in k[2])]
        if not cands:
            return
        kname, style, ctors = r.choice(cands)
        cname = [c for c, a in ctors if a][0]
        f = r.choice(self.eff_names())
        self.used.add(f)
        eff = self.efuncs[f]["eff"]
        n = r.randint(0, 40)
        arm, fn = self.int_exc_arm(kname)
        tv = self.fresh("ct")
        lines.append(
            f"let {tv} = handle {{\n"
            f"  handle {{ {f}({n}) }} with {{\n"
            f"    {eff}::Ask(x) => throw({cname}(x))\n"
            f"    {eff}::Tell(y) => resume(())\n"
            f"  }}\n"
            f"}} with {{ Exception[{kname}]::Throw(e) => {arm} }}")

        def h(op, arg):
            if op == "Ask":
                raise Thrown(kname, cname, arg)
            return None
        try:
            exp = self.eval_fn(f, n, {eff: h})
        except Thrown as t:
            exp = fn(t)
        self.emit(lines, "C", f"\\{{{tv}}}", str(exp))
        lines.append(f"{acc} = (({acc} * 31 + {tv}) & {MASK})")

    def thr_names(self):
        return [n for n, s in self.efuncs.items() if s["kind"] == "thr"]

    def o_throw_str(self, lines, acc):
        r = self.r
        f = r.choice(self.thr_names())
        self.used.add(f)
        kname = self.efuncs[f]["kname"]
        s = self.efuncs[f]
        n = r.randint(s["thresh"] - 2, s["thresh"] + 6)
        n = max(n, 0)
        arm, fn = self.str_exc_arm(kname)
        tv = self.fresh("ts")
        vv = self.fresh("v")
        lines.append(
            f"let {tv} = handle {{\n  let {vv} = {f}({n})\n  \"ok \\{{{vv}}}\"\n"
            f"}} with {{ Exception[{kname}]::Throw(e) => {arm} }}")
        try:
            exp = f"ok {self.eval_fn(f, n, {})}"
        except Thrown as t:
            exp = fn(t)
        self.emit(lines, "T", f"\\{{{tv}}}", exp)

    def o_throw_int(self, lines, acc, f=None):
        r = self.r
        f = f or r.choice(self.thr_names())
        self.used.add(f)
        s = self.efuncs[f]
        n = max(0, r.randint(s["thresh"] - 3, s["thresh"] + 5))
        pre = []
        expr, handlers, _, exc = self.discharge(
            f"{f}({n})", self.rows[f], pre, self.int_exc_arm)
        lines += pre
        tv = self.fresh("ti")
        lines.append(f"let {tv} = {expr}")
        try:
            exp = self.eval_fn(f, n, handlers)
        except Thrown as t:
            exp = exc(t)
        self.emit(lines, "T", f"\\{{{tv}}}", str(exp))
        lines.append(f"{acc} = (({acc} * 31 + {tv}) & {MASK})")

    def o_mix(self, lines, acc, f=None):
        """A helper whose row mixes a user effect and an exception kind
        (possibly through an effectset): both are discharged by nested
        handles before the entry."""
        r = self.r
        mixes = [n for n, s in self.efuncs.items() if s["kind"] == "mix"]
        f = f or r.choice(mixes)
        self.used.update([f, self.efuncs[f]["ef"], self.efuncs[f]["th"]])
        n = r.randint(0, 40)
        pre = []
        expr, handlers, tcs, exc = self.discharge(
            f"{f}({n})", self.rows[f], pre, self.int_exc_arm)
        lines += pre
        tv = self.fresh("tm")
        lines.append(f"let {tv} = {expr}")
        try:
            exp = self.eval_fn(f, n, handlers)
        except Thrown as t:
            exp = exc(t)
        self.emit(lines, "T", f"\\{{{tv}}}", str(exp))
        lines.append(f"{acc} = (({acc} * 31 + {tv}) & {MASK})")

    def o_traits(self, lines, acc):
        r = self.r
        tr, st, g1, g2, m1, k1, m2, k2 = self.trait_info
        a = r.randint(0, 60)
        p, q = r.randint(0, 60), r.randint(0, 60)
        p2, q2 = r.randint(0, 60), r.randint(0, 60)
        mi = lambda v: (v * m1 + k1) & MASK  # noqa: E731
        ms = lambda pp, qq: (pp * m2 - qq + k2) & MASK  # noqa: E731
        gv = self.fresh("gv")
        lines.append(f"let {gv} = {g1}({a})")
        self.emit(lines, "R", f"\\{{{gv}}}", str(mi(a)))
        gs = self.fresh("gs")
        lines.append(f"let {gs} = {g1}({st}::{{ q: {q}, p: {p} }})")
        self.emit(lines, "R", f"\\{{{gs}}}", str(ms(p, q)))
        g2v = self.fresh("gw")
        lines.append(
            f"let {g2v} = {g2}({st}::{{ p: {p}, q: {q} }}, {st}::{{ p: {p2}, q: {q2} }})")
        self.emit(lines, "R", f"\\{{{g2v}}}", str((ms(p, q) * 2 - ms(p2, q2)) & MASK))
        lines.append(f"{acc} = (({acc} * 31 + {gv} + {gs}) & {MASK})")


class Gen:
    def __init__(self, seed, liveness=True, liveness_bias=None,
                 extended=False):
        self.r = random.Random(seed)
        # Extended productions (#2979) draw from their OWN stream, so the
        # base program for a seed is the same with or without --extended and
        # a finding in the base part reproduces in both modes.
        self.ext = None
        if extended:
            er = random.Random(seed * 1000003 + 2979)
            self.ext = ExtGen(self, er)
        self.structs = []   # (name, [(fname, ty, is_mut)])
        self.enums = []     # (name, [(vname, [tys])])
        self.helpers = []   # (name, [(argname, ty)], ret_ty, body_lines)
        self.struct_consumers = {}  # sname -> helper name that consumes it
        self.recursors = []  # (name, struct_type, base_case_expr)
        self.uid = 0
        if liveness_bias is not None:
            self.liveness_bias = liveness_bias
        elif liveness:
            self.liveness_bias = (
                LIVENESS_MIN_BIAS
                + self.r.random() * (LIVENESS_MAX_BIAS - LIVENESS_MIN_BIAS))
        else:
            self.liveness_bias = 0.0

    def fresh(self, p):
        self.uid += 1
        return f"{p}{self.uid}"

    # ---------- type declarations ----------

    def gen_types(self):
        # 2-4 structs; force same-named fields at different slots (#722).
        nstructs = self.r.randint(2, 4)
        for i in range(nstructs):
            fields = []
            names = self.r.sample(FIELD_POOL, self.r.randint(2, 4))
            self.r.shuffle(names)
            for fn in names:
                ty = self.r.choice(["Int", "Int", "String"])
                is_mut = ty == "Int" and self.r.random() < 0.3
                fields.append((fn, ty, is_mut))
            self.structs.append((f"S{i}", fields))
        nenums = self.r.randint(1, 2)
        for i in range(nenums):
            variants = []
            for v in range(self.r.randint(2, 3)):
                arity = self.r.randint(0, 2)
                variants.append((f"E{i}V{v}", ["Int"] * arity))
            self.enums.append((f"E{i}", variants))

    def type_decls(self):
        out = []
        for sname, fields in self.structs:
            body = ";\n".join(
                f"  {'mut ' if m else ''}{fn}: {ty}" for fn, ty, m in fields)
            out.append(f"export struct {sname} {{\n{body}\n}}")
        for ename, variants in self.enums:
            body = ";\n".join(
                f"  {vn}" + (f"({', '.join(tys)})" if tys else "")
                for vn, tys in variants)
            out.append(f"export enum {ename} {{\n{body}\n}}")
        return "\n\n".join(out)

    # ---------- expressions ----------

    def int_expr(self, env, depth):
        r = self.r
        ivars = [n for n, t in env if t == "Int"]
        if depth <= 0:
            if ivars and r.random() < 0.7:
                return r.choice(ivars)
            return str(r.randint(0, 99))
        pick = r.random()
        if pick < 0.30:
            op = r.choice(["+", "-", "*", "+", "-"])
            return (f"(({self.int_expr(env, depth - 1)} {op} "
                    f"{self.int_expr(env, depth - 1)}) & {MASK})")
        if pick < 0.38:
            # guarded division / modulo: divisor forced into 1..16
            op = r.choice(["/", "%"])
            return (f"(({self.int_expr(env, depth - 1)} {op} "
                    f"(1 + ({self.int_expr(env, depth - 1)} & 15))) & {MASK})")
        if pick < 0.44:
            op = r.choice(["<<", ">>", "^", "|", "&"])
            return (f"(({self.int_expr(env, depth - 1)} {op} "
                    f"({self.int_expr(env, depth - 1)} & 15)) & {MASK})")
        if pick < 0.54:
            return (f"(if {self.bool_expr(env, depth - 1)} "
                    f"{{ {self.int_expr(env, depth - 1)} }} else "
                    f"{{ {self.int_expr(env, depth - 1)} }})")
        if pick < 0.62:
            svars = [(n, t) for n, t in env if t.startswith("S")]
            if svars:
                n, t = r.choice(svars)
                ifields = [fn for fn, ty, _ in self.struct_fields(t)
                           if ty == "Int"]
                if ifields:
                    return f"({n}.{r.choice(ifields)} & {MASK})"
            return self.int_expr(env, depth - 1)
        if pick < 0.70:
            strs = [n for n, t in env if t == "String"]
            if strs:
                return f"String::length({r.choice(strs)})"
            return self.int_expr(env, depth - 1)
        if pick < 0.80:
            ints_ret = [h for h in self.helpers if h[2] == "Int"]
            if ints_ret:
                name, params, _, _ = r.choice(ints_ret)
                args = ", ".join(self.arg_for(t, env, depth - 1)
                                 for _, t in params)
                return f"{name}({args})"
            return self.int_expr(env, depth - 1)
        if ivars:
            return r.choice(ivars)
        return str(r.randint(0, 99))

    def bool_expr(self, env, depth):
        r = self.r
        if depth <= 0:
            return r.choice(["true", "false"])
        pick = r.random()
        if pick < 0.5:
            op = r.choice(["==", "!=", "<", ">", "<=", ">="])
            return (f"({self.int_expr(env, depth - 1)} {op} "
                    f"{self.int_expr(env, depth - 1)})")
        if pick < 0.7:
            op = r.choice(["&&", "||"])
            return (f"({self.bool_expr(env, depth - 1)} {op} "
                    f"{self.bool_expr(env, depth - 1)})")
        if pick < 0.8:
            return f"!({self.bool_expr(env, depth - 1)})"
        strs = [n for n, t in env if t == "String"]
        if len(strs) >= 1:
            return (f'({r.choice(strs)} == "{r.choice(STR_POOL)}")')
        return f"({self.int_expr(env, depth - 1)} == {r.randint(0, 5)})"

    def str_expr(self, env, depth):
        r = self.r
        svars = [n for n, t in env if t == "String"]
        if depth <= 0 or r.random() < 0.4:
            if svars and r.random() < 0.5:
                return r.choice(svars)
            return f'"{r.choice(STR_POOL)}"'
        pick = r.random()
        if pick < 0.5:
            return (f"String::concat({self.str_expr(env, depth - 1)}, "
                    f"{self.str_expr(env, depth - 1)})")
        if pick < 0.75:
            # string interpolation of a masked int
            return f'"p\\{{{self.int_expr(env, depth - 1)}}}q"'
        sfields = []
        for n, t in env:
            if t.startswith("S"):
                for fn, ty, _ in self.struct_fields(t):
                    if ty == "String":
                        sfields.append(f"{n}.{fn}")
        if sfields:
            return r.choice(sfields)
        return f'"{r.choice(STR_POOL)}"'

    def struct_fields(self, sname):
        for n, fields in self.structs:
            if n == sname:
                return fields
        return []

    def struct_literal(self, sname, env, depth):
        fields = list(self.struct_fields(sname))
        # shuffle literal order vs declared order (#722 construction path)
        self.r.shuffle(fields)
        parts = []
        for fn, ty, _ in fields:
            val = (self.int_expr(env, depth) if ty == "Int"
                   else self.str_expr(env, depth))
            parts.append(f"{fn}: {val}")
        return f"{sname}::{{ {', '.join(parts)} }}"

    def arg_for(self, ty, env, depth):
        if ty == "Int":
            return self.int_expr(env, depth)
        if ty == "String":
            return self.str_expr(env, depth)
        if ty == "Bool":
            return self.bool_expr(env, depth)
        if ty.startswith("S"):
            return self.struct_literal(ty, env, depth)
        return "0"

    # ---------- statements ----------

    def gen_stmts(self, env, acc, n, depth, allow_loops=True):
        r = self.r
        lines = []
        for _ in range(n):
            # --- liveness-aware bias (#765): stress RC/Perceus dup-drop
            # accounting via deep def-use chains, aliasing, conditional
            # moves and cross-scope closure capture. Pure bypass: falls
            # through to the existing generation menu below when it does
            # not fire, so no existing coverage is lost.
            if self.liveness_bias > 0 and r.random() < self.liveness_bias:
                kind = r.random()
                if kind < 0.28:
                    lines += self.gen_def_use_chain(env, acc, depth)
                elif kind < 0.52:
                    lines += self.gen_alias_stmts(env, acc, depth)
                elif kind < 0.78:
                    lines += self.gen_conditional_move(env, acc, depth)
                else:
                    lines += self.gen_cross_scope_capture(env, acc, depth)
                continue
            pick = r.random()
            if pick < 0.22:
                v = self.fresh("i")
                lines.append(f"let {v} = {self.int_expr(env, depth)}")
                env.append((v, "Int"))
            elif pick < 0.32:
                v = self.fresh("s")
                lines.append(f"let {v} = {self.str_expr(env, depth)}")
                env.append((v, "String"))
            elif pick < 0.44:
                sname, _ = r.choice(self.structs)
                v = self.fresh("st")
                lines.append(
                    f"let {v} = {self.struct_literal(sname, env, depth)}")
                env.append((v, sname))
            elif pick < 0.52:
                # mut struct field store (#722 __set_field)
                targets = []
                for n2, t in env:
                    if t.startswith("S"):
                        for fn, ty, m in self.struct_fields(t):
                            if m:
                                targets.append(f"{n2}.{fn}")
                if targets:
                    lines.append(
                        f"{r.choice(targets)} = {self.int_expr(env, depth)}")
                else:
                    v = self.fresh("i")
                    lines.append(f"let {v} = {self.int_expr(env, depth)}")
                    env.append((v, "Int"))
            elif pick < 0.62 and allow_loops:
                # bounded while accumulating into acc
                i = self.fresh("w")
                bound = r.randint(2, 6)
                lines.append(f"let mut {i} = 0")
                lines.append(f"while {i} < {bound} {{")
                lines.append(
                    f"  {acc} = (({acc} * 31 + "
                    f"{self.int_expr(env + [(i, 'Int')], 1)}) & {MASK})")
                lines.append(f"  {i} = {i} + 1")
                lines.append("}")
            elif pick < 0.72 and allow_loops:
                # for-in comprehension + bounded index (#538)
                arr = self.fresh("xs")
                ys = self.fresh("ys")
                elems = ", ".join(str(r.randint(0, 99))
                                  for _ in range(r.randint(2, 5)))
                lines.append(f"let {arr} = [{elems}]")
                lines.append(
                    f"let {ys} = for x in {arr} {{ ((x * 3 + "
                    f"{self.int_expr(env, 1)}) & {MASK}) }}")
                idx = f"(({self.int_expr(env, 1)}) % Array::length({ys}))"
                lines.append(f"{acc} = (({acc} + {ys}[{idx}]) & {MASK})")
            elif pick < 0.82:
                # enum construction + exhaustive match
                ename, variants = r.choice(self.enums)
                vn, tys = r.choice(variants)
                args = (f"({', '.join(self.int_expr(env, 1) for _ in tys)})"
                        if tys else "")
                ev = self.fresh("e")
                lines.append(f"let {ev} = {vn}{args}")
                arms = []
                for wn, wtys in variants:
                    if wtys:
                        binders = [self.fresh("b") for _ in wtys]
                        body = f"(({' + '.join(binders)}) & {MASK})"
                        arms.append(f"  {wn}({', '.join(binders)}) => {body}")
                    else:
                        arms.append(f"  {wn} => {r.randint(0, 9)}")
                mv = self.fresh("m")
                lines.append(
                    f"let {mv} = match {ev} {{\n" + ",\n".join(arms) + "\n}")
                env.append((mv, "Int"))
            elif pick < 0.90:
                # Option round-trip through a helper-ish inline match
                ov = self.fresh("o")
                cond = self.bool_expr(env, 1)
                val = self.int_expr(env, depth)
                lines.append(
                    f"let {ov} = if {cond} {{ Some({val}) }} else {{ None }}")
                mv = self.fresh("m")
                lines.append(
                    f"let {mv} = match {ov} {{ Some(x) => x, None => 7 }}")
                env.append((mv, "Int"))
            else:
                # closure (some with mutable capture)
                k = self.fresh("k")
                f = self.fresh("fn")
                lines.append(f"let {k} = {self.int_expr(env, 1)}")
                if r.random() < 0.4:
                    c = self.fresh("c")
                    lines.append(f"let mut {c} = 0")
                    lines.append(
                        f"let {f} = (n: Int) -> Int {{ {c} = "
                        f"(({c} + n + {k}) & {MASK})\n  {c} }}")
                else:
                    lines.append(
                        f"let {f} = (n: Int) -> Int {{ ((n * 7 + {k}) "
                        f"& {MASK}) }}")
                lines.append(
                    f"{acc} = (({acc} * 17 + {f}({self.int_expr(env, 1)})) "
                    f"& {MASK})")
        return lines

    # ---------- liveness-aware generation (#765) ----------
    #
    # These four generators target the shapes behind vibe's worst historical
    # RC/Perceus bugs (#725 dup/drop corruption, #737 tail-resume argument
    # corruption, #745 RC lane traps): a value that stays live across many
    # intervening operations, an alias of a live value used alongside the
    # original, a value consumed in only one branch of a conditional, and a
    # closure that captures an outer binding but is invoked from elsewhere.
    # Called from gen_stmts under `self.liveness_bias`; see the module
    # docstring.

    def gen_def_use_chain(self, env, acc, depth):
        """A value created early, threaded through several intermediate
        let-bindings/helper calls, consumed only at a sink (folded into
        acc) at the end of the chain -- stays live across many
        intervening operations that might incorrectly drop/dup it."""
        r = self.r
        chain_len = r.randint(3, 6)
        lines = []
        if self.structs and r.random() < 0.4:
            sname, _ = r.choice(self.structs)
            head = self.fresh("duv")
            lines.append(f"let {head} = {self.struct_literal(sname, env, depth)}")
            cur = head
            for _ in range(chain_len):
                nxt = self.fresh("duv")
                # thread the struct forward untouched through intermediate
                # bindings (each rebind is itself an alias of the previous).
                lines.append(f"let {nxt} = {cur}")
                cur = nxt
            consumer = self.struct_consumers.get(sname)
            ifields = [fn for fn, ty, _ in self.struct_fields(sname) if ty == "Int"]
            if consumer:
                lines.append(f"{acc} = (({acc} * 31 + {consumer}({cur})) & {MASK})")
            elif ifields:
                lines.append(
                    f"{acc} = (({acc} * 31 + ({cur}.{r.choice(ifields)} & {MASK})) "
                    f"& {MASK})")
            else:
                lines.append(f"{acc} = (({acc} + 1) & {MASK})")
            env.append((cur, sname))
        else:
            head = self.fresh("duv")
            lines.append(f"let {head} = {self.int_expr(env, depth)}")
            cur = head
            int_helpers = [h for h in self.helpers
                           if h[2] == "Int" and any(pt == "Int" for _, pt in h[1])]
            for _ in range(chain_len):
                nxt = self.fresh("duv")
                if int_helpers and r.random() < 0.5:
                    name, params, _, _ = r.choice(int_helpers)
                    args = []
                    placed = False
                    for _pn, pt in params:
                        if pt == "Int" and not placed:
                            args.append(cur)
                            placed = True
                        else:
                            args.append(self.arg_for(pt, env, 1))
                    lines.append(f"let {nxt} = {name}({', '.join(args)})")
                else:
                    lines.append(
                        f"let {nxt} = (({cur} * 3 + {self.int_expr(env, 1)}) "
                        f"& {MASK})")
                cur = nxt
            lines.append(f"{acc} = (({acc} * 31 + {cur}) & {MASK})")
            env.append((cur, "Int"))
        return lines

    def gen_alias_stmts(self, env, acc, depth):
        """`let b = a` then use of both a and b -- stresses whether the RC
        dup on alias-creation is correct (both must remain independently
        usable/droppable)."""
        r = self.r
        lines = []
        if self.structs and r.random() < 0.6:
            sname, _ = r.choice(self.structs)
            a = self.fresh("al")
            lines.append(f"let {a} = {self.struct_literal(sname, env, depth)}")
            b = self.fresh("al")
            lines.append(f"let {b} = {a}")
            fields = self.struct_fields(sname)
            ifields = [fn for fn, ty, _ in fields if ty == "Int"]
            if ifields:
                fa, fb = r.choice(ifields), r.choice(ifields)
                lines.append(f"{acc} = (({acc} * 31 + {a}.{fa}) & {MASK})")
                lines.append(f"{acc} = (({acc} * 31 + {b}.{fb}) & {MASK})")
            else:
                sfield = fields[0][0]
                lines.append(
                    f"{acc} = (({acc} + String::length({a}.{sfield})) & {MASK})")
                lines.append(
                    f"{acc} = (({acc} + String::length({b}.{sfield})) & {MASK})")
            env.append((a, sname))
            env.append((b, sname))
        else:
            s = self.fresh("as")
            lines.append(f"let {s} = {self.str_expr(env, depth)}")
            t = self.fresh("as")
            lines.append(f"let {t} = {s}")
            lines.append(f"{acc} = (({acc} + String::length({s})) & {MASK})")
            lines.append(f"{acc} = (({acc} + String::length({t})) & {MASK})")
            env.append((s, "String"))
            env.append((t, "String"))
        return lines

    def gen_conditional_move(self, env, acc, depth):
        """A value consumed in only ONE branch of an if -- stresses whether
        the other branch correctly drops it, and whether an outer scope's
        later use after the conditional is still valid."""
        r = self.r
        lines = []
        sname, _ = r.choice(self.structs)
        cm = self.fresh("cm")
        lines.append(f"let {cm} = {self.struct_literal(sname, env, depth)}")
        consumer = self.struct_consumers.get(sname)
        cond = self.bool_expr(env, 1)
        cmv = self.fresh("cmv")
        if consumer:
            # only the `if`-branch moves/consumes cm via the helper call;
            # the `else`-branch never touches it at all.
            lines.append(
                f"let {cmv} = if {cond} {{ {consumer}({cm}) }} "
                f"else {{ {r.randint(0, 9)} }}")
        else:
            lines.append(f"let {cmv} = if {cond} {{ 1 }} else {{ 0 }}")
        lines.append(f"{acc} = (({acc} * 31 + {cmv}) & {MASK})")
        # later use in the outer scope, after the conditional resolves,
        # regardless of which branch was taken at runtime.
        ifields = [fn for fn, ty, _ in self.struct_fields(sname) if ty == "Int"]
        if ifields:
            lines.append(
                f"{acc} = (({acc} + ({cm}.{r.choice(ifields)} & {MASK})) & {MASK})")
        env.append((cm, sname))
        env.append((cmv, "Int"))
        return lines

    def gen_cross_scope_capture(self, env, acc, depth):
        """A closure defined inside one branch of an `if` (a nested
        expression scope) that captures a `let`-bound aggregate or a `mut`
        variable from the enclosing scope, then gets invoked from the
        outer scope after the `if` resolves -- stresses capture-time dup
        accounting."""
        r = self.r
        lines = []
        cond = self.bool_expr(env, 1)
        fn = self.fresh("xfn")
        if self.structs and r.random() < 0.5:
            sname, _ = r.choice(self.structs)
            cap = self.fresh("cap")
            lines.append(f"let {cap} = {self.struct_literal(sname, env, depth)}")
            ifields = [fn2 for fn2, ty, _ in self.struct_fields(sname) if ty == "Int"]
            if ifields:
                body_a = f"(({cap}.{r.choice(ifields)} + n) & {MASK})"
            else:
                body_a = f"(n & {MASK})"
            lines.append(
                f"let {fn} = if {cond} {{ (n: Int) -> Int {{ {body_a} }} }} "
                f"else {{ (n: Int) -> Int {{ ((n * 2) & {MASK}) }} }}")
            env.append((cap, sname))
        else:
            cap = self.fresh("capm")
            lines.append(f"let mut {cap} = {r.randint(0, 9)}")
            lines.append(
                f"let {fn} = if {cond} {{ (n: Int) -> Int {{\n"
                f"  {cap} = (({cap} + n) & {MASK})\n"
                f"  {cap}\n"
                f"}} }} else {{ (n: Int) -> Int {{\n"
                f"  {cap} = (({cap} + n + 1) & {MASK})\n"
                f"  {cap}\n"
                f"}} }}")
            lines.append(f"{acc} = (({acc} + {cap}) & {MASK})")
            env.append((cap, "Int"))
        arg = self.int_expr(env, 1)
        lines.append(f"{acc} = (({acc} * 13 + {fn}({arg})) & {MASK})")
        return lines

    # ---------- helpers (top-level functions) ----------

    def gen_helpers(self):
        r = self.r
        # struct-consuming helpers (take the struct BY VALUE, i.e. move it
        # across a call boundary) -- used by the def-use-chain and
        # conditional-move liveness generators as an explicit sink/move
        # site. Built before the f0..fN loop so those bodies (via
        # gen_stmts -> the liveness generators) can already call them.
        for sname, _ in self.structs:
            if r.random() < 0.85:
                hname = f"consume_{sname.lower()}"
                fields = self.struct_fields(sname)
                ifields = [fn for fn, ty, _ in fields if ty == "Int"]
                sfields = [fn for fn, ty, _ in fields if ty == "String"]
                parts = []
                if ifields:
                    parts.append(f"(v.{r.choice(ifields)} & {MASK})")
                if sfields:
                    parts.append(f"String::length(v.{r.choice(sfields)})")
                if not parts:
                    parts.append("1")
                body = [f"(({' + '.join(parts)}) & {MASK})"]
                self.helpers.append((hname, [("v", sname)], "Int", body))
                self.struct_consumers[sname] = hname
        for i in range(r.randint(3, 6)):
            name = f"f{i}"
            nparams = r.randint(1, 3)
            params = []
            for p in range(nparams):
                ty = r.choice(["Int", "Int", "String", "Bool"])
                params.append((f"a{p}", ty))
            ret = r.choice(["Int", "Int", "Int", "String"])
            env = list(params)
            body = []
            acc = "h"
            body.append(f"let mut {acc} = 1")
            body += self.gen_stmts(env, acc, r.randint(1, 3), 2,
                                   allow_loops=(r.random() < 0.5))
            if ret == "Int":
                body.append(f"(({acc} + {self.int_expr(env, 2)}) & {MASK})")
            else:
                body.append(self.str_expr(env, 2))
            self.helpers.append((name, params, ret, body))
        # one helper returning Option[struct] across a call boundary (#722)
        sname, _ = r.choice(self.structs)
        env = [("a0", "Int")]
        body = [
            f"if a0 > 2 {{ Some({self.struct_literal(sname, env, 1)}) }} "
            f"else {{ None }}"
        ]
        self.helpers.append((f"mk_{sname.lower()}", [("a0", "Int")],
                             f"Option[{sname}]", body))
        self.opt_struct = sname

        # tail-resume-shaped recursion (#765, approximates #737 without
        # needing effect handlers): a struct is threaded UNTOUCHED through
        # `n` stack frames and only read at the base case. Depth is capped
        # by a literal argument at the call site (see gen_main), never by
        # arbitrary generated ints, so this stays trap-free/hang-free by
        # construction. Kept out of self.helpers (and thus out of the
        # generic Int-returning-helper call pool used by int_expr/
        # gen_def_use_chain) so it can never be invoked with an
        # unbounded/generated depth.
        if self.liveness_bias > 0:
            for _ in range(r.randint(1, 2)):
                sname, _ = r.choice(self.structs)
                ifields = [fn for fn, ty, _ in self.struct_fields(sname)
                           if ty == "Int"]
                rname = self.fresh("carry_walk")
                base = (f"(carried.{r.choice(ifields)} & {MASK})"
                        if ifields else "0")
                self.recursors.append((rname, sname, base))

    def helper_decls(self):
        out = []
        for name, params, ret, body in self.helpers:
            sig_params = ", ".join(t for _, t in params)
            arg_names = ", ".join(n for n, _ in params)
            body_txt = "\n".join("  " + l for l in body)
            out.append(
                f"export let {name}: ({sig_params}) -> {ret} = "
                f"({arg_names}) -> {{\n{body_txt}\n}}")
        return "\n\n".join(out)

    def recursor_decls(self):
        # `fn` supports self-recursion with no `rec` keyword needed (see
        # docs/user/reference/cheatsheet.md); each frame either recurses with the carried
        # value untouched, or (base case) consumes it.
        out = []
        for rname, sname, base in self.recursors:
            out.append(
                f"export fn {rname}(n: Int, carried: {sname}) -> Int {{\n"
                f"  if n <= 0 {{ {base} }} else {{ {rname}(n - 1, carried) }}\n"
                f"}}")
        return "\n\n".join(out)

    # ---------- main ----------

    def gen_main(self):
        r = self.r
        env = []
        lines = ["let mut acc = 1"]
        lines += self.gen_stmts(env, "acc", r.randint(6, 12), 3)
        # Option[struct] across a call boundary, read an Int field (#722)
        sname = self.opt_struct
        ifields = [fn for fn, ty, _ in self.struct_fields(sname)
                   if ty == "Int"]
        sfields = [fn for fn, ty, _ in self.struct_fields(sname)
                   if ty == "String"]
        arm = []
        if ifields:
            arm.append(f"(b.{r.choice(ifields)} & {MASK})")
        if sfields:
            arm.append(f"String::length(b.{r.choice(sfields)})")
        arm_val = f"(({' + '.join(arm)}) & {MASK})" if arm else "3"
        lines.append(
            f"let ob = mk_{sname.lower()}({r.randint(0, 6)})")
        lines.append(
            f"let obv = match ob {{ Some(b) => {arm_val}, None => 5 }}")
        lines.append(f"acc = ((acc * 13 + obv) & {MASK})")
        # tail-resume-shaped recursion (#765): bounded depth literal so
        # this stays trap-free/hang-free by construction; the carried
        # struct is only consumed at the base case, many frames down.
        for rname, sname, _base in self.recursors:
            depth_arg = r.randint(5, 15)
            cw = self.fresh("cw")
            lines.append(
                f"let {cw} = {rname}({depth_arg}, "
                f"{self.struct_literal(sname, env, 1)})")
            lines.append(f"acc = ((acc * 7 + {cw}) & {MASK})")
        if self.ext is not None:
            # #2979: effect / exception / container / generic productions,
            # each printing an oracle line with a generation-known answer.
            self.ext.gen_decls()
            lines += self.ext.oracle_stmts("acc")
        # fold in every live Int/String binding so miscompiled slots surface
        for n, t in env:
            if t == "Int":
                lines.append(f"acc = ((acc * 31 + {n}) & {MASK})")
            elif t == "String":
                lines.append(f"acc = ((acc * 31 + String::length({n})) & {MASK})")
            elif t.startswith("S"):
                for fn, ty, _ in self.struct_fields(t):
                    if ty == "Int":
                        lines.append(
                            f"acc = ((acc * 31 + {n}.{fn}) & {MASK})")
                    else:
                        lines.append(
                            f"acc = ((acc * 31 + "
                            f"String::length({n}.{fn})) & {MASK})")
        lines.append("acc")
        body = "\n".join("  " + l for l in lines)
        # The oracle lines are printed, so the extended entry carries
        # Stdout -- and nothing else: every user effect and exception kind
        # was discharged by a handle above (ExtGen.discharge).
        row = " with Stdout" if self.ext is not None else ""
        return f"export let _start = () -> Int{row} {{\n{body}\n}}"

    def build(self):
        self.gen_types()
        self.gen_helpers()
        main = self.gen_main()
        ext = "\n\n".join(self.ext.decls) if self.ext is not None else ""
        return (self.type_decls(), self.helper_decls(), self.recursor_decls(),
                ext, main)


def main():
    args = sys.argv[1:]
    positional = [a for a in args if not a.startswith("--")]
    seed = int(positional[0])
    outdir = positional[1]
    classic = "--classic" in args
    extended = "--extended" in args
    liveness_bias = None
    for a in args:
        if a.startswith("--liveness-bias="):
            liveness_bias = float(a.split("=", 1)[1])

    g = Gen(seed, liveness=not classic, liveness_bias=liveness_bias,
            extended=extended)
    types, helpers, recursors, ext, mainfn = g.build()
    helper_block = "\n\n".join(p for p in (helpers, recursors, ext) if p)

    single = f"// fuzz seed {seed}\n{types}\n\n{helper_block}\n\n{mainfn}\n"
    with open(f"{outdir}/single.vibe", "w") as f:
        f.write(single)

    with open(f"{outdir}/defs.vibe", "w") as f:
        f.write(f"// fuzz seed {seed} (defs)\n{types}\n\n{helper_block}\n")
    imports = ([n for n, _ in g.structs] + [n for n, _ in g.enums]
               + [h[0] for h in g.helpers]
               + [rn for rn, _, _ in g.recursors])
    if g.ext is not None:
        imports += g.ext.exports
    with open(f"{outdir}/main.vibe", "w") as f:
        f.write(f"// fuzz seed {seed} (main)\n"
                f"import ./defs.vibe {{ {', '.join(imports)} }}\n\n"
                f"{mainfn}\n")

    # The lane-independent oracle (#2979): one `<ID>|<text>` line per
    # generation-known value, in the order the program prints them. Written
    # only in extended mode, so a classic/liveness program is judged exactly
    # as before.
    if g.ext is not None:
        with open(f"{outdir}/expected.txt", "w") as f:
            for oid, text in g.ext.expected:
                f.write(f"{oid}|{text}\n")
        skip = g.ext.skip_lanes()
        if skip:
            with open(f"{outdir}/skip_lanes", "w") as f:
                f.write(" ".join(skip) + "\n")


if __name__ == "__main__":
    main()
