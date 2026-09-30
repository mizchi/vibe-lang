#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# 108/108. The ADR-0068 concurrency surface is opt-in (#2248).
#      docs/user/reference/stable-surface.md said the unstable surface "is reached only
#      through `@build.unstable`, an explicit flag, or an ADR still marked
#      `proposed`" -- and `@build.unstable` appeared nowhere else in the tree,
#      there was no such flag, and `TaskGroup::run` checked clean with no
#      marker of any kind.
#
#      BOTH verbs, because a build that accepts what the check rejects is the
#      "two verbs, two answers" defect #1567 fixed for check/diagnostics, and
#      it is worse here: the accepting verb is the one that ships. And three
#      directions each, since any one alone is satisfiable by the wrong thing
#      -- silence would also pass if the gate were deleted, rejection would
#      also pass if the opt-in did nothing, and both would pass if it rejected
#      every file.
echo "[compiler-gate] 108/108 the ADR-0068 concurrency surface is opt-in, in check AND build (#2248)"
uwdir="_build/_gate_unstable_warn"
rm -rf "$uwdir"; mkdir -p "$uwdir"
cat > "$uwdir/uses.vibe" <<'UWEOF'
import @vibe/concurrent/experimental { TaskGroup }

fn main() -> Int allows Exception {
  TaskGroup::run((n) -> {
    let _t = TaskGroup::spawn(n, () -> { 7 })
    0
  })
}
UWEOF
cat > "$uwdir/plain.vibe" <<'UWEOF'
fn main() -> Int { 1 + 1 }
UWEOF
# `env -u VIBE_UNSTABLE`: the no-opt-in cases must not inherit the opt-in.
# Measured -- with VIBE_UNSTABLE=1 in the ambient environment this section
# reported "did not reject" and would have passed vacuously had the assertion
# been the other way round. Same defect #2252 found in five self-tests: a
# check that measures the machine, not the property.
uw_check() { env -u VIBE_UNSTABLE VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" check "$1" 2>&1; }
uw_build() { # <src> <out> [extra env assignments...]
  local src="$1" out="$2"; shift 2
  rm -f "$out" "$out.diag"
  env -u VIBE_UNSTABLE "$@" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$src" "$out" main >/dev/null 2>&1 || true
}
# check: rejected, opt-in accepted, unrelated file untouched.
#
# Captured into a variable, not piped: this gate runs under `set -o pipefail`,
# and `uw_check` exits 1 on the rejection it is asserting, so `uw_check | grep`
# fails even when grep MATCHES. Measured -- the first version reported "vibe
# check accepted @vibe/concurrent/experimental" while the rejection it was looking for was
# printed one line above it in the same log.
uw_uses_out="$(uw_check "$uwdir/uses.vibe" || true)"
if ! printf '%s\n' "$uw_uses_out" | grep -qF 'VIBE_UNSTABLE=1'; then
  echo "[compiler-gate] FAIL: vibe check accepted @vibe/concurrent/experimental with no opt-in (#2248)" >&2
  printf '%s\n' "$uw_uses_out" >&2
  exit 1
fi
if ! VIBE_UNSTABLE=1 VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" check "$uwdir/uses.vibe" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not let vibe check through (#2248)" >&2
  exit 1
fi
uw_plain_out="$(uw_check "$uwdir/plain.vibe" || true)"
if printf '%s\n' "$uw_plain_out" | grep -qF 'VIBE_UNSTABLE=1'; then
  echo "[compiler-gate] FAIL: a file not importing @vibe/concurrent/experimental was rejected anyway (#2248)" >&2
  printf '%s\n' "$uw_plain_out" >&2
  exit 1
fi

# build: the same three, through the FS-compile lane.
uw_build "$uwdir/uses.vibe" "$uwdir/uses.wasm"
if [ -s "$uwdir/uses.wasm" ]; then
  echo "[compiler-gate] FAIL: vibe build accepted @vibe/concurrent/experimental with no opt-in -- the build accepts what the check rejects (#2248)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/uses.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the build rejection did not name the opt-in (#2248)" >&2
  cat "$uwdir/uses.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
uw_build "$uwdir/uses.vibe" "$uwdir/uses_optin.wasm" VIBE_UNSTABLE=1
if [ ! -s "$uwdir/uses_optin.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not let the build through (#2248)" >&2
  cat "$uwdir/uses_optin.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
uw_build "$uwdir/plain.vibe" "$uwdir/plain.wasm"
if [ ! -s "$uwdir/plain.wasm" ]; then
  echo "[compiler-gate] FAIL: a file not importing @vibe/concurrent/experimental failed to build (#2248)" >&2
  cat "$uwdir/plain.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

# The stable core needs no opt-in: `@vibe/concurrent` re-exports the task
# group, channel and `Parallel::map` subset of the experimental package, and
# both check and build take it with the variable cleared. It must not carry the
# rest: importing the TYPE `TaskGroup` from it does not bring
# `TaskGroup::spawn_suspend` along (a type publishes its constructors, not
# every function sharing its prefix).
cat > "$uwdir/stable.vibe" <<'UWEOF'
import @vibe/concurrent { TaskGroup::run, TaskGroup::spawn, TaskHandle::join }

fn main() -> Int allows Exception {
  TaskGroup::run((g) -> {
    let t = TaskGroup::spawn(g, () -> { 7 })
    TaskHandle::join(t)
  })
}
UWEOF
cat > "$uwdir/stable_leak.vibe" <<'UWEOF'
import @vibe/concurrent { TaskGroup::run, struct TaskGroup }

fn main() -> Int allows Exception {
  TaskGroup::run((g) -> {
    let _t = TaskGroup::spawn_suspend(g, () -> Int with Async + Exception { 7 })
    0
  })
}
UWEOF
uw_stable_out="$(uw_check "$uwdir/stable.vibe" || true)"
if [ -n "$uw_stable_out" ]; then
  echo "[compiler-gate] FAIL: vibe check rejected the stable @vibe/concurrent with no opt-in" >&2
  printf '%s\n' "$uw_stable_out" >&2
  exit 1
fi
uw_build "$uwdir/stable.vibe" "$uwdir/stable.wasm"
if [ ! -s "$uwdir/stable.wasm" ]; then
  echo "[compiler-gate] FAIL: the stable @vibe/concurrent did not build with no opt-in" >&2
  cat "$uwdir/stable.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
uw_leak_out="$(VIBE_UNSTABLE=1 VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$stage2_wasm" \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" check "$uwdir/stable_leak.vibe" 2>&1 || true)"
if ! printf '%s\n' "$uw_leak_out" | grep -qF 'TaskGroup::spawn_suspend'; then
  echo "[compiler-gate] FAIL: importing TaskGroup from the stable @vibe/concurrent exposed TaskGroup::spawn_suspend" >&2
  printf '%s\n' "$uw_leak_out" >&2
  exit 1
fi

# Whitespace must not cross the boundary (#2277 review). The first version of
# the scan matched `String::starts_with(line, "import ")` and sliced a fixed 7
# bytes, so a tab skipped the check outright and two spaces yielded an empty
# package name. Both spellings are valid source the lexer accepts, so both were
# a silent bypass; the gate now reads the PARSED import instead. Written with
# printf rather than a heredoc so the tab survives being read back.
printf 'import\t@vibe/concurrent/experimental { TaskGroup }\n\nfn main() -> Int allows Exception {\n  TaskGroup::run((n) -> { 0 })\n}\n' > "$uwdir/tab.vibe"
printf 'import  @vibe/concurrent/experimental { TaskGroup }\n\nfn main() -> Int allows Exception {\n  TaskGroup::run((n) -> { 0 })\n}\n' > "$uwdir/spaces.vibe"
for uw_odd in tab spaces; do
  uw_odd_out="$(uw_check "$uwdir/$uw_odd.vibe" || true)"
  if ! printf '%s\n' "$uw_odd_out" | grep -qF 'VIBE_UNSTABLE=1'; then
    echo "[compiler-gate] FAIL: '$uw_odd' whitespace spelling of the import bypassed the check gate (#2277)" >&2
    printf '%s\n' "$uw_odd_out" >&2
    exit 1
  fi
  uw_build "$uwdir/$uw_odd.vibe" "$uwdir/$uw_odd.wasm"
  if [ -s "$uwdir/$uw_odd.wasm" ]; then
    echo "[compiler-gate] FAIL: '$uw_odd' whitespace spelling of the import bypassed the build gate (#2277)" >&2
    exit 1
  fi
done

# The reported line must be the OFFENDING import, not the first line that
# mentions the package. `import @vibe/core { .. } // @vibe/concurrent/experimental` is a
# stable import carrying the name in a comment; naming it told the reader to
# delete a line that was not the problem, which is worse than no line at all
# (#2277 review). The offending import is on line 3 here.
cat > "$uwdir/comment.vibe" <<'UWEOF'
import @vibe/core { array_empty } // @vibe/concurrent/experimental

import @vibe/concurrent/experimental { TaskGroup }

fn main() -> Int allows Exception {
  TaskGroup::run((n) -> { 0 })
}
UWEOF
uw_build "$uwdir/comment.vibe" "$uwdir/comment.wasm"
if ! grep -qF 'line 3:' "$uwdir/comment.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the opt-in diagnostic named the wrong import line (#2277)" >&2
  cat "$uwdir/comment.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

# A PINNED `require` header must not silence the gate. The build ingests before
# it parses, and ingestion blanks that header; a scan that read the raw bytes
# instead met the `#` in `#pkg:sha1:...`, the lexer refused it ("unknown #
# directive"), the parse yielded nothing, and the gate went silent while the
# build compiled the unstable import. Measured: unpinned produced the
# diagnostic, pinned produced none (#2277 review).
#
# The pin here is deliberately bogus, so the build fails either way -- what is
# asserted is WHICH diagnostic comes out. A pin error means the gate never
# spoke.
cat > "$uwdir/pinned.vibe" <<'UWEOF'
require @vibe/concurrent/experimental 0.0.1 = #pkg:sha1:0123456789abcdef0123456789abcdef01234567

import @vibe/concurrent/experimental { TaskGroup }

fn main() -> Int allows Exception {
  TaskGroup::run((n) -> { 0 })
}
UWEOF
uw_build "$uwdir/pinned.vibe" "$uwdir/pinned.wasm"
if [ -s "$uwdir/pinned.wasm" ]; then
  echo "[compiler-gate] FAIL: a pinned-require entry built against @vibe/concurrent/experimental with no opt-in (#2277)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/pinned.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a pinned require header silenced the opt-in gate (#2277)" >&2
  cat "$uwdir/pinned.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

# The path may be on the NEXT line. `import\n  @vibe/concurrent/experimental { .. }` is valid
# source; a same-line search missed it and fell back to line 1, naming an
# unrelated declaration. The location comes from the lexer now, so this and the
# comment case above are the same rule rather than two patches (#2277 review).
# The import here starts on line 5.
printf 'fn helper() -> Int {\n  1\n}\n\nimport\n  @vibe/concurrent/experimental { TaskGroup }\n\nfn main() -> Int allows Exception {\n  TaskGroup::run((n) -> { 0 })\n}\n' > "$uwdir/multiline.vibe"
uw_build "$uwdir/multiline.vibe" "$uwdir/multiline.wasm"
if ! grep -qF 'line 5:' "$uwdir/multiline.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a multiline import declaration got the wrong line (#2277)" >&2
  cat "$uwdir/multiline.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

# The BUFFER lane must agree too. `vibe check --single-file` (VIBE_DIAGNOSTICS)
# does not resolve imports, so an UNUSED `import @vibe/concurrent/experimental` analyzed
# clean there while both other verbs rejected the same file -- an editor showing
# nothing is the third answer to the same question (#2277 review). Unused on
# purpose: that is the shape that slipped through.
cat > "$uwdir/buffer.vibe" <<'UWEOF'
import @vibe/concurrent/experimental { TaskGroup }

fn main() -> Int {
  1
}
UWEOF
rm -f "$uwdir/buffer.out"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DIAGNOSTICS=1   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$uwdir/buffer.vibe" "$uwdir/buffer.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/buffer.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the single-file diagnostics lane accepted an unstable import (#2277)" >&2
  cat "$uwdir/buffer.out" >&2 2>/dev/null || true
  exit 1
fi
rm -f "$uwdir/buffer.optin.out"
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DIAGNOSTICS=1   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$uwdir/buffer.vibe" "$uwdir/buffer.optin.out" __no_entry__ >/dev/null 2>&1 || true
if grep -qF 'VIBE_UNSTABLE=1' "$uwdir/buffer.optin.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not clear the single-file diagnostic (#2277)" >&2
  cat "$uwdir/buffer.optin.out" >&2 2>/dev/null || true
  exit 1
fi
# ...and the JSON form of that same buffer lane, which is what the editor
# actually consumes. It serialized only `collect_all_diagnostics`, so it
# answered `[]` while the text form reported the error -- the LSP would have
# been the one surface still accepting the unstable import (#2277 review).
rm -f "$uwdir/buffer.json"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DIAGNOSTICS=1 VIBE_DIAGNOSTICS_JSON=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/buffer.vibe" "$uwdir/buffer.json" __no_entry__ >/dev/null 2>&1 || true
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/buffer.json" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the single-file JSON lane dropped the unstable diagnostic (#2277)" >&2
  cat "$uwdir/buffer.json" >&2 2>/dev/null || true
  exit 1
fi
# The JSON form must carry the COLUMN, not just the message. `lsp_parse_diag_line`
# accepts exactly `line L:C:`; a readable `line L:col C:` made it fall back to
# column 1, so the editor put the cursor at character 0 while the text form
# named the real column (#2277 review). The import is indented so the two
# answers can differ at all.
printf '  import @vibe/concurrent/experimental { TaskGroup }\n\nfn main() -> Int {\n  1\n}\n' > "$uwdir/indented.vibe"
rm -f "$uwdir/indented.out" "$uwdir/indented.json"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DIAGNOSTICS=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/indented.vibe" "$uwdir/indented.out" __no_entry__ >/dev/null 2>&1 || true
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DIAGNOSTICS=1 VIBE_DIAGNOSTICS_JSON=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/indented.vibe" "$uwdir/indented.json" __no_entry__ >/dev/null 2>&1 || true
# Two lanes, one column: byte column 3 in the text form is UTF-16 character 2 in
# the JSON form. Before the fix the JSON said 0 for this file while the text
# form said 3, because `line L:col C:` is not a spelling `lsp_parse_diag_line`
# can read -- it parsed "col 3" as a number, failed, and fell back to column 1.
if ! grep -qF 'line 1:3: set VIBE_UNSTABLE=1' "$uwdir/indented.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the text diagnostic lost the column of an indented unstable import (#2277)" >&2
  cat "$uwdir/indented.out" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -qF '"character":2' "$uwdir/indented.json" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the JSON diagnostic lost the column the text form reported (#2277)" >&2
  cat "$uwdir/indented.json" >&2 2>/dev/null || true
  exit 1
fi

# `vibe serve` is an ARTIFACT-producing verb with its own branch, taken before
# the FS-compile gate, so the same handler that `vibe check` rejects used to
# yield a deployable component with no opt-in (#2277 review). The handler shape
# is the four-parameter String one `validate_serve_handler` requires; the
# control below proves the file is otherwise servable.
cat > "$uwdir/serve.vibe" <<'UWEOF'
import @vibe/concurrent/experimental { TaskGroup }

export fn handler(method: String, url: String, headers: String, body: String) -> String {
  "ok"
}
UWEOF
rm -f "$uwdir/serve.component.wasm" "$uwdir/serve.component.wasm.diag"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SERVE_COMPONENT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/serve.vibe" "$uwdir/serve.component.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$uwdir/serve.component.wasm" ]; then
  echo "[compiler-gate] FAIL: vibe serve emitted a component for an unstable import with no opt-in (#2277)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/serve.component.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe serve refused the handler for the wrong reason (#2277)" >&2
  cat "$uwdir/serve.component.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -f "$uwdir/serve.optin.wasm" "$uwdir/serve.optin.wasm.diag"
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SERVE_COMPONENT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/serve.vibe" "$uwdir/serve.optin.wasm" __no_entry__ >/dev/null 2>&1 || true
if grep -qF 'VIBE_UNSTABLE=1' "$uwdir/serve.optin.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not clear the serve gate (#2277)" >&2
  cat "$uwdir/serve.optin.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# `export @pkg { .. }` would depend on the package exactly as an import does and
# then PUBLISH its surface onward. Measured: it does not parse, so nothing
# crosses the boundary through it -- but that is a fact about the PARSER, not
# about this gate, and it is the kind of fact that changes without anyone
# revisiting the gate (#2277 review).
cat > "$uwdir/reexport.vibe" <<'UWEOF'
export @vibe/concurrent/experimental { TaskGroup }

fn main() -> Int {
  1
}
UWEOF
uw_build "$uwdir/reexport.vibe" "$uwdir/reexport.wasm"
if [ -s "$uwdir/reexport.wasm" ]; then
  echo "[compiler-gate] FAIL: a re-export of the unstable package built with no opt-in (#2277)" >&2
  exit 1
fi
# TWO acceptable refusals, and the check has to distinguish them or it passes
# for a reason it never verified. Today the form does not parse at all -- the
# parser builds `SReExport` for `TDot`/`TDotDot` paths only and answers a
# package path with "unexpected token in export" -- so the gate is not what
# stops it. If that syntax ever lands, this arm stops matching and the
# diagnostic must be the opt-in one instead; anything else fails here.
if grep -qF 'unexpected token in export' "$uwdir/reexport.wasm.diag" 2>/dev/null; then
  :
elif grep -qF 'VIBE_UNSTABLE=1' "$uwdir/reexport.wasm.diag" 2>/dev/null; then
  :
else
  echo "[compiler-gate] FAIL: a package re-export was refused for an unrelated reason -- if it now parses, gate it (#2277)" >&2
  cat "$uwdir/reexport.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# The SINGLE-SOURCE lane is artifact-producing too. `VIBE_TEST_BACKEND=gc` and
# `VIBE_BENCH_BACKEND=gc` reach it because `runtime/vibe` clears
# `VIBE_FS_COMPILE` and selects the backend, so the file compiled and RAN with
# no opt-in while every check form rejected the same declaration. Measured
# before the fix: `vibe test` refused it, `VIBE_TEST_BACKEND=gc vibe test`
# answered `1 passed` (#2277 review). The import is unused on purpose -- that is
# the shape this lane accepts.
cat > "$uwdir/bare.vibe" <<'UWEOF'
import @vibe/concurrent/experimental { TaskGroup }

test "unused unstable import" {
  assert_true(1 + 1 == 2)
}
UWEOF
rm -f "$uwdir/bare.wasm" "$uwdir/bare.wasm.diag"
env -u VIBE_UNSTABLE -u VIBE_FS_COMPILE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_TEST=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/bare.vibe" "$uwdir/bare.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$uwdir/bare.wasm" ]; then
  echo "[compiler-gate] FAIL: the single-source lane built an unstable import with no opt-in (#2277)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/bare.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the single-source lane refused the file for the wrong reason (#2277)" >&2
  cat "$uwdir/bare.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -f "$uwdir/bare.optin.wasm" "$uwdir/bare.optin.wasm.diag"
env -u VIBE_FS_COMPILE VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_TEST=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/bare.vibe" "$uwdir/bare.optin.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$uwdir/bare.optin.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not clear the single-source gate (#2277)" >&2
  cat "$uwdir/bare.optin.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# ...and an ordinary file on that lane is untouched, so the gate is not simply
# refusing everything.
printf 'test "plain" {\n  assert_true(1 + 1 == 2)\n}\n' > "$uwdir/bare_plain.vibe"
rm -f "$uwdir/bare_plain.wasm" "$uwdir/bare_plain.wasm.diag"
env -u VIBE_UNSTABLE -u VIBE_FS_COMPILE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_TEST=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/bare_plain.vibe" "$uwdir/bare_plain.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$uwdir/bare_plain.wasm" ]; then
  echo "[compiler-gate] FAIL: the single-source gate refused an ordinary file (#2277)" >&2
  cat "$uwdir/bare_plain.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# TWO imports of the same package must be located independently. The offset scan
# restarted from token zero for each `SImport`, so both diagnostics carried the
# FIRST declaration's coordinates -- and the second one then names a line whose
# text the reader would find nothing wrong with (#2277 review).
cat > "$uwdir/twice.vibe" <<'UWEOF'
import @vibe/concurrent/experimental { TaskGroup }

import @vibe/concurrent/experimental { Nursery }

fn main() -> Int {
  1
}
UWEOF
rm -f "$uwdir/twice.out"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DIAGNOSTICS=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/twice.vibe" "$uwdir/twice.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -qF 'line 1:1: set VIBE_UNSTABLE=1' "$uwdir/twice.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the first of two unstable imports was not reported at line 1 (#2277)" >&2
  cat "$uwdir/twice.out" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -qF 'line 3:1: set VIBE_UNSTABLE=1' "$uwdir/twice.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the SECOND unstable import was reported at the first one's line (#2277)" >&2
  cat "$uwdir/twice.out" >&2 2>/dev/null || true
  exit 1
fi
# The import may sit in a SIBLING, and that is the normal shape of a project --
# `main.vibe` calling `./worker.vibe` with the concurrency in the worker. The
# entry-only scan missed exactly that: measured before the fix, this two-file
# program BUILT an artifact and checked clean with no opt-in (#2284).
#
# The diagnostic must name the file that actually spells the import, not the
# entry -- otherwise the reader is sent to a file with nothing wrong in it.
mkdir -p "$uwdir/sib"
cat > "$uwdir/sib/worker.vibe" <<'UWEOF'
import @vibe/concurrent/experimental {
  TaskGroup
}

export fn run_all() -> Int with Exception {
  TaskGroup::run((n) -> {
    0
  })
}
UWEOF
cat > "$uwdir/sib/main.vibe" <<'UWEOF'
import ./worker.vibe {
  run_all
}

fn main() -> Int allows Exception {
  run_all()
}
UWEOF
uw_build "$uwdir/sib/main.vibe" "$uwdir/sib/main.wasm"
if [ -s "$uwdir/sib/main.wasm" ]; then
  echo "[compiler-gate] FAIL: a sibling file carried the unstable import past the gate (#2284)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/sib/main.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the sibling import was refused for the wrong reason (#2284)" >&2
  cat "$uwdir/sib/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -qF 'worker.vibe' "$uwdir/sib/main.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the diagnostic named the entry, not the file that spells the import (#2284)" >&2
  cat "$uwdir/sib/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
uw_build "$uwdir/sib/main.vibe" "$uwdir/sib/optin.wasm" VIBE_UNSTABLE=1
if [ ! -s "$uwdir/sib/optin.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not let the sibling case build (#2284)" >&2
  cat "$uwdir/sib/optin.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# `vibe check` must agree -- the whole point is that the two verbs answer alike.
uw_sib_out="$(uw_check "$uwdir/sib/main.vibe" || true)"
if ! printf '%s\n' "$uw_sib_out" | grep -qF 'VIBE_UNSTABLE=1'; then
  echo "[compiler-gate] FAIL: vibe check accepted a sibling-carried unstable import (#2284)" >&2
  printf '%s\n' "$uw_sib_out" >&2
  exit 1
fi
# ...and an ordinary two-file program is untouched, or the closure scan is
# simply refusing everything with a dependency.
mkdir -p "$uwdir/plain2"
printf 'export fn helper() -> Int {\n  7\n}\n' > "$uwdir/plain2/dep.vibe"
printf 'import ./dep.vibe {\n  helper\n}\n\nfn main() -> Int {\n  helper()\n}\n' > "$uwdir/plain2/main.vibe"
uw_build "$uwdir/plain2/main.vibe" "$uwdir/plain2/main.wasm"
if [ ! -s "$uwdir/plain2/main.wasm" ]; then
  echo "[compiler-gate] FAIL: the closure scan refused an ordinary two-file program (#2284)" >&2
  cat "$uwdir/plain2/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

# `vibe serve` needs its own copy of the closure gate: it returns before the
# FS-compile branch that carries the other one, so a handler whose DEPENDENCY
# imports the package emitted a deployable component with no opt-in (#2302
# review).
#
# Placement is asserted too, not just rejection. The gate runs before the
# component is emitted, because an unstable dependency drags in `vibe.sleep`
# and the handler-purity check would otherwise speak first -- telling the
# reader their handler is impure rather than that the dependency needs an
# opt-in. A gate must win over the diagnostics that are downstream of it.
mkdir -p "$uwdir/srv"
cat > "$uwdir/srv/dep.vibe" <<'UWEOF'
import @vibe/concurrent/experimental {
  TaskGroup
}

export fn helper() -> Int with Exception {
  TaskGroup::run((n) -> {
    0
  })
}
UWEOF
cat > "$uwdir/srv/h.vibe" <<'UWEOF'
import ./dep.vibe {
  helper
}

export fn handler(method: String, url: String, headers: String, body: String) -> String {
  "ok"
}
UWEOF
rm -f "$uwdir/srv/c.wasm" "$uwdir/srv/c.wasm.diag"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SERVE_COMPONENT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/srv/h.vibe" "$uwdir/srv/c.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ -s "$uwdir/srv/c.wasm" ]; then
  echo "[compiler-gate] FAIL: vibe serve emitted a component whose dependency imports the unstable package (#2284)" >&2
  exit 1
fi
if ! grep -qF 'VIBE_UNSTABLE=1' "$uwdir/srv/c.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe serve refused the handler for the wrong reason -- the gate must outrank the purity check (#2302)" >&2
  cat "$uwdir/srv/c.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
if ! grep -qF 'dep.vibe' "$uwdir/srv/c.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the serve diagnostic named the handler, not the file that spells the import (#2284)" >&2
  cat "$uwdir/srv/c.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# With the opt-in the gate stands down -- whatever happens next is not its say.
rm -f "$uwdir/srv/optin.wasm" "$uwdir/srv/optin.wasm.diag"
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SERVE_COMPONENT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/srv/h.vibe" "$uwdir/srv/optin.wasm" __no_entry__ >/dev/null 2>&1 || true
if grep -qF 'VIBE_UNSTABLE=1' "$uwdir/srv/optin.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not clear the serve closure gate (#2302)" >&2
  cat "$uwdir/srv/optin.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
# ...and an ordinary handler is untouched.
printf 'export fn handler(method: String, url: String, headers: String, body: String) -> String {\n  "ok"\n}\n' > "$uwdir/srv/plain.vibe"
rm -f "$uwdir/srv/plain.wasm" "$uwdir/srv/plain.wasm.diag"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_SERVE_COMPONENT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uwdir/srv/plain.vibe" "$uwdir/srv/plain.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$uwdir/srv/plain.wasm" ]; then
  echo "[compiler-gate] FAIL: the serve closure gate refused an ordinary handler (#2302)" >&2
  cat "$uwdir/srv/plain.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi

rm -rf "$uwdir"
echo "[compiler-gate] ADR-0068 opt-in gate: check + build + serve + single-source + closure + repeated-import + package-re-export + buffer(text+json+column) + whitespace + comment + multiline + pinned-require ok (#2248, #2277)"
fmtdir="_build/_gate_vibe_fmt"
rm -rf "$fmtdir"; mkdir -p "$fmtdir"
printf 'let   add=(a:Int,b:Int)->Int{a+b}\n' > "$fmtdir/messy.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fmtdir/messy.vibe" "$fmtdir/out.vibe" >"$fmtdir/run.log" 2>&1 || true
if [ ! -s "$fmtdir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: VIBE_FMT produced no output -- vibe fmt is not wired into the compiler (#2149)" >&2
  cat "$fmtdir/run.log" >&2 || true
  exit 1
fi
cat > "$fmtdir/expected.vibe" <<'FMTEXP'
let add = (a: Int, b: Int) -> Int {
  a + b
}
FMTEXP
if ! cmp -s "$fmtdir/expected.vibe" "$fmtdir/out.vibe"; then
  echo "[compiler-gate] FAIL: VIBE_FMT did not produce the canonical layout (#2149)" >&2
  diff -u "$fmtdir/expected.vibe" "$fmtdir/out.vibe" >&2 || true
  exit 1
fi
rm -rf "$fmtdir"
echo "[compiler-gate] vibe fmt ok (#2149)"

# 109/109. A multiline closure literal in a NON-FINAL argument slot formats to
# a fixpoint (#2271). Reported as permanently unformattable -- apply changed
# nothing, --check kept reporting a diff. The construct was never the problem:
# the formatter ENTRY had failed to compile (a fresh checkout has none of the
# untracked generated artifacts), and `vibe fmt` spelled "I could not build
# myself" with the same exit 1 it uses for "this file is not formatted", so a
# caller looped forever. Fixed in scripts/ensure_entry_wasm.sh (the failure is
# loud) and scripts/vibe_fmt.sh (it exits 2), pinned there by
# scripts/ensure_entry_wasm_test.sh. This section pins the other half of the
# report -- that the SHAPE formats, on the stage2 lane -- so the issue's claim
# is a regression test in both directions.
echo "[compiler-gate] 109/109 a multiline closure in a non-final argument slot formats to a fixpoint (#2271)"
nfdir="_build/_gate_nonfinal_closure"
rm -rf "$nfdir"; mkdir -p "$nfdir"
cat > "$nfdir/in.vibe" <<'NFIN'
fn collect_by(is_formal: (String) -> Bool, out: Array[String]) -> Unit {
  ()
}
fn caller(shadow: Array[String], out: Array[String]) -> Unit {
  collect_by((head) -> {
      let mut found = false
      if Array::length(shadow) > 0 {
    found = true
      } else {
        ()
      }
      found
  }, out)
}
NFIN
cat > "$nfdir/expected.vibe" <<'NFEXP'
fn collect_by(is_formal: (String) -> Bool, out: Array[String]) -> Unit {
  ()
}
fn caller(shadow: Array[String], out: Array[String]) -> Unit {
  collect_by((head) -> {
    let mut found = false
    if Array::length(shadow) > 0 {
      found = true
    } else {
      ()
    }
    found
  }, out)
}
NFEXP
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nfdir/in.vibe" "$nfdir/out.vibe" >"$nfdir/run.log" 2>&1 || true
if [ ! -s "$nfdir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: the formatter produced nothing for a non-final closure argument (#2271)" >&2
  cat "$nfdir/run.log" >&2 || true
  exit 1
fi
if ! cmp -s "$nfdir/expected.vibe" "$nfdir/out.vibe"; then
  echo "[compiler-gate] FAIL: non-final closure argument not formatted as expected (#2271)" >&2
  diff -u "$nfdir/expected.vibe" "$nfdir/out.vibe" >&2 || true
  exit 1
fi
# The fixpoint is the half the issue said was unreachable: formatting the
# formatted form again must change nothing, or `pkf run fmt` and CI's
# vibe-fmt-check disagree about the file forever.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FMT=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nfdir/expected.vibe" "$nfdir/again.vibe" >"$nfdir/again.log" 2>&1 || true
if ! cmp -s "$nfdir/expected.vibe" "$nfdir/again.vibe"; then
  echo "[compiler-gate] FAIL: the formatted non-final closure is not a fixpoint (#2271)" >&2
  diff -u "$nfdir/expected.vibe" "$nfdir/again.vibe" >&2 || true
  exit 1
fi
rm -rf "$nfdir"
echo "[compiler-gate] non-final closure argument fixpoint ok (#2271)"


# 110/110. A user's own `assert_eq` is the function that runs (#2283).
# Measured on a stage2 predating this guard: `fn assert_eq(a: Int, b: Int) ->
# Int { a + b }` plus `assert_eq(1, 2)` compiled clean and TRAPPED with
# `assert_eq failed` instead of returning 3, with no diagnostic naming the
# conflict. Two layers had to give -- the lowering, which claimed every arity-2
# `assert_eq` by name, and codegen, which had no shadowing guard at all on
# these three spellings (#1095 removed `prefer_bound_call`, and the half of it
# that was wrong is `local_idx_hint`, not `fn_idx_in_list`).
echo "[compiler-gate] 110/110 a user's own assert_eq is the function that runs, top-level or local, on BOTH lanes (#2283, #2285, #2300)"
asdir="_build/_gate_assert_shadow"
rm -rf "$asdir"; mkdir -p "$asdir"
cat > "$asdir/shadow.vibe" <<'ASEOF'
fn assert_eq(a: Int, b: Int) -> String {
  Int::to_string(a + b)
}

fn main() -> Unit allows Console {
  println(assert_eq(1, 2))
}
ASEOF
rm -f "$asdir/shadow.wasm" "$asdir/shadow.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asdir/shadow.vibe" "$asdir/shadow.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asdir/shadow.wasm" ]; then
  echo "[compiler-gate] FAIL: a program defining its own assert_eq did not compile (#2283)" >&2
  cat "$asdir/shadow.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
as_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$asdir/shadow.wasm" 2>&1 || true)"
if ! printf '%s\n' "$as_out" | grep -qx '3'; then
  echo "[compiler-gate] FAIL: the user's own assert_eq was not the function that ran (#2283)" >&2
  printf '%s\n' "$as_out" >&2
  exit 1
fi
# The FS lane too. `assert_true` is the oracle so the check does not depend on
# captured stdout: if the builtin claimed the call, `assert_eq(1, 2)` traps
# before `assert_true` ever sees a value.
cat > "$asdir/shadow_test.vibe" <<'ASEOF'
fn assert_eq(a: Int, b: Int) -> Int {
  a + b
}

test "own assert_eq" {
  assert_true(assert_eq(1, 2) == 3)
}
ASEOF
VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
  bash scripts/vibe_test.sh "$asdir/shadow_test.vibe" >"$asdir/shadow.log" 2>&1 || true
if grep -qF 'assert_eq failed' "$asdir/shadow.log"; then
  echo "[compiler-gate] FAIL: the FS lane replaced the user's assert_eq with the builtin assertion (#2283)" >&2
  cat "$asdir/shadow.log" >&2
  exit 1
fi
if ! grep -qF '1 passed, 0 failed' "$asdir/shadow.log"; then
  echo "[compiler-gate] FAIL: the user's own assert_eq did not run in the FS lane (#2283)" >&2
  cat "$asdir/shadow.log" >&2
  exit 1
fi
# ...and the BUILTIN still works where nothing shadows it, or the guard has
# simply turned the feature off.
cat > "$asdir/builtin_test.vibe" <<'ASEOF'
test "builtin assert still fires" {
  assert_eq(1, 2)
}
ASEOF
VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
  bash scripts/vibe_test.sh "$asdir/builtin_test.vibe" >"$asdir/builtin.log" 2>&1 || true
if ! grep -qF 'assert_eq failed' "$asdir/builtin.log"; then
  echo "[compiler-gate] FAIL: the builtin assert_eq stopped reporting failures (#2283)" >&2
  cat "$asdir/builtin.log" >&2
  exit 1
fi
# ...and a LOCAL binding wins too (#2285). Three binder shapes, all measured
# broken on a stage2 from `b1d42642`: the pattern-bound one reported `assert_eq
# failed / expected: 2 / actual: 1`, and the `let` and parameter shapes did not
# even compile ("expected Int, got ()") because the lowering had already
# rewritten the call before the checker could read the binding.
#
# Two layers again, and they only work together: the desugar scan stands down
# for a local binder, and codegen's three assert arms read the whole of
# `prefer_bound_call`. Standing down ALONE is measurably worse -- it trades the
# builtin's message for a bare `unreachable` -- which is why the local case
# stayed broken until both landed.
cat > "$asdir/local.vibe" <<'ASEOF'
fn make_cmp() -> (Int, Int) -> Int {
  (a, b) -> { a + b }
}

fn use_param(assert_eq: (Int, Int) -> Int) -> Int {
  assert_eq(1, 2)
}

fn main() -> Unit allows Console {
  match make_cmp() {
    assert_eq => println(Int::to_string(assert_eq(1, 2)))
  }
  let assert_eq = (a: Int, b: Int) -> Int { a + b }
  println(Int::to_string(assert_eq(1, 2)))
  println(Int::to_string(use_param(make_cmp())))
  let assert_true = (a: Int) -> Int { a + 41 }
  println(Int::to_string(assert_true(1)))
}
ASEOF
rm -f "$asdir/local.wasm" "$asdir/local.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asdir/local.vibe" "$asdir/local.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asdir/local.wasm" ]; then
  echo "[compiler-gate] FAIL: a program binding assert_eq locally did not compile (#2285)" >&2
  cat "$asdir/local.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
local_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$asdir/local.wasm" 2>&1 || true)"
if [ "$(printf '%s\n' "$local_out" | grep -c '^3$')" != "3" ] || \
   ! printf '%s\n' "$local_out" | grep -qx '42'; then
  echo "[compiler-gate] FAIL: a local binding of assert_eq/assert_true was claimed by the builtin (#2285)" >&2
  echo "  want three lines of '3' (pattern, let, parameter) and one '42' (assert_true), got:" >&2
  printf '%s\n' "$local_out" >&2
  exit 1
fi
# The same shape through the FS/test lane, which is where #2285 was reported.
cat > "$asdir/local_test.vibe" <<'ASEOF'
fn make_cmp() -> (Int, Int) -> Int {
  (a, b) -> { a + b }
}

test "pattern-bound assert_eq" {
  match make_cmp() {
    assert_eq => assert_true(assert_eq(1, 2) == 3)
  }
}
ASEOF
VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
  bash scripts/vibe_test.sh "$asdir/local_test.vibe" >"$asdir/local.log" 2>&1 || true
if ! grep -qF '1 passed, 0 failed' "$asdir/local.log"; then
  echo "[compiler-gate] FAIL: a pattern-bound assert_eq did not run in the FS lane (#2285)" >&2
  cat "$asdir/local.log" >&2
  exit 1
fi
# Reading `local_idx_hint` is only sound while the capture scan skips these
# names. Drop them from is_inlined_scalar_builtin and a lambda calling a bare
# assert captures a slot holding nothing, so the call lowers to a
# `call_indirect` of a nonexistent closure -- #1095, exactly. That regression is
# silent in every other case, so it gets its own probe.
cat > "$asdir/lambda.vibe" <<'ASEOF'
fn main() -> Unit allows Console {
  let f = () -> Unit { assert_eq(1, 1) }
  f()
  let g = () -> Unit { assert_true(1 == 1) }
  g()
  let h = () -> Unit { assert(true) }
  h()
  println("ok")
}
ASEOF
rm -f "$asdir/lambda.wasm" "$asdir/lambda.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$asdir/lambda.vibe" "$asdir/lambda.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$asdir/lambda.wasm" ]; then
  echo "[compiler-gate] FAIL: a lambda calling a bare assert did not compile (#1095 guard, #2285)" >&2
  cat "$asdir/lambda.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
lambda_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$asdir/lambda.wasm" 2>&1 || true)"
if ! printf '%s\n' "$lambda_out" | grep -qx 'ok'; then
  echo "[compiler-gate] FAIL: a bare assert inside a lambda no longer runs -- #1095 is back (#2285)" >&2
  printf '%s\n' "$lambda_out" >&2
  exit 1
fi
# #2300: everything above is the LINEAR lane. The wasm-gc lane compiled the
# same three spellings unconditionally, so a user's own `assert_eq` trapped
# `unreachable` there while linear ran it -- one language, two answers, no
# diagnostic on either.
#
# Both directions are probed, because the naive port of linear's guard breaks
# the SECOND one: `assert*` are in the gc func table (in_gc_table = true,
# in_linear_table = false), so `fn_idx_in_list < 0` fires for every call and
# the arm stops emitting its result at all (`expected 1 elements on the stack
# for fallthru, found 3`). A green shadow probe with a broken builtin probe is
# exactly the state this pair exists to reject.
cat > "$asdir/gc_shadow_test.vibe" <<'ASEOF'
fn assert_eq(a: Int, b: Int) -> Int {
  a + b
}

test "own assert_eq" {
  assert_true(assert_eq(1, 2) == 3)
}
ASEOF
VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1   bash scripts/vibe_test.sh "$asdir/gc_shadow_test.vibe" >"$asdir/gc_shadow.log" 2>&1 || true
if ! grep -qF '1 passed, 0 failed' "$asdir/gc_shadow.log"; then
  echo "[compiler-gate] FAIL: the wasm-gc lane still hijacks a user's own assert_eq (#2300)" >&2
  cat "$asdir/gc_shadow.log" >&2
  exit 1
fi
# ...and the builtin still fires on gc where nothing shadows it, both ways.
cat > "$asdir/gc_builtin_test.vibe" <<'ASEOF'
test "builtin assert_eq passes" {
  assert_eq(1 + 1, 2)
}
ASEOF
VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1   bash scripts/vibe_test.sh "$asdir/gc_builtin_test.vibe" >"$asdir/gc_builtin.log" 2>&1 || true
if ! grep -qF '1 passed, 0 failed' "$asdir/gc_builtin.log"; then
  echo "[compiler-gate] FAIL: the gc builtin assert_eq stopped working -- the shadow guard fires for every call (#2300)" >&2
  cat "$asdir/gc_builtin.log" >&2
  exit 1
fi
cat > "$asdir/gc_builtin_fail_test.vibe" <<'ASEOF'
test "builtin assert_eq fails" {
  assert_eq(1, 2)
}
ASEOF
VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1   bash scripts/vibe_test.sh "$asdir/gc_builtin_fail_test.vibe" >"$asdir/gc_builtin_fail.log" 2>&1 || true
if grep -qF '1 passed, 0 failed' "$asdir/gc_builtin_fail.log"; then
  echo "[compiler-gate] FAIL: the gc builtin assert_eq no longer rejects 1 vs 2 (#2300)" >&2
  cat "$asdir/gc_builtin_fail.log" >&2
  exit 1
fi
# A LOCAL binding, not just a top-level one. The gc guard's first test is
# `find_local_slot`, and that half has its own failure mode -- a lambda bound to
# the name is what the Codex review on #2311 flagged, with the builtin returning
# `0` where the reader's function returns 42. Red-tested: both of these fail on
# a stage2 carrying #2309 but not #2300.
cat > "$asdir/gc_local_test.vibe" <<'ASEOF'
test "local assert_true shadow" {
  let assert_true = (a: Int) -> Int { a + 41 }
  assert(assert_true(1) == 42)
}
ASEOF
VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
  bash scripts/vibe_test.sh "$asdir/gc_local_test.vibe" >"$asdir/gc_local.log" 2>&1 || true
if ! grep -qF '1 passed, 0 failed' "$asdir/gc_local.log"; then
  echo "[compiler-gate] FAIL: a LOCAL assert_true binding is still hijacked on the gc lane (#2300)" >&2
  cat "$asdir/gc_local.log" >&2
  exit 1
fi
cat > "$asdir/gc_local_eq_test.vibe" <<'ASEOF'
fn make_cmp() -> (Int, Int) -> Int {
  (a, b) -> { a + b }
}

test "local assert_eq shadow" {
  let assert_eq = make_cmp()
  assert(assert_eq(1, 2) == 3)
}
ASEOF
VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
  bash scripts/vibe_test.sh "$asdir/gc_local_eq_test.vibe" >"$asdir/gc_local_eq.log" 2>&1 || true
if ! grep -qF '1 passed, 0 failed' "$asdir/gc_local_eq.log"; then
  echo "[compiler-gate] FAIL: a LOCAL assert_eq binding is still hijacked on the gc lane (#2300)" >&2
  cat "$asdir/gc_local_eq.log" >&2
  exit 1
fi
# The gc guard reads the closure's local names, so it inherits the same #1095
# hazard the linear one does: a bare assert inside a lambda must not be seen as
# a binding. Probe it on this lane too rather than assuming linear's answer
# transfers -- the two lanes keep these names in different tables, which is the
# whole reason this issue existed.
cat > "$asdir/gc_lambda_test.vibe" <<'ASEOF'
test "bare asserts inside lambdas" {
  let f = () -> Unit { assert_eq(1, 1) }
  f()
  let g = () -> Unit { assert_true(1 == 1) }
  g()
  let h = () -> Unit { assert(true) }
  h()
}
ASEOF
VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1   bash scripts/vibe_test.sh "$asdir/gc_lambda_test.vibe" >"$asdir/gc_lambda.log" 2>&1 || true
if ! grep -qF '1 passed, 0 failed' "$asdir/gc_lambda.log"; then
  echo "[compiler-gate] FAIL: a bare assert inside a lambda broke on the gc lane (#1095 shape, #2300)" >&2
  cat "$asdir/gc_lambda.log" >&2
  exit 1
fi
rm -rf "$asdir"
echo "[compiler-gate] user-defined assert_eq wins (top-level and local, linear and gc); builtin still fires; no #1095 capture regression ok (#2283, #2285, #2300)"

# 111/111. A binding named `eq` is the function that runs (#2309).
# Measured on a stage2 from f9115cdf: `let eq = (a: Int, b: Int) -> Int { a + b
# }` then `eq(1, 2)` printed `0`. The checker had already typed the call against
# the user's `eq` and agreed the result was an `Int`; codegen emitted `i64.eq`
# anyway. No diagnostic and no trap -- a wrong VALUE, which is the worst way to
# break by this repo's own triage order.
#
# `eq`'s inline arm carries a `cc_arg_is_scalarish` disjunct that deliberately
# lets the builtin beat `prefer_bound_call` (#710/#711: that flag is a
# whole-program name match, not a file-scoped one, and dropping the disjunct
# regressed leb128_test.vibe). The fix splits the flag's two readings rather
# than removing the disjunct: `fn_idx_in_list` stays exactly as it was, and
# only `local_idx_hint` -- a lexical binding in this very closure -- wins.
echo "[compiler-gate] 111/111 a binding named eq is the function that runs (#2309)"
eqdir="_build/_gate_eq_shadow"
rm -rf "$eqdir"; mkdir -p "$eqdir"
cat > "$eqdir/eq.vibe" <<'EQEOF'
fn main() -> Unit allows Console {
  let eq = (a: Int, b: Int) -> Int { a + b }
  println(Int::to_string(eq(1, 2)))
  let feq = (a: Double, b: Double) -> Double { a + b }
  println(Double::to_string(feq(1.5, 2.5)))
}
EQEOF
# The float arm is the sharper of the two: it had no shadowing guard at all, and
# it only misfires under RC -- the production default -- so a non-RC probe would
# pass while every shipped build was wrong.
cat > "$eqdir/eqf.vibe" <<'EQEOF'
fn main() -> Unit allows Console {
  let eq = (a: Double, b: Double) -> Double { a + b }
  println(Double::to_string(eq(1.5, 2.5)))
}
EQEOF
for probe in eq eqf; do
  rm -f "$eqdir/$probe.wasm" "$eqdir/$probe.wasm.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw     bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"     "$eqdir/$probe.vibe" "$eqdir/$probe.wasm" main >/dev/null 2>&1 || true
  if [ ! -s "$eqdir/$probe.wasm" ]; then
    echo "[compiler-gate] FAIL: the $probe shadow probe did not compile (#2309)" >&2
    cat "$eqdir/$probe.wasm.diag" >&2 2>/dev/null || true
    exit 1
  fi
done
eq_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$eqdir/eq.wasm" 2>&1 || true)"
if ! printf '%s
' "$eq_out" | grep -qx '3'; then
  echo "[compiler-gate] FAIL: a binding named eq is still replaced by the builtin -- want 3 (#2309)" >&2
  printf '%s
' "$eq_out" >&2
  exit 1
fi
eqf_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$eqdir/eqf.wasm" 2>&1 || true)"
if ! printf '%s
' "$eqf_out" | grep -qx '4'; then
  echo "[compiler-gate] FAIL: a binding named eq on Double is still replaced by the builtin -- want 4 (#2309)" >&2
  printf '%s
' "$eqf_out" >&2
  exit 1
fi
# The builtin must still answer where nothing shadows it -- and it must still
# take the INLINE path for the #705 reason the disjunct exists: a bound `eq`'s
# string fallback reads OOB on Int values that resemble fat pointers.
cat > "$eqdir/builtin.vibe" <<'EQEOF'
fn main() -> Unit allows Console {
  println(if eq(1, 2) { "y" } else { "n" })
  println(if eq(7, 7) { "y" } else { "n" })
  println(if eq(0.5, 0.5) { "y" } else { "n" })
  println(if eq(0.5, 0.25) { "y" } else { "n" })
}
EQEOF
rm -f "$eqdir/builtin.wasm" "$eqdir/builtin.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw   bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"   "$eqdir/builtin.vibe" "$eqdir/builtin.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$eqdir/builtin.wasm" ]; then
  echo "[compiler-gate] FAIL: the unshadowed eq probe did not compile (#2309)" >&2
  cat "$eqdir/builtin.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
builtin_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$eqdir/builtin.wasm" 2>&1 || true)"
if [ "$(printf '%s
' "$builtin_out" | tr -d '[:space:]')" != "nyyn" ]; then
  echo "[compiler-gate] FAIL: the builtin eq stopped answering where nothing shadows it -- want n y y n (#2309)" >&2
  printf '%s
' "$builtin_out" >&2
  exit 1
fi
# A TOP-LEVEL definition, not just a lexical binding (Codex review on #2312).
# `local_idx_hint` is -1 for this shape and `fn_idx_in_list` cannot decide it
# either -- `eq` is in the linear func table unconditionally, so that index is
# >= 0 for every call whether or not anyone defined one. Measured before the
# fix: `0`.
cat > "$eqdir/toplevel.vibe" <<'EQEOF'
fn eq(a: Int, b: Int) -> Int {
  a + b
}

fn main() -> Unit allows Console {
  println(Int::to_string(eq(1, 2)))
}
EQEOF
rm -f "$eqdir/toplevel.wasm" "$eqdir/toplevel.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eqdir/toplevel.vibe" "$eqdir/toplevel.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$eqdir/toplevel.wasm" ]; then
  echo "[compiler-gate] FAIL: the top-level eq probe did not compile (#2309)" >&2
  cat "$eqdir/toplevel.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
top_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$eqdir/toplevel.wasm" 2>&1 || true)"
if ! printf '%s\n' "$top_out" | grep -qx '3'; then
  echo "[compiler-gate] FAIL: a top-level fn eq is still replaced by the builtin -- want 3 (#2309)" >&2
  printf '%s\n' "$top_out" >&2
  exit 1
fi
# The guard asks whether THIS program defines the name, and a merged program
# can contain someone else's top-level `eq` -- @vibe/semver exports one. If the
# guard were a whole-program name match it would stand the builtin down for
# every `eq` call in any program that imports semver, which is #711's mistake
# in a new place. Merged top-level names are module-qualified, so it must not.
cat > "$eqdir/withsemver.vibe" <<'EQEOF'
import @vibe/semver { parse }

fn main() -> Unit allows Console {
  let _ = parse("1.0.0")
  println(if eq(7, 7) { "y" } else { "n" })
  println(if eq(1, 2) { "y" } else { "n" })
}
EQEOF
rm -f "$eqdir/withsemver.wasm" "$eqdir/withsemver.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_FS_COMPILE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eqdir/withsemver.vibe" "$eqdir/withsemver.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$eqdir/withsemver.wasm" ]; then
  echo "[compiler-gate] FAIL: the semver+eq probe did not compile (#2309)" >&2
  cat "$eqdir/withsemver.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
sem_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$eqdir/withsemver.wasm" 2>&1 || true)"
if [ "$(printf '%s\n' "$sem_out" | tr -d '[:space:]')" != "yn" ]; then
  echo "[compiler-gate] FAIL: another module's top-level eq stood the builtin down -- want y n (#2309, #711)" >&2
  printf '%s\n' "$sem_out" >&2
  exit 1
fi
# The gc lane, both shapes plus the builtin. Its `eq` and `not` arms were
# unconditional, so a bound name of either kind lost to the builtin there while
# linear honored it.
cat > "$eqdir/gc_eq_local_test.vibe" <<'EQEOF'
test "local eq shadow" {
  let eq = (a: Int, b: Int) -> Int { a + b }
  assert(eq(1, 2) == 3)
}
EQEOF
cat > "$eqdir/gc_eq_top_test.vibe" <<'EQEOF'
fn eq(a: Int, b: Int) -> Int {
  a + b
}

test "top-level eq shadow" {
  assert(eq(1, 2) == 3)
}
EQEOF
cat > "$eqdir/gc_not_test.vibe" <<'EQEOF'
test "local not shadow" {
  let not = (a: Int) -> Int { a + 41 }
  assert(not(1) == 42)
}
EQEOF
cat > "$eqdir/gc_builtin_eq_test.vibe" <<'EQEOF'
test "builtin eq still answers" {
  assert(eq(7, 7))
  assert(not(eq(1, 2)))
}
EQEOF
for probe in gc_eq_local gc_eq_top gc_not gc_builtin_eq; do
  VIBE_TEST_BACKEND=gc VIBE_TEST_CLI_WASM="$stage2_wasm" VIBE_TEST_QUIET_COMPILER_NOTE=1 \
    bash scripts/vibe_test.sh "$eqdir/${probe}_test.vibe" >"$eqdir/$probe.log" 2>&1 || true
  if ! grep -qF '1 passed, 0 failed' "$eqdir/$probe.log"; then
    echo "[compiler-gate] FAIL: gc probe $probe did not pass (#2309)" >&2
    cat "$eqdir/$probe.log" >&2
    exit 1
  fi
done
rm -rf "$eqdir"
echo "[compiler-gate] a binding named eq wins on Int and Double, local and top-level, linear and gc; another module's eq does not; the builtin still answers unshadowed ok (#2309)"

# 112/112. `vibe check` answers about a `.vpkg` contract (#2280).
# A contract is the package boundary and the public API surface (ADR-0070),
# and it was the one file `vibe check` could not answer for: it read the raw
# bytes as statement grammar and reported `expected { but got fn` on
# lib/@vibe/random/index.vpkg -- a committed contract the build consumes on
# every run. That message is not merely unhelpful, it asserts something untrue
# about the file, which is the failure mode this repo ranks first.
echo "[compiler-gate] 112/112 vibe check answers about a .vpkg contract (#2280)"
vpdir="_build/_gate_vpkg_check"
rm -rf "$vpdir"; mkdir -p "$vpdir"
# A real tree package, not a synthetic one: the point is that `check` agrees
# with the loader about files the build already consumes.
for contract in lib/@vibe/random/index.vpkg; do
  rm -f "$vpdir/out" "$vpdir/out.diag"
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw     bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm"     "$contract" "$vpdir/out" main >"$vpdir/stdout" 2>&1; then
    echo "[compiler-gate] FAIL: vibe check rejected the working contract $contract (#2280)" >&2
    cat "$vpdir/out.diag" >&2 2>/dev/null || true
    cat "$vpdir/stdout" >&2
    exit 1
  fi
  if grep -q 'expected { but got' "$vpdir/out.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe check still reads $contract as statement grammar (#2280)" >&2
    cat "$vpdir/out.diag" >&2
    exit 1
  fi
done
# It must still be able to REJECT, and reject for the RIGHT reason. Exit-nonzero
# alone is not evidence here: the pre-fix compiler ALSO exits nonzero on every
# contract, with the parse error this section exists to remove -- so a bare
# "it failed" assertion passes on the broken build and proves nothing. Assert
# the diagnostic names the unimplemented declaration and is NOT the parse error.
#
# A synthetic package rather than a copy of a real one: copying drags in that
# package's header (generated_hash, deps) and its tests, so a failure would not
# distinguish "the contract violation was caught" from "the copy was malformed".
mkdir -p "$vpdir/pkg"
cat > "$vpdir/pkg/index.vpkg" <<'VPEOF'
name = @gate/vpkgcheck
version = 0.0.1
description =
  #|gate-only package for #2280
deps = {}

generated_hash =

fn implemented(x: Int) -> Int
VPEOF
cat > "$vpdir/pkg/impl.vibe" <<'VPEOF'
export fn implemented(x: Int) -> Int {
  x + 1
}
VPEOF
# Green first: the synthetic package must check clean, or the red case below
# would be measuring a broken fixture instead of the contract rule.
rm -f "$vpdir/ok.out" "$vpdir/ok.out.diag"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$vpdir/pkg/index.vpkg" "$vpdir/ok.out" main >"$vpdir/ok.stdout" 2>&1; then
  echo "[compiler-gate] FAIL: vibe check rejected a well-formed synthetic contract (#2280)" >&2
  cat "$vpdir/ok.out.diag" >&2 2>/dev/null || true
  cat "$vpdir/ok.stdout" >&2
  exit 1
fi
# Now declare a name no sibling implements.
printf 'fn no_such_implementation_exists(x: Int) -> Int\n' >> "$vpdir/pkg/index.vpkg"
rm -f "$vpdir/bad.out" "$vpdir/bad.out.diag"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$vpdir/pkg/index.vpkg" "$vpdir/bad.out" main >"$vpdir/bad.stdout" 2>&1; then
  echo "[compiler-gate] FAIL: vibe check accepted a contract declaring an unimplemented name (#2280)" >&2
  exit 1
fi
bad_report="$(cat "$vpdir/bad.out.diag" "$vpdir/bad.stdout" 2>/dev/null || true)"
if ! printf '%s\n' "$bad_report" | grep -qF 'no_such_implementation_exists'; then
  echo "[compiler-gate] FAIL: the rejection does not name the unimplemented declaration -- it may be failing for the pre-#2280 parse reason instead" >&2
  printf '%s\n' "$bad_report" >&2
  exit 1
fi
if printf '%s\n' "$bad_report" | grep -qF 'expected { but got'; then
  echo "[compiler-gate] FAIL: the rejection IS the pre-#2280 parse error, not a contract violation" >&2
  printf '%s\n' "$bad_report" >&2
  exit 1
fi
rm -rf "$vpdir"
echo "[compiler-gate] vibe check reads a contract as a contract, and still rejects a real violation ok (#2280)"

# 113/113. An inherited unstable import is reported as inherited, and the
# physical one keeps its own line (#2289).
# Ingestion PREPENDS a directory's shared `index.vpkg` imports, so a sibling
# that also spells its own import has two `SImport`s for one package: synthetic
# first, physical second. The offset scan only sees the physical file, so
# walking in statement order let the synthetic one consume the physical one's
# offset -- the reader was told to delete their own `import` line, and deleting
# it revealed a second error for the contract import nobody had mentioned.
#
# The second half is the reason only one of them was ever visible: the adapter
# emitted `Array::get(warns, 0)` and dropped the rest.
echo "[compiler-gate] 113/113 an inherited unstable import is named as inherited, and every import is reported (#2289)"
ihdir="_build/_gate_inherited_unstable"
rm -rf "$ihdir"; mkdir -p "$ihdir/pkg"
# `env -u VIBE_UNSTABLE` on EVERY probe here, for the reason section 108 states
# at its own call sites: this lane exports VIBE_UNSTABLE=1 lane-wide (line 20),
# and under that grant the gate stands down and reports nothing. Measured -- the
# first version of this section passed by hand and reported 0 in CI, which is a
# gate that cannot fail rather than a gate that passes (#2252).
cat > "$ihdir/pkg/index.vpkg" <<'IHEOF'
name = @gate/inheritedunstable
version = 0.0.1
description =
  #|gate-only package for #2289
deps = {}

generated_hash =

import @vibe/concurrent/experimental { TaskGroup }

fn work() -> Int
IHEOF
cat > "$ihdir/pkg/impl.vibe" <<'IHEOF'
import @vibe/concurrent/experimental { TaskGroup }

export fn work() -> Int {
  7
}
IHEOF
rm -f "$ihdir/out" "$ihdir/out.diag"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ihdir/pkg/impl.vibe" "$ihdir/out" main >"$ihdir/out.stdout" 2>&1 || true
ih_report="$(cat "$ihdir/out.diag" 2>/dev/null || true)"
# EXACTLY two reports: the inherited one and the physical one, one line each.
#
# Both bounds matter. Fewer than two is the adapter dropping all but the first,
# which is what made the misassignment invisible. MORE than two is the dedupe
# failing: the loader ingests a module several times per compile and records a
# candidate each time, so printing every report without dedupe made one file's
# single import read as three.
ih_n="$(printf '%s\n' "$ih_report" | grep -c 'VIBE_UNSTABLE=1' || true)"
if [ "$ih_n" != "2" ]; then
  echo "[compiler-gate] FAIL: reported $ih_n unstable imports, want exactly 2 (inherited + physical) (#2289)" >&2
  printf '%s\n' "$ih_report" >&2
  echo "--- compile output ---" >&2
  cat "$ihdir/out.stdout" >&2 || true
  exit 1
fi
# Exactly one of the two calls itself inherited. The NOTE is the discriminator,
# not the position: an absent offset falls back to line 1 by design ("a miss
# costs a position, never a verdict"), so both lines read `line 1:1` here and
# testing the position would be testing nothing.
ih_inherited="$(printf '%s\n' "$ih_report" | grep -c 'inherits' || true)"
if [ "$ih_inherited" != "1" ]; then
  echo "[compiler-gate] FAIL: $ih_inherited of the reports call the import inherited, want exactly 1 (#2289)" >&2
  printf '%s\n' "$ih_report" >&2
  exit 1
fi
# ...and the other one names the physical import's own line rather than
# inheriting the fallback -- this is the half that regresses if the synthetic
# occurrence goes back to consuming the cursor.
if ! printf '%s\n' "$ih_report" | grep -v 'inherits' | grep -qF 'line 1:1'; then
  echo "[compiler-gate] FAIL: the physical import lost its own position (#2289)" >&2
  printf '%s\n' "$ih_report" >&2
  exit 1
fi
# The flood the Codex review on #2312 named: ingestion prepends the shared
# import to EVERY sibling, so a package with N members reported one `import`
# line N times. Measured on this 3-member package before the per-directory
# dedupe: ten reports. An inherited import is one edit -- the directory's
# index.vpkg -- so it must be reported once no matter how many members inherit
# it, while the contract's own physical import keeps its own line.
mkdir -p "$ihdir/flood"
cat > "$ihdir/flood/index.vpkg" <<'IHEOF'
name = @gate/inheritedflood
version = 0.0.1
description =
  #|gate-only package for #2289
deps = {}

generated_hash =

import @vibe/concurrent/experimental { TaskGroup }

fn a() -> Int
fn b() -> Int
fn c() -> Int
IHEOF
for member in a b c; do
  printf 'export fn %s() -> Int {\n  1\n}\n' "$member" > "$ihdir/flood/$member.vibe"
done
rm -f "$ihdir/flood.out" "$ihdir/flood.out.diag"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ihdir/flood/index.vpkg" "$ihdir/flood.out" main >/dev/null 2>&1 || true
flood_report="$(cat "$ihdir/flood.out.diag" 2>/dev/null || true)"
flood_inherited="$(printf '%s\n' "$flood_report" | grep -c 'inherits' || true)"
if [ "$flood_inherited" != "1" ]; then
  echo "[compiler-gate] FAIL: $flood_inherited inherited reports for one shared import across 3 members, want 1 (#2289)" >&2
  printf '%s\n' "$flood_report" >&2
  exit 1
fi
flood_own="$(printf '%s\n' "$flood_report" | grep 'VIBE_UNSTABLE=1' | grep -vc 'inherits' || true)"
if [ "$flood_own" != "1" ]; then
  echo "[compiler-gate] FAIL: $flood_own reports for the contract's own import line, want 1 (#2289)" >&2
  printf '%s\n' "$flood_report" >&2
  exit 1
fi
# The contract's own import is at line 9 of that .vpkg -- the edit point.
if ! printf '%s\n' "$flood_report" | grep -v 'inherits' | grep -qF 'index.vpkg: line 9:'; then
  echo "[compiler-gate] FAIL: the contract's own import is not reported at its own line (#2289)" >&2
  printf '%s\n' "$flood_report" >&2
  exit 1
fi

# A file that ONLY inherits keeps the behaviour it already had.
cat > "$ihdir/pkg/impl.vibe" <<'IHEOF'
export fn work() -> Int {
  7
}
IHEOF
rm -f "$ihdir/only.out" "$ihdir/only.out.diag"
env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ihdir/pkg/impl.vibe" "$ihdir/only.out" main >/dev/null 2>&1 || true
if ! grep -qF 'inherits' "$ihdir/only.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a file that only inherits the import no longer says so (#2289)" >&2
  cat "$ihdir/only.out.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$ihdir"
echo "[compiler-gate] inherited and physical unstable imports are each reported, each in its own words ok (#2289)"

# 115/115. `vibe lsp` publishDiagnostics carries the ADR-0068 opt-in (#2297).
# Section 108 covers the boundary on `vibe check --single-file`, in both its
# text and its `--json` form -- but the JSON form only reports it because the
# ADAPTER splices the verdict in, so 108 says nothing about the live server.
# Measured before this landed: publishDiagnostics on a buffer whose only
# content is `import @vibe/concurrent/experimental` delivered the unused-import warning and
# no opt-in error at all, while the two check forms reported both.
#
# Both directions, because a fix that always appends the diagnostic would pass
# the first assertion and break the opt-in.
echo "[compiler-gate] 115/115 vibe lsp publishDiagnostics reports the ADR-0068 opt-in (#2297)"
lspudir="_build/_gate_lsp_unstable"
rm -rf "$lspudir"; mkdir -p "$lspudir"
python3 - "$lspudir/input.bin" <<'PYEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

src = 'import @vibe/concurrent/experimental { TaskGroup }\n\nexport let main = () -> Int { 0 }\n'
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate_unstable.vibe", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
PYEOF
# `env -u VIBE_UNSTABLE` for the same reason section 108 and 113 do it: this
# lane grants the opt-in lane-wide (run.sh:20), and under that grant the gate
# stands down and this section would assert nothing.
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$lspudir/input.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$lspudir/plain.bin" 2>"$lspudir/plain.err" || true
if ! grep -q 'publishDiagnostics' "$lspudir/plain.bin" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe lsp published no diagnostics at all (#2297)" >&2
  head -c 400 "$lspudir/plain.bin" >&2 || true
  cat "$lspudir/plain.err" >&2 || true
  exit 1
fi
if ! grep -q 'VIBE_UNSTABLE=1' "$lspudir/plain.bin" 2>/dev/null; then
  echo "[compiler-gate] FAIL: publishDiagnostics omits the ADR-0068 opt-in that every check form reports (#2297)" >&2
  grep -o '"method":"textDocument/publishDiagnostics".\{0,300\}' "$lspudir/plain.bin" >&2 || true
  exit 1
fi
# ...and the opt-in suppresses it, while diagnostics keep flowing.
VIBE_UNSTABLE=1 VIBE_STDIN_BYTES="$(cat "$lspudir/input.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$lspudir/optin.bin" 2>/dev/null || true
if ! grep -q 'publishDiagnostics' "$lspudir/optin.bin" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe lsp stopped publishing diagnostics under VIBE_UNSTABLE=1 (#2297)" >&2
  exit 1
fi
if grep -q 'VIBE_UNSTABLE=1' "$lspudir/optin.bin" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not suppress the opt-in diagnostic in the LSP (#2297)" >&2
  exit 1
fi
# ...and the scan must never COST diagnostics. `collect_all_diagnostics` uses
# the recovering lexer and reports a lex error; the unstable scan uses
# `lex_with_offsets`, which THROWS on one. The first version let that throw
# escape, and `lsp_diagnostics_safe_with_unstable` turns a throw into `[]` --
# so a buffer with any syntax error published as CLEAN. That is strictly worse
# than the missing warning this section exists for, and it is invisible unless
# something asserts on a file that does not lex.
python3 - "$lspudir/lex.bin" <<'PYEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

# A lexer error and no unstable import at all: the scan still runs (no grant),
# so this is the shape that regressed.
src = 'let x = `\nexport let main = () -> Int { 0 }\n'
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate_lex.vibe", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
PYEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$lspudir/lex.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$lspudir/lex.out" 2>/dev/null || true
if grep -q '"diagnostics":\[\]' "$lspudir/lex.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a buffer with a lexer error published NO diagnostics -- the unstable scan swallowed them (#2297)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$lspudir/lex.out" >&2 || true
  exit 1
fi
if ! grep -q '"severity":1' "$lspudir/lex.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the lexer error is not published as an error severity (#2297)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$lspudir/lex.out" >&2 || true
  exit 1
fi
# ...and the scan must read the buffer with the grammar the buffer HAS. The
# first version passed `("", source, source)` -- no path, raw text -- which was
# documented as safe because "a buffer is never a `.vpkg` facade". Both halves
# were wrong, and each silently drops the diagnostic this section is about:
#
#   - an editor DOES open `index.vpkg`. With an empty path the scan parses the
#     contract with the statement grammar, the header fails, the scan returns
#     `None`, and no opt-in error is reported for a contract that imports
#     `@vibe/concurrent/experimental`;
#   - a buffer may open with a `require ... = #pkg:sha1:` head. The base lane
#     blanks that before parsing (#2227); the scan reparsed the RAW source,
#     where the directive is a parse error -- `None` again.
#
# Both probes were measured against a stage2 built before the fix: each
# published its OTHER diagnostic and no opt-in error, so this pair fails on the
# pre-fix compiler rather than merely passing on the fixed one.
for probe in vpkg pin; do
  python3 - "$lspudir/$probe.bin" "$probe" <<'LSPGRAMMAREOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

VPKG = (
    "name = @gate/lspvpkg\n"
    "version = 0.0.1\n"
    "description =\n"
    "  #|gate-only package for #2297\n"
    "deps = {}\n"
    "\n"
    "generated_hash =\n"
    "\n"
    "import @vibe/concurrent/experimental { TaskGroup }\n"
    "\n"
    "fn implemented(x: Int) -> Int\n"
)
PIN = (
    "require @gate/dep 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n"
    "\n"
    "import @vibe/concurrent/experimental { TaskGroup }\n"
    "\n"
    "export let main = () -> Int { 0 }\n"
)
kind = sys.argv[2]
src, uri = (VPKG, "file:///gate/index.vpkg") if kind == "vpkg" else (PIN, "file:///gate/pin.vibe")
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri, "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
LSPGRAMMAREOF
  env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$lspudir/$probe.bin")" \
    VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    > "$lspudir/$probe.out" 2>/dev/null || true
  if ! grep -q 'publishDiagnostics' "$lspudir/$probe.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: vibe lsp published nothing for the $probe buffer (#2297)" >&2
    exit 1
  fi
  if ! grep -q 'VIBE_UNSTABLE=1' "$lspudir/$probe.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $probe buffer's unstable import got no opt-in diagnostic -- the scan read it with the wrong grammar (#2297)" >&2
    grep -o '"diagnostics":\[[^]]*\]' "$lspudir/$probe.out" >&2 || true
    exit 1
  fi
done
# NOT asserted here: the `.vpkg` buffer ALSO publishes `expected { but got eof`,
# because the base `collect_all_diagnostics` still reads a contract as
# statements. That is the LSP half of #2280 -- it predates #2297 (measured on a
# stage2 built from the commit before it) and is tracked as #2314. Asserting a
# clean answer here would fail for a reason this section does not own.
rm -rf "$lspudir"
echo "[compiler-gate] vibe lsp reports the ADR-0068 opt-in, the opt-in suppresses it, a lex error still reports, and .vpkg/pin-head buffers are read with their own grammar ok (#2297)"

# 116/116. A diagnostic on a trait method names the TRAIT, not the synthesized
#          witness struct (#2286).
# `vibe check` and `vibe test` always reported `the signature of `Store::lookup``;
# the full COMPILE lane reported ``field `lookup` of struct `StoreDict``, a
# declaration the author never wrote. Not a duplicate to drop -- measured, the
# compile lane emits exactly one diagnostic and that was it, so suppressing it
# would have lost a real type error.
#
# The second case is the one that killed the previous attempt (#2276): a
# program may legitimately declare its own `StoreDict`, and relabelling on the
# `+ "Dict"` name convention reports a real user struct as a trait signature.
echo "[compiler-gate] 116/116 a trait-method diagnostic names the trait, not the synthesized dict struct (#2286)"
tdlabdir="_build/_gate_trait_dict_label"
rm -rf "$tdlabdir"; mkdir -p "$tdlabdir"
cat > "$tdlabdir/trait.vibe" <<'TDEOF'
trait Store {
  lookup(Self, Map[Int, String]) -> String
}

fn main() -> Int {
  0
}
TDEOF
rm -f "$tdlabdir/t.wasm" "$tdlabdir/t.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdlabdir/trait.vibe" "$tdlabdir/t.wasm" main >/dev/null 2>&1 || true
td_report="$(cat "$tdlabdir/t.wasm.diag" 2>/dev/null || true)"
if [ -z "$td_report" ]; then
  echo "[compiler-gate] FAIL: the bad Map key in a trait method produced no diagnostic at all (#2286)" >&2
  exit 1
fi
if printf '%s\n' "$td_report" | grep -qF 'StoreDict'; then
  echo "[compiler-gate] FAIL: the compile lane still names the synthesized StoreDict (#2286)" >&2
  printf '%s\n' "$td_report" >&2
  exit 1
fi
if ! printf '%s\n' "$td_report" | grep -qF 'Store::lookup'; then
  echo "[compiler-gate] FAIL: the diagnostic does not name the trait method the author wrote (#2286)" >&2
  printf '%s\n' "$td_report" >&2
  exit 1
fi
# The red case: a HAND-WRITTEN struct with the conventional name must still be
# described as what it is. This is what a name-convention fix gets wrong.
cat > "$tdlabdir/handwritten.vibe" <<'TDEOF'
struct StoreDict { lookup: Map[Int, String] }

fn main() -> Int {
  0
}
TDEOF
rm -f "$tdlabdir/h.wasm" "$tdlabdir/h.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdlabdir/handwritten.vibe" "$tdlabdir/h.wasm" main >/dev/null 2>&1 || true
hw_report="$(cat "$tdlabdir/h.wasm.diag" 2>/dev/null || true)"
if ! printf '%s\n' "$hw_report" | grep -qF 'of struct `StoreDict`'; then
  echo "[compiler-gate] FAIL: a hand-written StoreDict lost its field label -- the fix is reading the name convention, not the desugar's record (#2286)" >&2
  printf '%s\n' "$hw_report" >&2
  exit 1
fi
# ...and `vibe check` keeps the answer it always had, so the two verbs agree.
rm -f "$tdlabdir/chk.out" "$tdlabdir/chk.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdlabdir/trait.vibe" "$tdlabdir/chk.out" main >/dev/null 2>&1 || true
if ! grep -qF 'Store::lookup' "$tdlabdir/chk.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe check no longer names the trait method (#2286)" >&2
  cat "$tdlabdir/chk.out.diag" >&2 2>/dev/null || true
  exit 1
fi
# ...and an INHERITED method names the trait that declares it. `flatten_traits`
# copies a supertrait's signatures into the child, so `ChildDict` carries fields
# `Child` never declared. Keying the provenance record by struct alone reported
# ``the signature of `Child::lookup` `` -- a declaration that exists nowhere in
# the source (Codex review on #2313).
#
# The child is declared FIRST on purpose. With `Base` first the walk stops on
# `BaseDict` and the label is right by accident, which is exactly how the bug
# stayed invisible; measured both orders on the pre-fix compiler, and only this
# one exposes it.
cat > "$tdlabdir/inherit.vibe" <<'TDEOF'
trait Child: Base {
  own(Self, Int) -> Int
}

trait Base {
  lookup(Self, Map[Double, String]) -> String
}

fn main() -> Int {
  0
}
TDEOF
rm -f "$tdlabdir/i.wasm" "$tdlabdir/i.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdlabdir/inherit.vibe" "$tdlabdir/i.wasm" main >/dev/null 2>&1 || true
inh_report="$(cat "$tdlabdir/i.wasm.diag" 2>/dev/null || true)"
if [ -z "$inh_report" ]; then
  echo "[compiler-gate] FAIL: the bad Map key in an inherited trait method produced no diagnostic at all (#2286)" >&2
  exit 1
fi
if printf '%s\n' "$inh_report" | grep -qF 'Child::lookup'; then
  echo "[compiler-gate] FAIL: an inherited method is labelled with the CHILD trait, which does not declare it (#2286)" >&2
  printf '%s\n' "$inh_report" >&2
  exit 1
fi
if ! printf '%s\n' "$inh_report" | grep -qF 'Base::lookup'; then
  echo "[compiler-gate] FAIL: the inherited method is not attributed to the trait that declares it (#2286)" >&2
  printf '%s\n' "$inh_report" >&2
  exit 1
fi
# The child's OWN method must still be attributed to the child, or the fix
# could pass the assertion above by always naming a supertrait.
cat > "$tdlabdir/ownmethod.vibe" <<'TDEOF'
trait Child: Base {
  own(Self, Map[Double, String]) -> String
}

trait Base {
  lookup(Self, Int) -> Int
}

fn main() -> Int {
  0
}
TDEOF
rm -f "$tdlabdir/o.wasm" "$tdlabdir/o.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdlabdir/ownmethod.vibe" "$tdlabdir/o.wasm" main >/dev/null 2>&1 || true
own_report="$(cat "$tdlabdir/o.wasm.diag" 2>/dev/null || true)"
if ! printf '%s\n' "$own_report" | grep -qF 'Child::own'; then
  echo "[compiler-gate] FAIL: a trait's OWN method is no longer attributed to it (#2286)" >&2
  printf '%s\n' "$own_report" >&2
  exit 1
fi
rm -rf "$tdlabdir"
echo "[compiler-gate] trait-method diagnostics name the DECLARING trait, inherited or own; a hand-written dict struct keeps its own label ok (#2286)"

# 117/117. A `.vpkg` buffer is read with the contract grammar on the
# single-buffer lanes too (#2314, the LSP half of #2280).
#
# #2280 taught `vibe check` (no `--single-file`) to read a contract as a
# contract. The single-buffer lanes never got it: `collect_all_diagnostics`
# took no path, so `vibe lsp` and the `vibe diagnostics` buffer lane answered
# `expected { but got fn` about a valid contract -- a diagnostic that asserts
# something untrue about a file the build consumes on every run.
echo "[compiler-gate] 117/117 a .vpkg buffer is read as a contract on the single-buffer lanes (#2314)"
vpbufdir="_build/_gate_vpkg_buffer"
rm -rf "$vpbufdir"; mkdir -p "$vpbufdir"
# A real tree contract, so a failure cannot be blamed on a synthetic fixture.
# `lib/@vibe/random/index.vpkg` is the file #2280 named.
real_contract="lib/@vibe/random/index.vpkg"
if [ ! -f "$ROOT_DIR/$real_contract" ]; then
  echo "[compiler-gate] FAIL: $real_contract is gone -- repoint this section (#2314)" >&2
  exit 1
fi
# The `vibe diagnostics` buffer lane writes its report to the OUTPUT file and
# exits 0 ("a report, not a failure"), so read that -- not just `.diag`/stdout,
# which are empty here and would make this assertion unable to fail.
rm -f "$vpbufdir/sf.out" "$vpbufdir/sf.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$real_contract" "$vpbufdir/sf.out" main >"$vpbufdir/sf.stdout" 2>&1 || true
sf_report="$(cat "$vpbufdir/sf.out" "$vpbufdir/sf.out.diag" "$vpbufdir/sf.stdout" 2>/dev/null || true)"
if printf '%s\n' "$sf_report" | grep -qF 'expected { but got'; then
  echo "[compiler-gate] FAIL: the vibe diagnostics buffer lane still reads $real_contract as statement grammar (#2314)" >&2
  printf '%s\n' "$sf_report" >&2
  exit 1
fi
# The live LSP is the surface the issue is filed against. Drive it over framed
# messages, the way section 115 does.
python3 - "$vpbufdir/lsp.bin" <<'VPBUFEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

src = (
    "name = @gate/vpkgbuffer\n"
    "version = 0.0.1\n"
    "description =\n"
    "  #|gate-only package for #2314\n"
    "deps = {}\n"
    "\n"
    "generated_hash =\n"
    "\n"
    "fn implemented(x: Int) -> Int\n"
)
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate/index.vpkg", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
VPBUFEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$vpbufdir/lsp.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$vpbufdir/lsp.out" 2>/dev/null || true
if ! grep -q 'publishDiagnostics' "$vpbufdir/lsp.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe lsp published nothing for a .vpkg buffer (#2314)" >&2
  exit 1
fi
if grep -q 'expected { but got' "$vpbufdir/lsp.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: vibe lsp still reads a .vpkg buffer as statement grammar (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/lsp.out" >&2 || true
  exit 1
fi
if ! grep -q '"diagnostics":\[\]' "$vpbufdir/lsp.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a well-formed .vpkg buffer is not clean on the LSP (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/lsp.out" >&2 || true
  exit 1
fi
# It must still be able to REJECT. Exit-clean alone would pass on a fix that
# simply suppressed every diagnostic for contracts -- which is the cheap wrong
# answer here, and indistinguishable from the right one without this half.
python3 - "$vpbufdir/bad.bin" <<'VPBUFEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

# Broken in the DECLARATION section, not the header: a bodyless `fn` with no
# return type. The header half is already covered by the pin-head scan.
src = (
    "name = @gate/vpkgbuffer\n"
    "version = 0.0.1\n"
    "description =\n"
    "  #|gate-only package for #2314\n"
    "deps = {}\n"
    "\n"
    "generated_hash =\n"
    "\n"
    "fn implemented(x: Int) ->\n"
)
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate/index.vpkg", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
VPBUFEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$vpbufdir/bad.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$vpbufdir/bad.out" 2>/dev/null || true
if grep -q '"diagnostics":\[\]' "$vpbufdir/bad.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a malformed .vpkg declaration published as CLEAN -- the contract branch reports nothing at all (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/bad.out" >&2 || true
  exit 1
fi
if ! grep -q '"severity":1' "$vpbufdir/bad.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the malformed .vpkg declaration is not published as an error (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/bad.out" >&2 || true
  exit 1
fi
# ...and it must POINT AT the declaration. `parse_contract_program` throws an
# unlocated message, and `locate_type_error`'s heuristics key on message
# prefixes the contract grammar never produces -- so without an anchor the
# editor gets the synthetic 0:0 range and the reader is told a contract is
# broken without being told where (#2314 review). The malformed `fn` is the
# LAST line of the probe, so a 0:0 answer and a correct one are far apart.
if grep -q '"start":{"line":0,"character":0}' "$vpbufdir/bad.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the malformed .vpkg declaration is published at the synthetic 0:0 range, not at the declaration (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/bad.out" >&2 || true
  exit 1
fi
if ! grep -q '"start":{"line":8' "$vpbufdir/bad.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the malformed .vpkg declaration is not anchored on its own line (expected line 8, 0-based) (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/bad.out" >&2 || true
  exit 1
fi
# ...and a contract whose EARLIER declaration is well-formed must not have the
# error anchored on it. This is the shape that broke the first anchor (Codex
# review on #2315): both the full token stream AND the prefix stopping right
# after line 1's `->` throw `expected type but got eof`, so a smallest-matching-
# prefix search walks BACKWARDS and publishes the error on line 1 -- pointing at
# correct code, which is the worst way to be wrong. The eof case is now anchored
# at the last real token instead of searched.
python3 - "$vpbufdir/eof.bin" <<'VPBUFEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

src = (
    "name = @gate/vpkgbuffer\n"
    "version = 0.0.1\n"
    "description =\n"
    "  #|gate-only package for #2314\n"
    "deps = {}\n"
    "\n"
    "generated_hash =\n"
    "\n"
    "fn a(x: Int) -> Int\n"
    "fn b(x: Int) ->\n"
)
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate/index.vpkg", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
VPBUFEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$vpbufdir/eof.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$vpbufdir/eof.out" 2>/dev/null || true
if ! grep -q '"severity":1' "$vpbufdir/eof.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the two-declaration malformed .vpkg published no error (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/eof.out" >&2 || true
  exit 1
fi
# Line 8 (0-based) is the WELL-FORMED `fn a`; line 9 is the malformed `fn b`.
if grep -q '"start":{"line":8' "$vpbufdir/eof.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the error is anchored on the WELL-FORMED declaration -- the eof anchor searched backwards (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/eof.out" >&2 || true
  exit 1
fi
if ! grep -q '"start":{"line":9' "$vpbufdir/eof.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the error is not anchored on the malformed declaration (expected line 9, 0-based) (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/eof.out" >&2 || true
  exit 1
fi
# ...and parsing is not the whole contract grammar. `parse_contract_program`
# ACCEPTS statements a contract may not contain; the loader rejects those
# separately with `classify_contract_stmts` (#729). Discarding the parsed
# statements reported this buffer as clean while the build refused it -- and
# the statement-grammar branch being replaced DID catch it, through
# `check_program` (Codex review on #2315).
python3 - "$vpbufdir/forbidden.bin" <<'VPBUFEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

src = (
    "name = @gate/vpkgbuffer\n"
    "version = 0.0.1\n"
    "description =\n"
    "  #|gate-only package for #2314\n"
    "deps = {}\n"
    "\n"
    "generated_hash =\n"
    "\n"
    "export let x: Int = \"s\"\n"
)
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate/index.vpkg", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
VPBUFEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$vpbufdir/forbidden.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$vpbufdir/forbidden.out" 2>/dev/null || true
if grep -q '"diagnostics":\[\]' "$vpbufdir/forbidden.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a contract containing a forbidden statement published as CLEAN -- the parsed statements are not classified (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/forbidden.out" >&2 || true
  exit 1
fi
if ! grep -q 'unsupported statement in a contract file' "$vpbufdir/forbidden.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the forbidden contract statement is not rejected for the loader's reason (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/forbidden.out" >&2 || true
  exit 1
fi
# NOT asserted: a position for this one. A classifier rejection is deliberately
# left unlocated -- the anchor probes the PARSER, and extending it to classify
# gives a non-monotone predicate that can anchor on later VALID code (the
# reasoning is in `contract_parse_error_offset`). Unlocated is what this lane
# already does with any diagnostic it cannot place. Tracked in #2317.
#
# The assertions above are what keeps this case honest without a position: a
# crash satisfies neither of them, which is how the earlier version of this
# section passed vacuously while the compiler was trapping.
# ...and reading a contract as a contract must not COST the ADR-0068 opt-in.
# This is the trap the rest of this section sets up: the `vibe diagnostics`
# buffer lane used to compute the unstable set with a SECOND scan over the RAW
# buffer, which could not parse a `.vpkg` header and so returned nothing. That
# was invisible while the base set was answering `expected { but got eof` about
# the same file -- removing the false error would have left a contract that
# imports `@vibe/concurrent/experimental` reporting NOTHING AT ALL, which is strictly worse
# than the wrong parse error this section removes (#2314 review). Measured on
# the pre-fix compiler: the LSP reported the opt-in for this contract and this
# lane did not.
cat > "$vpbufdir/unstable.vpkg" <<'VPBUFEOF'
name = @gate/unstablecontract
version = 0.0.1
description =
  #|gate-only package for #2314
deps = {}

generated_hash =

import @vibe/concurrent/experimental { TaskGroup }

fn implemented(x: Int) -> Int
VPBUFEOF
for form in text json; do
  rm -f "$vpbufdir/u.$form.out"
  if [ "$form" = json ]; then json_env=1; else json_env=0; fi
  env -u VIBE_UNSTABLE VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 \
    VIBE_DIAGNOSTICS_JSON="$json_env" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$vpbufdir/unstable.vpkg" "$vpbufdir/u.$form.out" main >/dev/null 2>&1 || true
  if ! grep -q 'VIBE_UNSTABLE=1' "$vpbufdir/u.$form.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $form diagnostics form dropped the ADR-0068 opt-in for a .vpkg buffer (#2314)" >&2
    cat "$vpbufdir/u.$form.out" >&2 || true
    exit 1
  fi
  if grep -q 'expected { but got' "$vpbufdir/u.$form.out" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the $form diagnostics form still reads a .vpkg as statement grammar (#2314)" >&2
    cat "$vpbufdir/u.$form.out" >&2 || true
    exit 1
  fi
done
# ...and the grant still suppresses it, or the assertion above would pass on a
# lane that appends the diagnostic unconditionally.
rm -f "$vpbufdir/u.granted.out"
VIBE_UNSTABLE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$vpbufdir/unstable.vpkg" "$vpbufdir/u.granted.out" main >/dev/null 2>&1 || true
if grep -q 'VIBE_UNSTABLE=1' "$vpbufdir/u.granted.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_UNSTABLE=1 did not suppress the opt-in on the .vpkg buffer lane (#2314)" >&2
  cat "$vpbufdir/u.granted.out" >&2 || true
  exit 1
fi
# ...and a contract lexes like a program: EVERY lex error, not just the first.
# The contract branch reaches for `parse_contract_program`, which throws, and
# the first version reached for the throwing lexer to match it. But a contract
# lexes with exactly the same rules as a program, and the `.vibe` lane reports
# both errors in `let p = ` + backtick twice -- so a contract reporting one was
# a gap, not a property of contract grammar (#2314 review).
python3 - "$vpbufdir/lex.bin" <<'VPBUFEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

src = (
    "name = @gate/vpkgbuffer\n"
    "version = 0.0.1\n"
    "description =\n"
    "  #|gate-only package for #2314\n"
    "deps = {}\n"
    "\n"
    "generated_hash =\n"
    "\n"
    "fn a(x: Int) -> `\n"
    "fn b(y: Int) -> `\n"
)
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate/index.vpkg", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
VPBUFEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$vpbufdir/lex.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$vpbufdir/lex.out" 2>/dev/null || true
lex_count="$(grep -o '"severity":1' "$vpbufdir/lex.out" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$lex_count" -lt 2 ]; then
  echo "[compiler-gate] FAIL: a .vpkg buffer with two lex errors published $lex_count -- the contract branch lexes without recovery (#2314)" >&2
  grep -o '"diagnostics":\[[^]]*\]' "$vpbufdir/lex.out" >&2 || true
  exit 1
fi
# ...and an ordinary `.vibe` buffer is untouched: it still type-checks, so a
# real type error must survive. Routing every buffer through the contract
# branch would pass everything above and silently stop checking programs.
python3 - "$vpbufdir/prog.bin" <<'VPBUFEOF'
import json, sys

def frame(obj):
    b = json.dumps(obj).encode("utf-8")
    return f"Content-Length: {len(b)}\r\n\r\n".encode("ascii") + b

src = 'fn main() -> Int {\n  let a: Int = "not an int"\n  0\n}\n'
msgs = [
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": "file:///gate/prog.vibe", "languageId": "vibe", "version": 1, "text": src}
    }}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]
with open(sys.argv[1], "wb") as f:
    f.write(b"".join(msgs))
VPBUFEOF
env -u VIBE_UNSTABLE VIBE_STDIN_BYTES="$(cat "$vpbufdir/prog.bin")" \
  VIBE_LSP=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  > "$vpbufdir/prog.out" 2>/dev/null || true
if grep -q '"diagnostics":\[\]' "$vpbufdir/prog.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: an ordinary .vibe buffer with a type error published as CLEAN -- the contract branch is catching everything (#2314)" >&2
  exit 1
fi
# ...and an unsupported `#` directive is reported, at its own `#` (#2316).
#
# That check lives in `parse_contract_program`, i.e. only on the contract
# branch this section added -- before it the buffer lane read the file as
# statements and answered CLEAN for a contract `vibe check` refuses. Measured
# on a stage2 built before that branch: buffer lane empty, import lane
# `unsupported # directive in a contract file: eof`. So this probe fails on the
# pre-fix compiler rather than merely passing on the fixed one.
#
# #2316 blamed the pin-blanking for erasing the directive line. It does not:
# `scan_package_header` blanks only the directives it recognizes, and a `#`
# line takes its final branch, which copies the line through verbatim. Both
# positions are covered below because the two reach the scanner differently --
# a `#` AFTER the header ends the scan there, one BEFORE it ends the scan
# immediately, so the header directives are copied through unblanked too.
#
# Each fixture is a real package DIRECTORY with a sibling implementation. A
# bare `.vpkg` is refused by the import lane whatever it contains ("contract
# declaration 'a' has no implementation"), which would make the oracle below
# pass without ever seeing the directive -- measured, a `#deprecated` fixture
# with no sibling was still "refused". The oracle asserts the MESSAGE, not the
# exit status, for the same reason.
for dirpos in after before; do
  rm -rf "$vpbufdir/$dirpos"; mkdir -p "$vpbufdir/$dirpos"
  rm -f "$vpbufdir/$dirpos.imp" "$vpbufdir/$dirpos.imp.diag" "$vpbufdir/$dirpos.buf"
  hdr='name = @gate/vpkgdir
version = 0.0.1
description =
  #|gate-only package for #2316
deps = {}

generated_hash =

'
  printf 'export fn a(x: Int) -> Int {\n  x + 1\n}\n' > "$vpbufdir/$dirpos/impl.vibe"
  if [ "$dirpos" = after ]; then
    printf '%s#eof\nfn a(x: Int) -> Int\n' "$hdr" > "$vpbufdir/$dirpos/index.vpkg"
    want_line='line 9:2:'
  else
    printf '#eof\n%sfn a(x: Int) -> Int\n' "$hdr" > "$vpbufdir/$dirpos/index.vpkg"
    want_line='line 1:2:'
  fi
  # The import lane is the oracle. Assert it reports THIS diagnostic before
  # asserting the buffer lane agrees -- a directive the loader started
  # accepting would otherwise leave this probe demanding an answer that is no
  # longer correct.
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$vpbufdir/$dirpos/index.vpkg" "$vpbufdir/$dirpos.imp" main >/dev/null 2>&1 || true
  if ! grep -qF 'unsupported # directive in a contract file: eof' "$vpbufdir/$dirpos.imp.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the import lane no longer reports a '#eof' directive ($dirpos the header) -- repoint this probe (#2316)" >&2
    cat "$vpbufdir/$dirpos.imp.diag" >&2 2>/dev/null || true
    exit 1
  fi
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$vpbufdir/$dirpos/index.vpkg" "$vpbufdir/$dirpos.buf" main >/dev/null 2>&1 || true
  if ! grep -qF 'unsupported # directive in a contract file: eof' "$vpbufdir/$dirpos.buf" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the buffer lane does not report a '#eof' directive ($dirpos the header) that the import lane refuses (#2316)" >&2
    cat "$vpbufdir/$dirpos.buf" >&2 2>/dev/null || true
    exit 1
  fi
  # Anchored on the directive's own '#', not left at 0:0 and not pushed to the
  # last real token by `contract_msg_mentions_eof` matching the word `eof` in
  # the MESSAGE -- which is the trap that predicate was narrowed to avoid.
  if ! grep -q "^$want_line" "$vpbufdir/$dirpos.buf" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the '#eof' directive ($dirpos the header) is not anchored on its own '#' (expected $want_line) (#2316)" >&2
    cat "$vpbufdir/$dirpos.buf" >&2 2>/dev/null || true
    exit 1
  fi
done
# `#deprecated` is the one directive a contract may carry, so it must stay
# clean on BOTH lanes -- otherwise the assertions above would pass on a fix
# that rejects every `#` line.
rm -rf "$vpbufdir/dep"; mkdir -p "$vpbufdir/dep"
rm -f "$vpbufdir/dep.imp" "$vpbufdir/dep.imp.diag" "$vpbufdir/dep.buf"
printf 'export fn a(x: Int) -> Int {\n  x + 1\n}\n' > "$vpbufdir/dep/impl.vibe"
printf 'name = @gate/vpkgdir\nversion = 0.0.1\ndescription =\n  #|gate-only package for #2316\ndeps = {}\n\ngenerated_hash =\n\n#deprecated\nfn a(x: Int) -> Int\n' > "$vpbufdir/dep/index.vpkg"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$vpbufdir/dep/index.vpkg" "$vpbufdir/dep.imp" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: the import lane refuses a '#deprecated' contract -- the control for the probes above is not valid (#2316)" >&2
  cat "$vpbufdir/dep.imp.diag" >&2 2>/dev/null || true
  exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_DIAGNOSTICS=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$vpbufdir/dep/index.vpkg" "$vpbufdir/dep.buf" main >/dev/null 2>&1 || true
if [ -s "$vpbufdir/dep.buf" ]; then
  echo "[compiler-gate] FAIL: '#deprecated' -- the one directive a contract may carry -- is reported as an error (#2316)" >&2
  cat "$vpbufdir/dep.buf" >&2
  exit 1
fi
rm -rf "$vpbufdir"
echo "[compiler-gate] a .vpkg buffer reads as a contract, still rejects a malformed declaration, reports an unsupported # directive at its own '#', and .vibe buffers still type-check ok (#2314, #2316)"

# 118/118. A call is checked the same above its callee's definition as below
# it (#2318).
#
# A forward reference skipped argument checking ENTIRELY -- types, arity, and
# the return type -- because the hoist pre-pass bound a top-level `fn`'s name
# with its ANNOTATION's type, and a `fn` carries its types on the EFn parameter
# list rather than on a binding annotation. It hoisted as `CtUnknown`, so the
# call checker's `_` arm returned `CtUnknown` and reported nothing.
#
# The property to pin is ORDER-INDEPENDENCE, not any single case: the verdict
# must not depend on where the definition sits. So every probe is run BOTH ways
# and the two verdicts compared, rather than asserting one message.
echo "[compiler-gate] 118/118 a call is checked the same above its callee's definition as below (#2318)"
fwddir="_build/_gate_fwd_check"
rm -rf "$fwddir"; mkdir -p "$fwddir"
# name|bad call|definition -- each is checked with the definition first and
# with the call first; the two must agree.
fwd_cases='argtype|takes(1, "s")|fn takes(a: Int, b: Int) -> Int { a + b }
arity|takes(1)|fn takes(a: Int, b: Int) -> Int { a + b }
unknownfn|nosuchfn(1)|fn takes(a: Int, b: Int) -> Int { a + b }'
printf '%s\n' "$fwd_cases" | while IFS='|' read -r nm call def; do
  [ -n "$nm" ] || continue
  printf 'fn caller() -> Int {\n  %s\n}\n\n%s\n\nfn main() -> Int {\n  caller()\n}\n' "$call" "$def" > "$fwddir/$nm.fwd.vibe"
  printf '%s\n\nfn caller() -> Int {\n  %s\n}\n\nfn main() -> Int {\n  caller()\n}\n' "$def" "$call" > "$fwddir/$nm.back.vibe"
  for ord in fwd back; do
    rm -f "$fwddir/$nm.$ord.out" "$fwddir/$nm.$ord.out.diag"
    if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fwddir/$nm.$ord.vibe" "$fwddir/$nm.$ord.out" main >/dev/null 2>&1; then
      echo "accepted" > "$fwddir/$nm.$ord.verdict"
    else
      echo "rejected" > "$fwddir/$nm.$ord.verdict"
    fi
  done
  fv="$(cat "$fwddir/$nm.fwd.verdict")"
  bv="$(cat "$fwddir/$nm.back.verdict")"
  if [ "$fv" != "$bv" ]; then
    echo "[compiler-gate] FAIL: case '$nm' depends on declaration order -- call-first says $fv, definition-first says $bv (#2318)" >&2
    cat "$fwddir/$nm.fwd.out.diag" >&2 2>/dev/null || true
    exit 1
  fi
  # ...and both must REJECT. Agreeing by accepting everything is the failure
  # this section exists to catch, and an order comparison alone cannot see it.
  if [ "$fv" != "rejected" ]; then
    echo "[compiler-gate] FAIL: case '$nm' is ACCEPTED in both orders -- the ill-typed call is not being checked at all (#2318)" >&2
    exit 1
  fi
done || exit 1
# A CORRECT forward call must still compile and run, or "reject everything"
# would pass every assertion above.
cat > "$fwddir/ok.vibe" <<'FWDEOF'
fn caller() -> Int {
  takes(1, 2)
}

fn takes(a: Int, b: Int) -> Int {
  a + b
}

fn main() -> Int {
  caller()
}
FWDEOF
rm -f "$fwddir/ok.wasm" "$fwddir/ok.wasm.diag"
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fwddir/ok.vibe" "$fwddir/ok.wasm" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: a CORRECT forward call no longer compiles (#2318)" >&2
  cat "$fwddir/ok.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fwddir/ok.wasm" 2>&1 | head -1)"
if [ "$ok_out" != "3" ]; then
  echo "[compiler-gate] FAIL: the correct forward call ran to '$ok_out', expected 3 (#2318)" >&2
  exit 1
fi
# An optional parameter may be omitted by a legitimate call, so the hoisted
# signature must stand down for it rather than report a false arity error.
cat > "$fwddir/opt.vibe" <<'FWDEOF'
fn caller() -> Int {
  takes(1)
}

fn takes(a: Int, b?: Int) -> Int {
  a
}

fn main() -> Int {
  caller()
}
FWDEOF
rm -f "$fwddir/opt.out" "$fwddir/opt.out.diag"
# `vibe check` exits 0 when clean, so the assertion is on the NEGATION -- the
# first draft had it inverted and failed on the fixed compiler, which is how
# the inversion was caught.
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fwddir/opt.vibe" "$fwddir/opt.out" main >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: omitting an OPTIONAL parameter in a forward call is reported as an error (#2318)" >&2
  cat "$fwddir/opt.out.diag" >&2 2>/dev/null || true
  exit 1
fi
rm -rf "$fwddir"
echo "[compiler-gate] a call is checked identically in both declaration orders; correct forward calls still run; optional params stand down ok (#2318)"
