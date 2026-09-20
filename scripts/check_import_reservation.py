#!/usr/bin/env python3
"""#2905: every user-callable capability spelling must RESERVE the import it lowers onto.

`linked_compile.vibe` maps builtin names onto host-import indices
(`"Console::read_char" => stdin_read_char_idx`). Those indices are the import
only WHEN THE IMPORT IS RESERVED; unreserved, they fall back to a never-called
stub of a different arity. So a name that is mapped but never reserved compiles
CLEAN, writes a `.wasm`, reports success, and produces a module that does not
validate -- "not enough arguments on the stack for call (need 1, got 0)".

That is #2905, and it is the third of its family: #1460 (`Console::write_char`,
`Console::write_err_char`), #2903 (`sleep_blocking`), #2905
(`Console::read_char`). Each was fixed by remembering to add the name in the
other place, which is exactly the step that keeps being missed. This asks the
question mechanically instead.

SCOPE, and why it is narrower than "every mapped name":

  - Only names the REGISTRY declares, so private lowering targets invented by
    codegen are out of scope.
  - Only `Provider::lower_snake_op` spellings -- what a user can write and grant
    at an entry point. Excluded, with measurements:
      * `vibe_sh_lines_raw`, `vibe_fs_read_dir_raw`, `resolve_path` are LOWERING
        targets; the reservation fires on the user spelling (`sh_lines`,
        `Fs::readdir`, `Path::ref`/`Path::resolve`), so the map name and the
        reserved name legitimately differ.
      * `Profiler::NowUs` / `Profiler::HeapBytes` are the CamelCase algebraic
        operation spellings. Measured: `allows Profiler::NowUs` on an entry
        point is REFUSED ("entry point 'main' grants `Profiler::NowUs`, but
        ..."), so they are unreachable without the lowercase sibling, which is
        reserved.
  - Only indices that are CONDITIONALLY reserved (`let X_idx = if
    X_import_idx >= 0 { .. } else { stub }`). An unconditional index cannot
    fall back and so cannot exhibit this.
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Overridable ONLY so the companion red test can point the gate at a mutated
# copy of a real input; unset on every real invocation.
LINKED = Path(os.environ.get("VIBE_IMPORT_RESERVATION_LINKED") or
              ROOT / "lib/@vibe/compiler/codegen/wasi/linked_compile.vibe")
REGISTRY = Path(os.environ.get("VIBE_IMPORT_RESERVATION_REGISTRY") or
                ROOT / "lib/@vibe/compiler/core/builtin_registry.vibe")

# A spelling a user can write AND grant: `Provider::lower_snake_op`.
USER_SPELLING = re.compile(r"^[A-Z][A-Za-z0-9]*::[a-z][a-z0-9_]*$")


def die(message: str) -> None:
    print(f"import-reservation: {message}", file=sys.stderr)
    raise SystemExit(1)


def registry_names(text: str) -> set[str]:
    names = set(re.findall(r'\(\s*"([A-Za-z_][A-Za-z0-9_:]*)"\s*,\s*CtFn\(', text))
    if not names:
        die("could not parse any registry rows; the parser has drifted")
    return names


def conditional_indices(text: str) -> set[str]:
    found = {a for a, _ in re.findall(r"let\s+(\w+_idx)\s*=\s*if\s+(\w+_import_idx)\s*>=\s*0", text)}
    if not found:
        die("could not parse any conditionally-reserved import indices; the parser has drifted")
    return found


def reserved_names(text: str) -> set[str]:
    found = set(re.findall(r'Map::has_key\(used_builtin_names,\s*"([^"]+)"\)', text))
    if not found:
        die("could not parse any reservation predicates; the parser has drifted")
    return found


def mapped_names(text: str) -> list[tuple[str, str]]:
    return [(m.group(1), m.group(2)) for m in re.finditer(r'"([A-Za-z_][A-Za-z0-9_:$]*)"\s*=>\s*(\w+_idx)\s*,', text)]


def unreserved(linked: str, registry: str) -> list[tuple[str, str]]:
    names = registry_names(registry)
    conditional = conditional_indices(linked)
    reserved = reserved_names(linked)
    out = []
    for name, index in mapped_names(linked):
        if index in conditional and name in names and USER_SPELLING.match(name) and name not in reserved:
            out.append((name, index))
    return out


def main() -> None:
    linked = LINKED.read_text()
    registry = REGISTRY.read_text()
    checked = [
        (n, i) for n, i in mapped_names(linked)
        if i in conditional_indices(linked) and n in registry_names(registry) and USER_SPELLING.match(n)
    ]
    if not checked:
        die("no user-callable mapped name was checked at all; the parser has drifted")
    bad = unreserved(linked, registry)
    if bad:
        lines = "\n".join(
            f"  {name} lowers onto {index} but never reserves it" for name, index in sorted(bad)
        )
        die(
            "a user-callable capability is mapped onto a conditionally-reserved import\n"
            "it never reserves, so a program using only that spelling builds clean and\n"
            "emits a module that does not validate (#2905):\n" + lines
        )
    print(f"import-reservation: ok ({len(checked)} user-callable spellings all reserve the import they lower onto)")


if __name__ == "__main__":
    main()
