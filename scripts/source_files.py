"""Read explicit local implementation modules for source-based gates."""
from __future__ import annotations

from pathlib import Path
import re
import sys


def read_source_group(path: str | Path) -> str:
    entry = Path(path).resolve()
    seen: set[Path] = set()

    def visit(file: Path) -> str:
        if file in seen:
            return ""
        seen.add(file)
        text = file.read_text()
        children: list[Path] = []
        if entry.suffix == ".vibe" and "// Compatibility exports; implementations are grouped" in entry.read_text():
            for target in re.findall(r"^(?:import|export) (\./\S+) \{", text, re.M):
                child = (file.parent / target).resolve()
                if child.parent == entry.parent and child.stem.startswith(entry.stem + "_"):
                    children.append(child)
        elif entry.suffix == ".rs" and "mod host_imports;" in entry.read_text():
            children = [file.parent / (name + ".rs") for name in re.findall(r"^mod (\w+);", text, re.M)]
        elif entry.suffix == ".js":
            children = [(file.parent / target).resolve() for target in re.findall(r'require\("(\./[^"\n]+\.js)"\)', text)]
        return text + "\n" + "\n".join(visit(child) for child in children)

    return visit(entry)


def read_local_pkl(path: str | Path) -> str:
    """Dependencies first, so shared declarations precede their root aliases."""
    seen: set[Path] = set()

    def visit(file: Path) -> str:
        file = file.resolve()
        if file in seen:
            return ""
        seen.add(file)
        text = file.read_text()
        children = []
        for target in re.findall(r'^import "([^"\n]+)"', text, re.M):
            if ":" not in target:
                children.append(visit(file.parent / target))
        return "\n".join(children + [text])

    return visit(Path(path))


if __name__ == "__main__":
    print(read_source_group(sys.argv[1]).replace("// Compatibility exports; implementations are grouped by their dependencies.", "// Flattened source group for a gate mutation."), end="")
