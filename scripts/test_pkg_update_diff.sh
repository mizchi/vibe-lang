#!/usr/bin/env bash
# `vibe pkg update` reports a contract change canonically (#3673,
# registry-design property 4):
#
#   bash scripts/test_pkg_update_diff.sh <stage2.wasm>
#
# 1. A version whose contract only reorders its declarations, renames a
#    parameter or reorders an effect row is reported as no surface change --
#    not as removals and additions that read like an authority change.
# 2. A version that adds a declaration lists only that declaration, and warns
#    that the contract now requires the new capability.
# 3. A version that removes a declaration lists it, and says the capability
#    only it needed is no longer required.
# 4. A capability required through an effectset alias is reported as that
#    capability, and so is one a function-valued `let` requires.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_pkg_update_diff.sh <stage2.wasm>" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
unset VIBE_HOST_WITHHOLD || true

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-pkg-update-diff.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[pkg-update-diff] FAIL $*" >&2; [ -f "$WORK/upd.out" ] && sed 's/^/  /' "$WORK/upd.out" >&2; exit 1; }
export VIBE_HOME="$WORK/home"
src="$VIBE_HOME/src/@diff3673/geo"
mkdir -p "$src"
vibe_pkg() {
  VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" pkg "$@"
}
release() { # <version> <contract body> <impl>
  printf 'name = @diff3673/geo\nversion = %s\n\n%s' "$1" "$2" > "$src/index.vpkg"
  printf '%s' "$3" > "$src/impl.vibe"
  vibe_pkg publish "$src" > "$WORK/pub.out" 2>&1 || { cat "$WORK/pub.out" >&2; fail "publish $1 was refused"; }
}
update() {
  vibe_pkg update @diff3673/geo > "$WORK/upd.out" 2>&1 || fail "update failed"
}

release 1.0.0 'fn area(w: Int, h: Int) -> Int
fn save(path: String) -> Unit with Fs + Console
' 'export fn area(w: Int, h: Int) -> Int { w * h }
export fn save(path: String) -> Unit with Fs + Console { println(path) }
'
vibe_pkg install @diff3673/geo@1.0.0 > "$WORK/inst.out" 2>&1 || { cat "$WORK/inst.out" >&2; fail "install 1.0.0"; }

# 1. Reordered declarations, a renamed parameter and a reordered row: the
#    same surface. The row order is part of the contract hash, so the hashes
#    differ and the comparison has to say there is nothing to see.
release 1.0.1 'fn save(file: String) -> Unit with Console + Fs
fn area(width: Int, height: Int) -> Int
' 'export fn save(file: String) -> Unit with Console + Fs { println(file) }
export fn area(width: Int, height: Int) -> Int { width * height }
'
update
grep -q 'update @diff3673/geo: 1.0.0 -> 1.0.1' "$WORK/upd.out" || fail "1.0.1 was not the update"
if grep -qE '\]   [-+]fn ' "$WORK/upd.out"; then fail "a reordered, renamed contract was reported as removals and additions"; fi
grep -q 'effect surface: now requires' "$WORK/upd.out" && fail "a reordered row was reported as a new capability"
if grep -q 'contract surface: unchanged' "$WORK/upd.out"; then :
else
  grep -q 'no declaration changed' "$WORK/upd.out" || fail "a contract that only changed its spelling did not say no declaration changed"
  grep -q 'effect surface: unchanged' "$WORK/upd.out" || fail "a reordered row did not leave the effect surface unchanged"
fi

# 2. An addition that needs Http: one added line, and a warning naming it.
release 1.1.0 'fn save(file: String) -> Unit with Console + Fs
fn area(width: Int, height: Int) -> Int
fn fetch(url: String) -> String with Http
' 'export fn save(file: String) -> Unit with Console + Fs { println(file) }
export fn area(width: Int, height: Int) -> Int { width * height }
export fn fetch(url: String) -> String with Http { url }
'
update
grep -q 'update @diff3673/geo: 1.0.1 -> 1.1.0' "$WORK/upd.out" || fail "1.1.0 was not the update"
[ "$(grep -cE '\]   [-+]fn ' "$WORK/upd.out")" = 1 ] || fail "the addition did not come out as exactly one changed declaration"
grep -qF '  +fn fetch (String) -> String with { Http }' "$WORK/upd.out" || fail "the added declaration is not listed"
grep -qF 'warning: effect surface: now requires Http (fetch)' "$WORK/upd.out" || fail "the new capability was not warned about"

# 3. Removing the only Fs declaration: the removal, and Fs no longer required.
release 2.0.0 'fn area(width: Int, height: Int) -> Int
fn fetch(url: String) -> String with Http
' 'export fn area(width: Int, height: Int) -> Int { width * height }
export fn fetch(url: String) -> String with Http { url }
'
update
grep -qF '  -fn save (String) -> Unit with { Console, Fs }' "$WORK/upd.out" || fail "the removed declaration is not listed"
grep -qF 'effect surface: no longer requires Fs' "$WORK/upd.out" || fail "the dropped capability was not reported"
grep -qF 'effect surface: no longer requires Console' "$WORK/upd.out" || fail "the dropped Console was not reported"
grep -q 'now requires' "$WORK/upd.out" && fail "a removal was reported as a new requirement"

# 4. A capability reached through an effectset alias is still a capability:
#    the row names `Disk`, and `Disk` is Fs.
release 2.1.0 'effectset Disk = { Fs }
fn area(width: Int, height: Int) -> Int
fn fetch(url: String) -> String with Http
fn store(path: String) -> Unit with Disk
' 'export fn area(width: Int, height: Int) -> Int { width * height }
export fn fetch(url: String) -> String with Http { url }
export fn store(path: String) -> Unit with Fs { Fs::write_file(path, "") }
'
update
grep -q 'update @diff3673/geo: 2.0.0 -> 2.1.0' "$WORK/upd.out" || fail "2.1.0 was not the update"
grep -qF 'warning: effect surface: now requires Fs (store)' "$WORK/upd.out" || fail "a capability behind an effectset alias was not warned about"

# 5. A function exported as an annotated value (`let f: (..) -> T with E`)
#    prints its row unbraced; it is still a capability.
release 2.2.0 'effectset Disk = { Fs }
fn area(width: Int, height: Int) -> Int
fn fetch(url: String) -> String with Http
fn store(path: String) -> Unit with Disk
let shout: (String) -> Unit with Console
' 'export fn area(width: Int, height: Int) -> Int { width * height }
export fn fetch(url: String) -> String with Http { url }
export fn store(path: String) -> Unit with Fs { Fs::write_file(path, "") }
export let shout: (String) -> Unit with Console = (s) -> { println(s) }
'
update
grep -q 'update @diff3673/geo: 2.1.0 -> 2.2.0' "$WORK/upd.out" || fail "2.2.0 was not the update"
grep -qF 'warning: effect surface: now requires Console (shout)' "$WORK/upd.out" || fail "a function-valued declaration's capability was not warned about"

# 6. A function exported through a type alias carries its row on the alias's
#    line, not its own.
release 2.3.0 'effectset Disk = { Fs }
type Clock = () -> Int with Process
fn area(width: Int, height: Int) -> Int
fn fetch(url: String) -> String with Http
fn store(path: String) -> Unit with Disk
let shout: (String) -> Unit with Console
let tick: Clock
' 'type Clock = () -> Int with Process
export fn area(width: Int, height: Int) -> Int { width * height }
export fn fetch(url: String) -> String with Http { url }
export fn store(path: String) -> Unit with Fs { Fs::write_file(path, "") }
export let shout: (String) -> Unit with Console = (s) -> { println(s) }
export let tick: Clock = () -> { 0 }
'
update
grep -q 'update @diff3673/geo: 2.2.0 -> 2.3.0' "$WORK/upd.out" || fail "2.3.0 was not the update"
grep -qF 'warning: effect surface: now requires Process' "$WORK/upd.out" || fail "a capability behind a function type alias was not warned about"

# 7. A struct field's function type: its bare row is followed by `;`.
release 2.4.0 'effectset Disk = { Fs }
type Clock = () -> Int with Process
struct Probe { read: () -> Int with Stdin; id: Int }
fn area(width: Int, height: Int) -> Int
fn fetch(url: String) -> String with Http
fn store(path: String) -> Unit with Disk
let shout: (String) -> Unit with Console
let tick: Clock
' 'type Clock = () -> Int with Process
export struct Probe { read: () -> Int with Stdin; id: Int }
export fn area(width: Int, height: Int) -> Int { width * height }
export fn fetch(url: String) -> String with Http { url }
export fn store(path: String) -> Unit with Fs { Fs::write_file(path, "") }
export let shout: (String) -> Unit with Console = (s) -> { println(s) }
export let tick: Clock = () -> { 0 }
'
update
grep -q 'update @diff3673/geo: 2.3.0 -> 2.4.0' "$WORK/upd.out" || fail "2.4.0 was not the update"
grep -qF 'warning: effect surface: now requires Stdin' "$WORK/upd.out" || fail "a struct field's capability was not warned about"

echo "[pkg-update-diff] ok (spelling-only change shows nothing; an addition lists one line and warns of Http; a removal lists it and drops Fs/Console; effectset and type aliases, function-valued lets and struct fields are seen)"
