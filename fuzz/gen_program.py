#!/usr/bin/env python3
"""Seeded random vibe program generator for differential fuzzing.

Generates a deterministic, well-typed, trap-free-by-construction vibe
program from an integer seed. The same seed also yields an FS-linked
split (defs.vibe + main.vibe) so single-file and multi-module lanes can
be diffed against each other.

Design notes:
- No expected-value oracle: the harness (run_fuzz.sh) diffs the program's
  result across bump / RC / wasm-gc backends and the FS-linked lane.
  Any divergence, compile diagnostic, trap, or hang on a generated
  program is a finding.
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

Usage: gen_program.py SEED OUTDIR [--classic] [--liveness-bias=X]
  --classic          disable the liveness-aware bias (legacy behavior)
  --liveness-bias=X  force the bias probability to X (0.0..1.0), instead
                      of the seed-derived default; mostly for testing.
Writes OUTDIR/single.vibe, OUTDIR/defs.vibe, OUTDIR/main.vibe.
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


class Gen:
    def __init__(self, seed, liveness=True, liveness_bias=None):
        self.r = random.Random(seed)
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
        # docs/cheatsheet.md); each frame either recurses with the carried
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
        return f"export let _start = () -> Int {{\n{body}\n}}"

    def build(self):
        self.gen_types()
        self.gen_helpers()
        main = self.gen_main()
        return self.type_decls(), self.helper_decls(), self.recursor_decls(), main


def main():
    args = sys.argv[1:]
    positional = [a for a in args if not a.startswith("--")]
    seed = int(positional[0])
    outdir = positional[1]
    classic = "--classic" in args
    liveness_bias = None
    for a in args:
        if a.startswith("--liveness-bias="):
            liveness_bias = float(a.split("=", 1)[1])

    g = Gen(seed, liveness=not classic, liveness_bias=liveness_bias)
    types, helpers, recursors, mainfn = g.build()
    helper_block = "\n\n".join(p for p in (helpers, recursors) if p)

    single = f"// fuzz seed {seed}\n{types}\n\n{helper_block}\n\n{mainfn}\n"
    with open(f"{outdir}/single.vibe", "w") as f:
        f.write(single)

    with open(f"{outdir}/defs.vibe", "w") as f:
        f.write(f"// fuzz seed {seed} (defs)\n{types}\n\n{helper_block}\n")
    imports = ([n for n, _ in g.structs] + [n for n, _ in g.enums]
               + [h[0] for h in g.helpers]
               + [rn for rn, _, _ in g.recursors])
    with open(f"{outdir}/main.vibe", "w") as f:
        f.write(f"// fuzz seed {seed} (main)\n"
                f"import ./defs.vibe {{ {', '.join(imports)} }}\n\n"
                f"{mainfn}\n")


if __name__ == "__main__":
    main()
