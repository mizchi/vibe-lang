#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
corpus="$repo_root/formal/oracle/call-typing.tsv"
checker="${VIBE_ORACLE_CHECKER:-$repo_root/scripts/vibe_cli.sh}"
strict=0

usage() {
  cat <<'EOF'
usage: formal/examples/selfhost-call-oracle.sh [--strict] [--corpus PATH] [--checker PATH]

Compare the Lean call-typing Oracle corpus with the selfhost checker.
Report mode tolerates semantic mismatches; --strict exits 1 when any drift exists.
Checker infrastructure errors always exit 2.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)
      strict=1
      shift
      ;;
    --corpus)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      corpus="$2"
      shift 2
      ;;
    --checker)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      checker="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "selfhost-call-oracle: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -f "$corpus" ] || {
  echo "selfhost-call-oracle: corpus not found: $corpus" >&2
  exit 2
}
[ -x "$checker" ] || {
  echo "selfhost-call-oracle: checker is not executable: $checker" >&2
  exit 2
}

exec 3<"$corpus"
IFS=$'\t' read -r version_key version_value version_extra <&3 || {
  echo "selfhost-call-oracle: empty corpus: $corpus" >&2
  exit 2
}
if [ "$version_key" != "version" ] || [ "$version_value" != "1" ] || [ -n "${version_extra:-}" ]; then
  echo "selfhost-call-oracle: unsupported corpus version header" >&2
  exit 2
fi

IFS=$'\t' read -r h_name h_issue h_verdict h_detail h_source h_extra <&3 || {
  echo "selfhost-call-oracle: missing corpus column header" >&2
  exit 2
}
if [ "$h_name" != "name" ] || [ "$h_issue" != "issue" ] || \
   [ "$h_verdict" != "verdict" ] || [ "$h_detail" != "detail" ] || \
   [ "$h_source" != "source" ] || [ -n "${h_extra:-}" ]; then
  echo "selfhost-call-oracle: unexpected corpus columns" >&2
  exit 2
fi

mkdir -p "$repo_root/_build"
work="$(mktemp -d "$repo_root/_build/formal-call-oracle.XXXXXX")"
trap 'rm -rf "$work"' EXIT

matched=0
mismatched=0
errors=0
row=2
printf 'status\tname\tissue\texpected\tactual\tdetail\n'

while IFS=$'\t' read -r name issue verdict detail source extra <&3; do
  row=$((row + 1))
  [ -n "$name$issue$verdict$detail$source${extra:-}" ] || continue
  if [ -n "${extra:-}" ] || [ -z "$name" ] || [ -z "$issue" ] || \
     [ -z "$detail" ] || [ -z "$source" ]; then
    echo "selfhost-call-oracle: malformed row $row" >&2
    exit 2
  fi
  case "$verdict" in
    accept|reject) ;;
    *)
      echo "selfhost-call-oracle: invalid verdict '$verdict' at row $row" >&2
      exit 2
      ;;
  esac

  slug="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '_')"
  source_file="$work/$(printf '%04d' "$row")-$slug.vibe"
  log_file="$source_file.log"
  printf '%s\n' "$source" >"$source_file"

  if "$checker" check "$source_file" >"$log_file" 2>&1; then
    checker_status=0
  else
    checker_status=$?
  fi

  case "$checker_status" in
    0) actual="accept" ;;
    1) actual="reject" ;;
    *) actual="error" ;;
  esac

  if [ "$actual" = "error" ]; then
    status="error"
    errors=$((errors + 1))
    echo "$name ($issue): checker exited $checker_status" >&2
    sed -n '1,5p' "$log_file" >&2
  elif [ "$actual" = "$verdict" ]; then
    status="match"
    matched=$((matched + 1))
  else
    status="mismatch"
    mismatched=$((mismatched + 1))
    echo "$name ($issue): Lean=$verdict, selfhost=$actual" >&2
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$status" "$name" "$issue" "$verdict" "$actual" "$detail"
done

printf 'summary\tmatched=%d\tmismatched=%d\terrors=%d\n' \
  "$matched" "$mismatched" "$errors"

if [ "$errors" -gt 0 ]; then
  exit 2
fi
if [ "$strict" -eq 1 ] && [ "$mismatched" -gt 0 ]; then
  exit 1
fi
