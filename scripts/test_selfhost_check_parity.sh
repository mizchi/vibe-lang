#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_check_parity}"
RAW_DIR="$OUT_DIR/raw"
CASES_FILE="${VIBE_CHECK_PARITY_CASES_FILE:-$PROJECT_ROOT/bench/selfhost_check_parity/cases.txt}"
ALLOWLIST_FILE="${VIBE_CHECK_PARITY_ALLOWLIST_FILE:-$PROJECT_ROOT/bench/selfhost_check_parity/allowed_diff_patterns.txt}"
SNAPSHOT_FILE="${VIBE_CHECK_PARITY_SNAPSHOT_FILE:-$PROJECT_ROOT/bench/golden/selfhost_check_parity_snapshot.json}"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
STAGE1_CHECKER_WASM="${STAGE1_CHECKER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm}"
REQUIRE_PARITY="${VIBE_CHECK_PARITY_REQUIRE_PARITY:-1}"
UPDATE_SNAPSHOT="${VIBE_CHECK_PARITY_UPDATE:-0}"

mkdir -p "$RAW_DIR"

if [ ! -x "$VIBE_BIN" ]; then
  echo "[check-parity] building host CLI..." >&2
  moon build --target native --release src/cmd/vibe --warn-list '-29'
fi

if [ ! -f "$STAGE1_CHECKER_WASM" ]; then
  echo "[check-parity] building selfhost checker wasm..." >&2
  moon build --target wasm src/cmd/vibe_check_wasi
fi

if ! command -v moonrun >/dev/null 2>&1; then
  echo "check parity gate failed: moonrun not found" >&2
  exit 1
fi

if [ ! -f "$CASES_FILE" ]; then
  echo "check parity gate failed: cases file not found: $CASES_FILE" >&2
  exit 1
fi

cases=()
while IFS= read -r row || [ -n "$row" ]; do
  case "$row" in
    ""|\#*) continue ;;
  esac
  if [ ! -f "$PROJECT_ROOT/$row" ]; then
    echo "check parity gate failed: case not found: $row" >&2
    exit 1
  fi
  cases+=("$row")
done < "$CASES_FILE"

if [ "${#cases[@]}" -eq 0 ]; then
  echo "check parity gate failed: no cases resolved" >&2
  exit 1
fi

echo "[check-parity] cases=${#cases[@]}"

for rel_case in "${cases[@]}"; do
  case_path="$PROJECT_ROOT/$rel_case"
  safe="$(printf '%s' "$rel_case" | tr '/.' '__')"

  host_stdout="$RAW_DIR/${safe}.host.stdout"
  host_stderr="$RAW_DIR/${safe}.host.stderr"
  self_stdout="$RAW_DIR/${safe}.self.stdout"
  self_stderr="$RAW_DIR/${safe}.self.stderr"
  host_norm="$RAW_DIR/${safe}.host.norm.json"
  self_norm="$RAW_DIR/${safe}.self.norm.json"

  set +e
  env VIBE_CHECK_DEBUG=0 "$VIBE_BIN" check "$case_path" >"$host_stdout" 2>"$host_stderr"
  host_status=$?
  set -e

  set +e
  moonrun "$STAGE1_CHECKER_WASM" --check --json --file "$case_path" >"$self_stdout" 2>"$self_stderr"
  self_status=$?
  set -e

  node - "$rel_case" "$host_stdout" "$host_stderr" "$host_status" > "$host_norm" <<'NODE'
const fs = require('fs');
const [,, relCase, outPath, errPath, statusText] = process.argv;
const status = Number(statusText || '0');
const text = `${fs.readFileSync(outPath, 'utf8')}\n${fs.readFileSync(errPath, 'utf8')}`;
const signatures = [];
for (const raw of text.split(/\r?\n/)) {
  const line = raw.trim();
  if (!line) continue;
  if (/^summary: errors=\d+, warnings=\d+$/.test(line)) continue;
  if (/^check: \d+ error\(s\) found$/.test(line)) continue;
  if (/^at\s+.+@.+$/.test(line) || /^\s+at\s+.+@.+$/.test(raw)) continue;
  let m = line.match(/^.+:\d+:\d+: ([a-z_]+): (.+)$/);
  if (m) {
    let stage = m[1];
    let message = m[2];
    if (stage === 'parse' || message.startsWith('parse: ')) {
      stage = 'parse';
      message = 'parse_error';
    }
    const kind = stage === 'warning' ? 'W' : 'E';
    signatures.push(`${kind}:${stage}:${message}`);
    continue;
  }
  m = line.match(/^check: [^:]+: (.+)$/);
  if (m) {
    const rawMessage = m[1];
    if (rawMessage.startsWith('parse: ')) {
      signatures.push('E:parse:parse_error');
    } else {
      signatures.push(`E:check:${rawMessage}`);
    }
    continue;
  }
}
signatures.sort();
const warningCount = signatures.filter((s) => s.startsWith('W:')).length;
const errorCount = signatures.length - warningCount;
const out = {
  case: relCase,
  runtime: 'host',
  exit_status: status,
  error_count: errorCount,
  warning_count: warningCount,
  signatures,
};
process.stdout.write(JSON.stringify(out, null, 2));
NODE

  node - "$rel_case" "$self_stdout" "$self_stderr" "$self_status" > "$self_norm" <<'NODE'
const fs = require('fs');
const [,, relCase, outPath, errPath, statusText] = process.argv;
const status = Number(statusText || '0');
const stdout = fs.readFileSync(outPath, 'utf8').trim();
const stderr = fs.readFileSync(errPath, 'utf8').trim();
if (!stdout) {
  const fail = {
    case: relCase,
    runtime: 'selfhost',
    exit_status: status,
    parse_error: 'empty stdout',
    stderr,
    error_count: 1,
    warning_count: 0,
    signatures: ['E:check:empty selfhost json output'],
  };
  process.stdout.write(JSON.stringify(fail, null, 2));
  process.exit(0);
}
let payload;
try {
  payload = JSON.parse(stdout);
} catch (e) {
  const fail = {
    case: relCase,
    runtime: 'selfhost',
    exit_status: status,
    parse_error: `invalid json: ${e.message}`,
    stderr,
    raw_stdout: stdout,
    error_count: 1,
    warning_count: 0,
    signatures: ['E:check:invalid selfhost json output'],
  };
  process.stdout.write(JSON.stringify(fail, null, 2));
  process.exit(0);
}
const diagnostics = Array.isArray(payload.diagnostics) ? payload.diagnostics : [];
const signatures = diagnostics.map((d) => {
  let stage = String(d && d.stage ? d.stage : 'check');
  let message = String(d && d.message ? d.message : '');
  if (stage === 'parse') {
    message = 'parse_error';
  }
  const kind = stage === 'warning' ? 'W' : 'E';
  return `${kind}:${stage}:${message}`;
}).sort();
const warningCount = signatures.filter((s) => s.startsWith('W:')).length;
const errorCount = signatures.length - warningCount;
const out = {
  case: relCase,
  runtime: 'selfhost',
  exit_status: status,
  error_count: errorCount,
  warning_count: warningCount,
  signatures,
};
process.stdout.write(JSON.stringify(out, null, 2));
NODE

done

CURRENT_JSON="$OUT_DIR/selfhost_check_parity.current.json"
node - "$RAW_DIR" "$ALLOWLIST_FILE" "${cases[@]}" > "$CURRENT_JSON" <<'NODE'
const fs = require('fs');
const path = require('path');

const [, , rawDir, allowlistPath, ...cases] = process.argv;

const allow = {
  host: [],
  self: [],
  meta: [],
};
if (fs.existsSync(allowlistPath)) {
  const text = fs.readFileSync(allowlistPath, 'utf8');
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const idx = line.indexOf(':');
    if (idx <= 0) continue;
    const scope = line.slice(0, idx);
    const pattern = line.slice(idx + 1);
    if (!allow[scope]) continue;
    allow[scope].push(new RegExp(pattern));
  }
}

function safeName(relCase) {
  return relCase.replace(/[/.]/g, '_');
}

function readNorm(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function multisetDiff(a, b) {
  const m = new Map();
  for (const v of b) m.set(v, (m.get(v) || 0) + 1);
  const out = [];
  for (const v of a) {
    const n = m.get(v) || 0;
    if (n > 0) {
      m.set(v, n - 1);
    } else {
      out.push(v);
    }
  }
  return out.sort();
}

function isAllowed(scope, text) {
  const rs = allow[scope] || [];
  return rs.some((r) => r.test(text));
}

const perCase = [];
let unexpectedCount = 0;
for (const relCase of cases) {
  const safe = safeName(relCase);
  const host = readNorm(path.join(rawDir, `${safe}.host.norm.json`));
  const self = readNorm(path.join(rawDir, `${safe}.self.norm.json`));

  const hostOnly = multisetDiff(host.signatures, self.signatures);
  const selfOnly = multisetDiff(self.signatures, host.signatures);

  const allowedHostOnly = [];
  const unexpectedHostOnly = [];
  for (const sig of hostOnly) {
    if (isAllowed('host', sig)) {
      allowedHostOnly.push(sig);
    } else {
      unexpectedHostOnly.push(sig);
    }
  }

  const allowedSelfOnly = [];
  const unexpectedSelfOnly = [];
  for (const sig of selfOnly) {
    if (isAllowed('self', sig)) {
      allowedSelfOnly.push(sig);
    } else {
      unexpectedSelfOnly.push(sig);
    }
  }

  const exitMismatch = host.exit_status !== self.exit_status;
  const exitMismatchAllowed = !exitMismatch || isAllowed('meta', 'exit_status_mismatch');
  const unexpectedExitMismatch = exitMismatch && !exitMismatchAllowed;

  unexpectedCount += unexpectedHostOnly.length;
  unexpectedCount += unexpectedSelfOnly.length;
  unexpectedCount += unexpectedExitMismatch ? 1 : 0;

  perCase.push({
    case: relCase,
    host_exit_status: host.exit_status,
    self_exit_status: self.exit_status,
    host_error_count: host.error_count,
    self_error_count: self.error_count,
    host_warning_count: host.warning_count,
    self_warning_count: self.warning_count,
    allowed_host_only: allowedHostOnly,
    unexpected_host_only: unexpectedHostOnly,
    allowed_self_only: allowedSelfOnly,
    unexpected_self_only: unexpectedSelfOnly,
    exit_status_mismatch: exitMismatch,
    exit_status_mismatch_allowed: exitMismatchAllowed,
    unexpected_exit_status_mismatch: unexpectedExitMismatch,
  });
}

const out = {
  schema_version: 1,
  total_cases: cases.length,
  unexpected_count: unexpectedCount,
  allowlist: {
    host: allow.host.map((r) => r.source),
    self: allow.self.map((r) => r.source),
    meta: allow.meta.map((r) => r.source),
  },
  cases: perCase,
};

process.stdout.write(JSON.stringify(out, null, 2));
NODE

if [ "$UPDATE_SNAPSHOT" = "1" ]; then
  cp "$CURRENT_JSON" "$SNAPSHOT_FILE"
  echo "[check-parity] snapshot updated: $SNAPSHOT_FILE"
fi

snapshot_diff=0
if [ -f "$SNAPSHOT_FILE" ]; then
  if ! diff -u "$SNAPSHOT_FILE" "$CURRENT_JSON" > "$OUT_DIR/snapshot.diff"; then
    snapshot_diff=1
  fi
else
  snapshot_diff=1
  echo "[check-parity] snapshot not found: $SNAPSHOT_FILE" >&2
fi

unexpected_count="$(node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));console.log(j.unexpected_count);" "$CURRENT_JSON")"

echo "=== selfhost check parity summary ==="
node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));for(const c of j.cases){const u=c.unexpected_host_only.length + c.unexpected_self_only.length + (c.unexpected_exit_status_mismatch?1:0);console.log(c.case + ": host_exit=" + c.host_exit_status + " self_exit=" + c.self_exit_status + " host_err=" + c.host_error_count + " self_err=" + c.self_error_count + " host_warn=" + c.host_warning_count + " self_warn=" + c.self_warning_count + " unexpected=" + u);}' "$CURRENT_JSON"
echo "snapshot: $SNAPSHOT_FILE"
echo "current:  $CURRENT_JSON"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost Check Parity"
    echo
    echo "- Cases: ${#cases[@]}"
    echo "- Unexpected diffs: $unexpected_count"
    echo "- Snapshot diff: $snapshot_diff"
    echo "- Snapshot: \\`$SNAPSHOT_FILE\\`"
    echo "- Current: \\`$CURRENT_JSON\\`"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ "$REQUIRE_PARITY" = "1" ]; then
  if [ "$unexpected_count" -gt 0 ]; then
    echo "check parity gate failed: unexpected diffs=$unexpected_count" >&2
    exit 1
  fi
  if [ "$snapshot_diff" -ne 0 ]; then
    echo "check parity gate failed: snapshot mismatch (see $OUT_DIR/snapshot.diff)" >&2
    exit 1
  fi
fi

echo "check parity gate passed"
