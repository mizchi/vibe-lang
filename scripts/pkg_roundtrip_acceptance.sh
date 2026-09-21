#!/usr/bin/env bash
# pkg_roundtrip_acceptance.sh -- the package round-trip a RELEASE has to answer
# for: `vibe new` / `add` / `fetch` / `publish` / `install` against an isolated
# registry with pinned dependencies, a program that actually runs against the
# installed package, and the four ways tampering must be refused (#2834).
#
# This is acceptance EVIDENCE, not a gate, and it is deliberately not wired
# into one: it needs a built `viberun` and a stage2 for the candidate, which a
# gate cannot assume. `tests/gates/early/run.sh` already carries the durable
# subset (publish / install / --store / version->hash immutability) and runs on
# every PR. What is here and not there is the newcomer's path end to end.
#
# Everything is local: VIBE_HOME is a scratch directory and the "remote" is a
# file:// git repository, so no network and no shared state. The candidate
# compiler is passed explicitly and never defaulted -- a release measurement
# that silently answers from the committed seed is worse than no measurement
# (CLAUDE.md, "Which compiler answered?").
#
# Usage:
#   STAGE2=<path to the candidate stage2.wasm> bash scripts/pkg_roundtrip_acceptance.sh
#
# VIBE_RUNNER   overrides the runner (default: runtime/viberun/target/release/viberun)
# ROOT_DIR      overrides the checkout root (default: this script's parent)
set -uo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STAGE2="${STAGE2:-}"
if [ -z "$STAGE2" ] || [ ! -f "$STAGE2" ]; then
  echo "pkg-roundtrip: set STAGE2 to the candidate stage2.wasm (no default: the" >&2
  echo "  committed seed is not the compiler a release is being measured for)" >&2
  exit 2
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/vibe-pkg-rt.XXXXXX")"
export VIBE_HOME="$W/home"
mkdir -p "$VIBE_HOME"
VIBE="$ROOT_DIR/runtime/vibe"
export VIBE_CLI_WASM="$STAGE2"
export VIBE_PKG_CLI_WASM="$STAGE2"
# The checkout launcher looks for $TOOLCHAIN_DIR/bin/viberun; point it at the
# built runner rather than installing a toolchain.
export VIBE_RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$VIBE_RUNNER" ] || { echo "no runner at $VIBE_RUNNER" >&2; exit 2; }

fail=0
note() { printf '%s\n' "$*"; }
ok()   { note "  ok   $*"; }
bad()  { note "  FAIL $*"; fail=1; }
check(){ if [ "$2" = "$3" ]; then ok "$1: $2"; else bad "$1: got '$2' want '$3'"; fi; }

note "candidate stage2: $STAGE2"
note "sha256: $(sha256sum "$STAGE2" | cut -d' ' -f1)"
note "isolated VIBE_HOME: $VIBE_HOME"
note "runner/OS: $(uname -srm)"
note

note "=== 1. vibe new scaffolds a project ==="
( cd "$W" && bash "$VIBE" new --name @rt/app app ) > "$W/new.log" 2>&1
check "exit" "$?" "0"
check "main.vibex" "$([ -f "$W/app/main.vibex" ] && echo yes || echo no)" "yes"
check "index.vpkg" "$([ -f "$W/app/index.vpkg" ] && echo yes || echo no)" "yes"
grep -q '^name = @rt/app' "$W/app/index.vpkg" && ok "name directive" || bad "name directive"

note "=== 2. a dependency package, served from a local git remote ==="
mkdir -p "$W/dep"
cat > "$W/dep/index.vpkg" <<'PKG'
name = @rt/mathx
version = 1.0.0

fn triple(x: Int) -> Int
PKG
cat > "$W/dep/impl.vibe" <<'V'
export fn triple(x: Int) -> Int {
  x * 3
}
V
( cd "$W/dep" && git init -q . && git add -A && \
  git -c user.email=rt@example.invalid -c user.name=rt commit -qm init && \
  git tag v1.0.0 ) >> "$W/git.log" 2>&1
check "dep tagged" "$?" "0"

note "=== 3. vibe add pins it by content hash ==="
( cd "$W/app" && bash "$VIBE" add "git:file://$W/dep@v1.0.0" ) > "$W/add.log" 2>&1
check "exit" "$?" "0"
sed 's/^/      /' "$W/add.log"
pin="$(grep -o '#pkg:b3:[0-9a-f]\{64\}' "$W/app/index.vpkg" | head -1)"
[ -n "$pin" ] && ok "pin recorded: $pin" || bad "no pin written into index.vpkg"
check "store copy" "$([ -f "$W/app/.vibe/store/@rt/mathx/impl.vibe" ] && echo yes || echo no)" "yes"

note "=== 4. the project builds and runs against the INSTALLED package ==="
cat > "$W/app/main.vibex" <<'V'
import @rt/mathx { triple }

fn main allows Console {
  println(Int::to_string(triple(14)))
}
V
out="$( cd "$W/app" && bash "$VIBE" run main.vibex 2>&1 )"
rc=$?
check "exit" "$rc" "0"
check "output" "$(printf '%s' "$out" | tail -1)" "42"

note "=== 5. vibe fetch restores a deleted store from the pin alone ==="
rm -rf "$W/app/.vibe/store"
( cd "$W/app" && bash "$VIBE" fetch ) > "$W/fetch.log" 2>&1
check "exit" "$?" "0"
check "store restored" "$([ -f "$W/app/.vibe/store/@rt/mathx/impl.vibe" ] && echo yes || echo no)" "yes"
out2="$( cd "$W/app" && bash "$VIBE" run main.vibex 2>&1 | tail -1 )"
check "still answers" "$out2" "42"

note "=== 6. RED: a tampered store copy is replaced, not trusted ==="
sed -i.bak 's/x \* 3/x * 4/' "$W/app/.vibe/store/@rt/mathx/impl.vibe"
rm -f "$W/app/.vibe/store/@rt/mathx/impl.vibe.bak"
( cd "$W/app" && bash "$VIBE" fetch ) > "$W/fetch2.log" 2>&1
check "exit" "$?" "0"
out3="$( cd "$W/app" && bash "$VIBE" run main.vibex 2>&1 | tail -1 )"
check "tamper did not survive" "$out3" "42"

note "=== 7. the pin names a COMMIT, so re-pointing the tag cannot reach it ==="
# This was written expecting a refusal, and measurement said otherwise: `vibe
# add` resolves the ref and records the COMMIT, so a moved `v1.0.0` is not a
# route into a pinned project at all. The stronger answer, kept as the
# measurement rather than reworded into a pass.
cat > "$W/dep/impl.vibe" <<'V'
export fn triple(x: Int) -> Int {
  x * 4
}
V
( cd "$W/dep" && git add -A && \
  git -c user.email=rt@example.invalid -c user.name=rt commit -qm moved && \
  git tag -f v1.0.0 ) >> "$W/git.log" 2>&1
rm -rf "$W/app/.vibe/store" "$VIBE_HOME/cache/pkg"
( cd "$W/app" && bash "$VIBE" fetch ) > "$W/fetch3.log" 2>&1
check "exit" "$?" "0"
grep -q "@$(cd "$W/dep" && git rev-list -n1 v1.0.0)" "$W/fetch3.log" && \
  bad "the moved tag was fetched" || ok "fetched the pinned commit, not the moved tag"
out7="$( cd "$W/app" && bash "$VIBE" run main.vibex 2>&1 | tail -1 )"
check "still the pinned behaviour" "$out7" "42"

note "=== 8. RED: a pin the source cannot satisfy is refused, nothing installed ==="
cp "$W/app/index.vpkg" "$W/app/index.vpkg.good"
badpin="$(printf '%064d' 0 | tr '0' 'a')"
sed -i.bak "s/#pkg:b3:[0-9a-f]\{64\}/#pkg:b3:$badpin/" "$W/app/index.vpkg"
rm -f "$W/app/index.vpkg.bak"
rm -rf "$W/app/.vibe/store" "$VIBE_HOME/cache/pkg"
( cd "$W/app" && bash "$VIBE" fetch ) > "$W/fetch4.log" 2>&1
rc8=$?
check "exit (nonzero = refused)" "$([ "$rc8" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "nothing installed" "$([ -f "$W/app/.vibe/store/@rt/mathx/impl.vibe" ] && echo yes || echo no)" "no"
sed 's/^/      /' "$W/fetch4.log" | tail -4
# Put the good pin back and re-populate the CAS the bad-pin case emptied, so
# what follows is not testing an empty cache.
mv "$W/app/index.vpkg.good" "$W/app/index.vpkg"
( cd "$W/app" && bash "$VIBE" fetch ) > "$W/fetch5.log" 2>&1
check "the good pin installs again" "$?" "0"

note "=== 9. RED: republishing a known version with new content is refused ==="
# Publish the ORIGINAL content first: `vibe add` already recorded 1.0.0 -> its
# hash under trust-on-first-use, so this must be an idempotent no-op, and only
# then is a differing republish the thing under test.
cat > "$W/dep/impl.vibe" <<'V'
export fn triple(x: Int) -> Int {
  x * 3
}
V
bash "$ROOT_DIR/scripts/vibe_pkg.sh" publish "$W/dep" > "$W/pub1.log" 2>&1
check "republish of the SAME content is idempotent" "$?" "0"
cat > "$W/dep/impl.vibe" <<'V'
export fn triple(x: Int) -> Int {
  x * 5
}
V
bash "$ROOT_DIR/scripts/vibe_pkg.sh" publish "$W/dep" > "$W/pub2.log" 2>&1
rc9=$?
check "differing republish (nonzero = refused)" "$([ "$rc9" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
sed 's/^/      /' "$W/pub2.log" | tail -3

note "=== 10. RED: a tampered transparency log is detected on install ==="
logrec="$VIBE_HOME/log/records.tsv"
if [ -f "$logrec" ]; then
  ok "transparency log written by publish: $(wc -l < "$logrec" | tr -d ' ') record(s)"
  cp "$logrec" "$W/records.bak"
  sed -i.bak 's/1\.0\.0/1.0.1/' "$logrec"; rm -f "$logrec.bak"
  bash "$ROOT_DIR/scripts/vibe_pkg.sh" install "@rt/mathx@1.0.0" > "$W/inst_tamper.log" 2>&1
  rc10=$?
  check "install (nonzero = refused)" "$([ "$rc10" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  sed 's/^/      /' "$W/inst_tamper.log" | tail -4
  cp "$W/records.bak" "$logrec"
  bash "$ROOT_DIR/scripts/vibe_pkg.sh" install "@rt/mathx@1.0.0" > "$W/inst_ok.log" 2>&1
  check "and the untampered log installs cleanly" "$?" "0"
else
  bad "no transparency log at $logrec"
fi

note
note "workdir: $W"
if [ "$fail" = 0 ]; then note "[pkg-roundtrip] ok"; else note "[pkg-roundtrip] FAIL"; fi
exit "$fail"
