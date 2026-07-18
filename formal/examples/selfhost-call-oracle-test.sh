#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
bridge="$repo_root/formal/examples/selfhost-call-oracle.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/corpus.tsv" <<'EOF'
version	1
name	issue	verdict	detail	source
accept-case	#1	accept	Unit;types=[]	fn ok() -> Unit { () }
reject-case	#2	reject	type-mismatch	fn reject_me() -> Int { "bad" }
drift-case	#3	reject	type-mismatch	fn accepted_by_checker() -> Int { 1 }
EOF

cat >"$work/fake-checker.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "check" ]
case "$(cat "$2")" in
  *reject_me*) exit 1 ;;
  *checker_error*) exit 64 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$work/fake-checker.sh"

set +e
VIBE_ORACLE_CHECKER="$work/fake-checker.sh" \
  "$bridge" --corpus "$work/corpus.tsv" \
  >"$work/report.tsv" 2>"$work/report.err"
report_status=$?
set -e

[ "$report_status" -eq 0 ] || {
  echo "report mode exited $report_status, expected 0" >&2
  cat "$work/report.err" >&2
  exit 1
}

cat >"$work/expected.tsv" <<'EOF'
status	name	issue	expected	actual	detail
match	accept-case	#1	accept	accept	Unit;types=[]
match	reject-case	#2	reject	reject	type-mismatch
mismatch	drift-case	#3	reject	accept	type-mismatch
summary	matched=2	mismatched=1	errors=0
EOF
diff -u "$work/expected.tsv" "$work/report.tsv"
grep -Fq 'drift-case (#3): Lean=reject, selfhost=accept' "$work/report.err"

set +e
VIBE_ORACLE_CHECKER="$work/fake-checker.sh" \
  "$bridge" --strict --corpus "$work/corpus.tsv" \
  >"$work/strict.tsv" 2>"$work/strict.err"
strict_status=$?
set -e
[ "$strict_status" -eq 1 ] || {
  echo "strict mode exited $strict_status, expected 1" >&2
  exit 1
}

cat >"$work/error.tsv" <<'EOF'
version	1
name	issue	verdict	detail	source
error-case	#4	reject	type-mismatch	fn checker_error() -> Int { 1 }
EOF

set +e
VIBE_ORACLE_CHECKER="$work/fake-checker.sh" \
  "$bridge" --corpus "$work/error.tsv" \
  >"$work/error-report.tsv" 2>"$work/error-report.err"
error_status=$?
set -e
[ "$error_status" -eq 2 ] || {
  echo "checker error exited $error_status, expected 2" >&2
  exit 1
}
grep -Fq $'error\terror-case\t#4\treject\terror\ttype-mismatch' "$work/error-report.tsv"

echo "selfhost call Oracle bridge tests passed"
