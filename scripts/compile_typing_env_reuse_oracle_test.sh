#!/usr/bin/env bash
# Red self-test for scripts/compile_typing_env_reuse_oracle.mjs (#2248, #3796).
#
# 1. The real compiler, unmutated: the oracle must pass. Its JSON records every
#    build the oracle made -- status, diagnostics, artifact digest, executed
#    result, telemetry -- and that recording is the scripted table below.
# 2. Scripted: a fake runner REPLAYS that recording (and writes stand-in reuse
#    records into the cache, two of each kind, so the corruptions have
#    something to rewrite). The unperturbed replay must pass, so a harness
#    that rejected everything would be caught; then each case perturbs ONE
#    cell -- a hit count, a module, a diagnostic, an executed result, a
#    record set -- and asserts the oracle rejects it with the assertion that
#    owns that cell.
# 3. The real compiler behind wrappers, because an oracle that stopped driving
#    the real lane would still satisfy a replay: a flipped module byte, the
#    typed-equality rows stripped from the reused records, each corruption
#    UNDONE before its build (the real compiler then hits, so the oracle's
#    "must miss" is what fails -- the corruption, not something else, is what
#    made it miss), each authority-changing configuration reset to the cold
#    build's, and the `--deny-env` grant dropped from a run.
#
# Each red case runs only the oracle section it perturbs
# (VIBE_COMPILE_TYPING_REUSE_ORACLE_SECTIONS); the green runs cover them all.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

# The oracle drops every VIBE_* variable from its children; these are the ones
# this test reads itself, so none may arrive from the caller (#2252).
unset VIBE_COMPILE_TYPING_REUSE_ORACLE_RUNNER VIBE_COMPILE_TYPING_REUSE_ORACLE_KEEP_TMP \
  VIBE_COMPILE_TYPING_REUSE_ORACLE_SECTIONS

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
ORACLE="$ROOT_DIR/scripts/compile_typing_env_reuse_oracle.mjs"
REAL_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

STAGE2="$(resolve_stage2 compile-typing-env-reuse-oracle-test "${COMPILE_REUSE_ORACLE_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || {
  echo "FAIL no compiler to run the real cases against" >&2; exit 1; }
case "$STAGE2" in /*) STAGE2_ABS="$STAGE2" ;; *) STAGE2_ABS="$ROOT_DIR/$STAGE2" ;; esac

# run_oracle SECTIONS RUNNER [ENV=VALUE...] -> exit code; stdout/stderr in $WORK/out, $WORK/err
run_oracle() {
  local sections="$1" runner="$2"
  shift 2
  env "$@" VIBE_COMPILE_TYPING_REUSE_ORACLE_SECTIONS="$sections" VIBE_COMPILE_TYPING_REUSE_ORACLE_RUNNER="$runner" \
    node "$ORACLE" "$STAGE2_ABS" >"$WORK/out" 2>"$WORK/err"
}

pass_case() { # label sections runner [env...]
  local label="$1"; shift
  if run_oracle "$@"; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected the oracle to pass"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
  fi
}

fail_case() { # label needle sections runner [env...]
  local label="$1" needle="$2"; shift 2
  if run_oracle "$@"; then
    echo "FAIL $label: the oracle PASSED on a mutated input"; fails=$((fails + 1))
  elif grep -qF -- "$needle" "$WORK/err"; then
    echo "ok   $label"
  else
    echo "FAIL $label: failed, but not on the expected assertion (wanted: $needle)"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
  fi
}

ALL="core,records,config,grants"

# ---- 1. the real compiler, unmutated ---------------------------------------
pass_case "the real compiler passes the oracle unmutated" "$ALL" "$REAL_RUNNER"
cp "$WORK/out" "$WORK/recording.json"
if ! node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (!(d.identities.length > 30)) process.exit(1)' "$WORK/recording.json" 2>/dev/null; then
  echo "FAIL the real run left no build recording to replay" >&2
  exit 1
fi

# ---- 2. scripted replay ----------------------------------------------------
# The replaying runner. It answers each build from the table by NAME: a
# compile by its output file, a `vibe run` by its build directory, an
# execution by the result written beside the module, so a module's bytes and
# what it prints can be perturbed apart. The table
# path travels without a VIBE_ prefix, because the oracle drops that namespace.
cat > "$WORK/fake.mjs" <<'FAKE'
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
const args = process.argv.slice(2);
const rows = new Map(JSON.parse(readFileSync(process.env.COMPILE_REUSE_ORACLE_FAKE_TABLE, "utf8")).map((row) => [row.build, row]));
const seg = (text) => `${text.length}:${text}`;
const row = (name) => {
  const found = rows.get(name);
  if (!found) { process.stderr.write(`fake runner: no table row for ${name}\n`); process.exit(3); }
  return found;
};
// Two bindings per publishing build: an alias names a target, the witness
// binds an input to the target and its text, and the target record IS that text.
function publish(cache, name, count) {
  for (let i = 0; i < count; i += 1) {
    const target = `${name}-t${i}`;
    const text = `fake type env ${name} ${i}`;
    writeFileSync(join(cache, `vibe_selfhost_typing_dependency_env_reuse_v10_${name}_${i}.txt`), `TDRE11A${seg(target)}`);
    writeFileSync(join(cache, `vibe_selfhost_typing_dependency_env_reuse_eligibility_v10_${name}_${i}.txt`), `TDRE10W${seg(`input-${i}`)}${seg(target)}${seg(text)}`);
    writeFileSync(join(cache, `vibe_selfhost_type_env_v10_${name}_${i}.tsv`), text);
  }
}
function answer(r) {
  process.stdout.write(r.diagnostics.stdout);
  process.stderr.write(r.diagnostics.stderr);
}
if (args[1] === "main") {
  process.stdout.write(`${readFileSync(`${args[2]}.result`, "utf8")}\n`);
} else if (args[3] === "run") {
  const dir = process.env.VIBE_BUILD_DIR;
  const r = row(basename(dir).slice(".run-".length));
  if (!r.no_artifact) {
    mkdirSync(join(dir, "run"), { recursive: true });
    writeFileSync(join(dir, "run", "run.wasm"), r.artifact);
    writeFileSync(join(dir, "run", "run.wasm.result"), `tdre=${r.result}`);
  }
  if (r.records) publish(process.env.VIBE_BUILD_CACHE_DIR, r.build, r.records);
  answer(r);
  process.exit(r.status);
} else {
  const out = args[4];
  const r = row(basename(out, ".wasm"));
  answer(r);
  if (r.status !== 0) {
    writeFileSync(`${out}.diag`, r.diagnostics.diag);
    process.exit(r.status);
  }
  writeFileSync(out, r.artifact);
  writeFileSync(`${out}.result`, r.result);
  writeFileSync(process.env.VIBE_INCREMENTAL_TELEMETRY_OUT, JSON.stringify(r.telemetry));
  const records = r.records ?? (r.reuse ? 2 : 0);
  if (records) publish(process.env.VIBE_BUILD_CACHE_DIR, r.build, records);
}
FAKE
printf '#!/usr/bin/env bash\nexec node "%s" "$@"\n' "$WORK/fake.mjs" > "$WORK/fake.sh"

# table [JS statements over `row(name)`, `tel(name, rechecked, transport)` and
# `rows`] -> path of a perturbed copy of the recording.
# A perturbation must APPLY: one that changed nothing would pass a red case
# vacuously, so the table builder refuses it.
table() {
  local f="$WORK/table.$RANDOM$RANDOM.json"
  node -e '
    const fs = require("fs");
    const rows = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).identities;
    const before = JSON.stringify(rows);
    const row = (name) => {
      const found = rows.find((r) => r.build === name);
      if (!found) throw new Error(`no recorded build ${name}`);
      return found;
    };
    const tel = (name, rechecked, transport) => Object.assign(row(name).telemetry, {
      modules_rechecked: rechecked, modules_reused: 3 - rechecked, modules_reused_dependency_transport_env: transport });
    new Function("row", "tel", "rows", process.argv[3] || "")(row, tel, rows);
    if (process.argv[3] && JSON.stringify(rows) === before) throw new Error("the perturbation changed nothing");
    fs.writeFileSync(process.argv[2], JSON.stringify(rows));
  ' "$WORK/recording.json" "$f" "${1:-}" || return 1
  echo "$f"
}

scripted_pass() { # label sections perturbation
  local t; t="$(table "$3")" || { echo "FAIL $1: bad perturbation"; fails=$((fails + 1)); return; }
  pass_case "$1" "$2" "$WORK/fake.sh" COMPILE_REUSE_ORACLE_FAKE_TABLE="$t"
}
scripted_fail() { # label needle sections perturbation
  local t; t="$(table "$4")" || { echo "FAIL $1: bad perturbation"; fails=$((fails + 1)); return; }
  fail_case "$1" "$2" "$3" "$WORK/fake.sh" COMPILE_REUSE_ORACLE_FAKE_TABLE="$t"
}

scripted_pass "the replayed recording passes" "$ALL" ""

# core: the body edits must hit, change the program, and match fresh.
scripted_fail "a meaning edit with no reuse hit is refused as vacuous" \
  "the meaning edit with reuse on recorded no dependency-transport reuse" core 'tel("edit-on", 3, 0)'
scripted_fail "a meaning edit that reused fewer consumers than expected is refused" \
  "the meaning edit with reuse on: expected" core 'tel("edit-on", 2, 1)'
scripted_fail "a private edit with no reuse hit is refused" \
  "the private edit with reuse on recorded no dependency-transport reuse" core 'tel("private-on", 3, 0)'
scripted_fail "a capability edit with no reuse hit is refused" \
  "the capability edit with reuse on recorded no dependency-transport reuse" core 'tel("capability-on", 3, 0)'
scripted_fail "an edit that left the module unchanged is refused as proving nothing" \
  "the meaning edit did not change the program" core \
  'row("edit-on").artifact = row("base-on").artifact'
scripted_fail "an edit that left the executed result unchanged is refused as proving nothing" \
  "the private edit did not change the executed result" core \
  'row("private-on").result = row("edit-on").result'
scripted_fail "a reuse-on module that differs from the fresh compile is refused" \
  "meaning edit: the reuse-on compile differs from a fresh reuse-off compile" core \
  'row("edit-on").artifact += "x"'
scripted_fail "a reuse-on module that EXECUTES differently from the fresh one is refused" \
  "private edit: the reuse-on module executed" core \
  'row("private-on").result += "1"'
scripted_fail "identical modules whose result is not the fixture's are refused" \
  "capability-fresh: the program executed" core \
  'row("capability-on").result += "1"; row("capability-fresh").result += "1"'
scripted_fail "reuse-on diagnostics that differ from the fresh ones are refused" \
  "body error: the reuse-on diagnostics differ" core \
  'row("diagnostic-on").diagnostics.diag += " (stale)"'
scripted_fail "a body error the fresh diagnostics do not name is refused" \
  "the body error's fresh diagnostics do not name it" core \
  'for (const n of ["diagnostic-on", "diagnostic-fresh"]) row(n).diagnostics.diag = "dep.vibe: line 1: something else"'
scripted_fail "a wrong recovery after the body error is refused" \
  "recovery after a body error: the reuse-on module executed" core 'row("recover-on").result += "1"'
scripted_fail "a reuse hit with reuse off is refused" \
  "meaning edit with reuse off: expected" core 'tel("control-edit", 1, 2)'
scripted_fail "reusing through records overwritten with garbage is refused" \
  "corrupted reuse records: expected" core 'tel("corrupt-on", 1, 2)'
scripted_fail "a corruption that found no records is refused" \
  "the corruption found no reuse records in the cache" core \
  'for (const r of rows) if (r.reuse) r.records = 0'
scripted_fail "a reuse hit across an interface edit is refused" \
  "interface edit with reuse on: expected" core 'tel("interface-on", 1, 2)'

# records: each kind independently, against an uncorrupted control.
scripted_fail "a snapshot control with no hit is refused (the misses would be vacuous)" \
  "the uncorrupted snapshot recorded no dependency-transport reuse" records 'tel("snapshot-on", 3, 0)'
for kind in alias-malformed alias-splice witness-malformed witness-splice target-malformed target-splice; do
  scripted_fail "reusing through $kind records is refused" \
    "$kind records: expected" records "tel(\"$kind-on\", 1, 2)"
done
scripted_fail "a corrupted-record module that executes wrongly is refused" \
  "witness-splice records: the reuse-on module executed" records 'row("witness-splice-on").result += "1"'
scripted_fail "a cache with no reuse records to corrupt is refused" \
  "the corruption found no alias records" records 'row("base-on").records = 0'
scripted_fail "a splice with nothing to exchange is refused" \
  "the alias splice needs two distinct valid alias records" records 'row("base-on").records = 1'

# config: authority changes miss, the backend may hit, all match fresh.
for name in cfg-flags error-row resolution; do
  scripted_fail "a reuse hit across the $name configuration change is refused" \
    "the $name configuration change: expected" config "tel(\"$name-on\", 1, 2)"
done
scripted_fail "a backend change that stops hitting is refused" \
  "the backend configuration change: expected" config 'tel("backend-on", 3, 0)'
scripted_fail "a configuration fresh compile that ignored the configuration is refused" \
  "cfg-flags-fresh: the program executed" config \
  'row("cfg-flags-on").result = row("cfg-flags-fresh").result = row("edit-fresh").result'

# grants: the run artifact under --deny-env.
scripted_fail "a --deny-env run that executes the full-grant program is refused" \
  "the --deny-env run executed" grants 'row("run-deny-on").result = row("run-full-on").result'
scripted_fail "a --deny-env artifact that differs from a fresh run is refused" \
  "the --deny-env run artifact differs from a fresh reuse-off run" grants 'row("run-deny-on").artifact += "x"'
scripted_fail "a run lane that starts publishing transport records is flagged" \
  "vibe run published" grants 'row("run-deny-on").records = 2'
scripted_fail "a run that wrote no artifact is refused" \
  "vibe run wrote no artifact" grants 'row("run-full-on").no_artifact = true'

# ---- 3. the real compiler behind wrappers ----------------------------------
# Each wrapper calls the real runner, then acts on ONE named build. Every
# action must APPLY: a target it cannot find exits non-zero rather than
# no-opping, because a silent no-op looks exactly like a passing gate.
cat > "$WORK/wrap.sh" <<'WRAP'
#!/usr/bin/env bash
set -uo pipefail
real="$COMPILE_REUSE_ORACLE_REAL_RUNNER"
target="$COMPILE_REUSE_ORACLE_TARGET"
out=""
for arg in "$@"; do case "$arg" in *.wasm) out="$arg" ;; esac; done
name="$(basename "$out" .wasm)"
if [ "${4:-}" = run ]; then name="$(basename "${VIBE_BUILD_DIR:-}")"; name="${name#.run-}"; fi
[ "${2:-}" = cli_main ] && [ "$name" = "$target" ] || exec bash "$real" "$@"
case "$COMPILE_REUSE_ORACLE_ACTION" in
  flip)
    bash "$real" "$@" || exit $?
    python3 -c '
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
if not data:
    raise SystemExit("wrapper: %s is empty" % path)
data[-1] ^= 0xFF
open(path, "wb").write(bytes(data))
' "$out" ;;
  strip)
    python3 "$COMPILE_REUSE_ORACLE_STRIP_PY" "$VIBE_BUILD_CACHE_DIR" || exit 9
    exec bash "$real" "$@" ;;
  undo)
    # Put the cold snapshot's records back over the corrupted ones.
    snapshot="$(dirname "$VIBE_BUILD_CACHE_DIR")/cold-snapshot"
    [ -d "$snapshot" ] || { echo "wrapper: no cold snapshot beside $VIBE_BUILD_CACHE_DIR" >&2; exit 9; }
    cp "$snapshot"/vibe_selfhost_* "$VIBE_BUILD_CACHE_DIR"/ || exit 9
    exec bash "$real" "$@" ;;
  reset-config)
    # The cold build's configuration, whatever the oracle asked for.
    exec env -u VIBE_CHECK_ERROR_ROW VIBE_CFG=tdre_lo VIBE_HOME="$PWD/.home" bash "$real" "$@" ;;
  drop-deny)
    args=()
    dropped=0
    for arg in "$@"; do
      if [ "$arg" = --deny-env ]; then dropped=1; else args+=("$arg"); fi
    done
    [ "$dropped" = 1 ] || { echo "wrapper: no --deny-env to drop" >&2; exit 9; }
    exec bash "$real" "${args[@]}" ;;
  *) echo "wrapper: unknown action" >&2; exit 9 ;;
esac
WRAP
chmod +x "$WORK/wrap.sh"

real_fail() { # label needle sections target action
  fail_case "$1" "$2" "$3" "$WORK/wrap.sh" \
    COMPILE_REUSE_ORACLE_REAL_RUNNER="$REAL_RUNNER" COMPILE_REUSE_ORACLE_TARGET="$4" \
    COMPILE_REUSE_ORACLE_ACTION="$5" COMPILE_REUSE_ORACLE_STRIP_PY="$WORK/strip_eq.py"
}

# Strips every typed-equality row from the reused records before the meaning
# edit's reuse-on build, and rebinds each witness to the stripped record so the
# reuse is still taken: a reuse that stopped republishing the typed-lowering
# rows. The oracle must refuse it. Like the flip, the strip must APPLY.
cat > "$WORK/strip_eq.py" <<'STRIPPY'
import os, sys

def fp(data):
    h1, h2 = 17, 29
    for i, c in enumerate(data):
        h1 = (h1 * 131 + c + 1) % 2147483647
        h2 = (h2 * 65599 + c + i + 1) % 2147483629
    return b"%d:%d:%d" % (len(data), h1, h2)

def strip(record):
    head = b"module_typed_lowering_offsets\tv8\n"
    start = record.find(head)
    if start < 0:
        return record
    lines = record[start + len(head):].split(b"\n")
    offsets, rest = [], []
    i = 0
    while not lines[i].startswith(b"module_typed_lowering_offsets\t"):
        offsets.append(lines[i]); i += 1
    count = lines[i]; i += 1
    eqrows = []
    while lines[i].startswith(b"module_typed_lowering_offsets\teqrow\t"):
        eqrows.append(lines[i]); i += 1
    if not eqrows:
        return record
    body = b"\n".join(offsets)
    tail = b"module_typed_lowering_offsets\teqcount\t0\nmodule_typed_lowering_offsets\tdigest\t" + fp(body) + b"\nmodule_typed_lowering_offsets\tend\n"
    return record[:start] + head + b"".join(o + b"\n" for o in offsets) + count + b"\n" + tail

def segment(data, pos):
    colon = data.index(b":", pos)
    n = int(data[pos:colon])
    return data[colon + 1:colon + 1 + n], colon + 1 + n

cache = sys.argv[1]
names = os.listdir(cache)
changed = {}
for name in names:
    if name.startswith("vibe_selfhost_type_env"):
        path = os.path.join(cache, name)
        old = open(path, "rb").read()
        new = strip(old)
        if new != old:
            changed[old] = new
            open(path, "wb").write(new)
if not changed:
    raise SystemExit("strip_eq: no record carried a typed equality row")
rebound = 0
for name in names:
    if name.startswith("vibe_selfhost_typing_dependency_env_reuse_eligibility"):
        path = os.path.join(cache, name)
        data = open(path, "rb").read()
        tag = b"TDRE10W"
        if not data.startswith(tag):
            continue
        key, p = segment(data, len(tag))
        fpv, p = segment(data, p)
        target, p = segment(data, p)
        if target in changed:
            t = changed[target]
            open(path, "wb").write(tag + b"%d:" % len(key) + key + b"%d:" % len(fpv) + fpv + b"%d:" % len(t) + t)
            rebound += 1
if rebound == 0:
    raise SystemExit("strip_eq: no witness bound a stripped record")
print("strip_eq: %d records, %d witnesses" % (len(changed), rebound), file=sys.stderr)
STRIPPY

real_fail "altering the REAL reuse-on module is refused" \
  "meaning edit: the reuse-on compile differs from a fresh reuse-off compile" core edit-on flip

# The fixture's `==` must depend on the reused typed rows: with them stripped,
# the reuse-on build is refused at the comparison. Before this case existed
# the fixture compared against a literal, which carries its own element type,
# and the oracle passed with the rows stripped (Codex on #3804).
fail_case "a reuse that drops the typed-equality rows is refused" "edit-on failed" core "$WORK/wrap.sh" \
  COMPILE_REUSE_ORACLE_REAL_RUNNER="$REAL_RUNNER" COMPILE_REUSE_ORACLE_TARGET=edit-on \
  COMPILE_REUSE_ORACLE_ACTION=strip COMPILE_REUSE_ORACLE_STRIP_PY="$WORK/strip_eq.py"
if ! grep -qF "structural \`==\` cannot be decided" "$WORK/err"; then
  echo "FAIL stripping the typed rows failed, but not at the comparison"; sed -n '1,8p' "$WORK/err"; fails=$((fails + 1))
fi

for kind in alias-malformed alias-splice witness-malformed witness-splice target-malformed target-splice; do
  real_fail "undoing the $kind corruption makes the REAL compiler hit, and the oracle fail" \
    "$kind records: expected planned/rechecked/transport-reused 3/3/0, got 3/1/2" records "$kind-on" undo
done

for name in cfg-flags error-row resolution; do
  real_fail "resetting the $name configuration makes the REAL compiler hit, and the oracle fail" \
    "the $name configuration change: expected planned/rechecked/transport-reused 3/3/0, got 3/1/2" config "$name-on" reset-config
done

real_fail "dropping --deny-env from the REAL run is refused" \
  "the --deny-env run executed" grants run-deny-on drop-deny

if [ "$fails" -eq 0 ]; then
  echo "compile-typing-env-reuse-oracle self-test: ok (real green + replay green + scripted and real reds, against $STAGE2)"
else
  echo "compile-typing-env-reuse-oracle self-test: $fails case(s) failed" >&2
  exit 1
fi
