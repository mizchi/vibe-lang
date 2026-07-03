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

Usage: gen_program.py SEED OUTDIR
Writes OUTDIR/single.vibe, OUTDIR/defs.vibe, OUTDIR/main.vibe.
"""
import random
import sys

MASK = 1048575  # 2^20 - 1: keeps every intermediate small + non-negative

FIELD_POOL = ["name", "kind", "v", "x", "y", "w", "tagf", "size"]
STR_POOL = ["alpha", "beta", "route", "k", "", "nested"]


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.structs = []   # (name, [(fname, ty, is_mut)])
        self.enums = []     # (name, [(vname, [tys])])
        self.helpers = []   # (name, [(argname, ty)], ret_ty, body_lines)
        self.uid = 0

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

    # ---------- helpers (top-level functions) ----------

    def gen_helpers(self):
        r = self.r
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
        return self.type_decls(), self.helper_decls(), main


def main():
    seed = int(sys.argv[1])
    outdir = sys.argv[2]
    g = Gen(seed)
    types, helpers, mainfn = g.build()

    single = f"// fuzz seed {seed}\n{types}\n\n{helpers}\n\n{mainfn}\n"
    with open(f"{outdir}/single.vibe", "w") as f:
        f.write(single)

    with open(f"{outdir}/defs.vibe", "w") as f:
        f.write(f"// fuzz seed {seed} (defs)\n{types}\n\n{helpers}\n")
    imports = ([n for n, _ in g.structs] + [n for n, _ in g.enums]
               + [h[0] for h in g.helpers])
    with open(f"{outdir}/main.vibe", "w") as f:
        f.write(f"// fuzz seed {seed} (main)\n"
                f"import ./defs.vibe {{ {', '.join(imports)} }}\n\n"
                f"{mainfn}\n")


if __name__ == "__main__":
    main()
