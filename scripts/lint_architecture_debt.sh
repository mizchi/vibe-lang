#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_ARCH_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
SCAN_ROOT="${VIBE_ARCH_LINT_ROOT:-$PROJECT_ROOT}"
RULES_FILE="${VIBE_ARCH_LINT_RULES:-$PROJECT_ROOT/scripts/architecture_debt_rules.tsv}"
ALLOWLIST_FILE="${VIBE_ARCH_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/architecture_debt_allowlist.txt}"

BASELINE_MARKER='# --- generated baseline: bash scripts/lint_architecture_debt.sh --update ---'

update_mode=0
for arg in "$@"; do
  case "$arg" in
    --update) update_mode=1 ;;
    *)
      echo "architecture-debt lint: unknown argument: $arg" >&2
      echo "usage: lint_architecture_debt.sh [--update]" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$SCAN_ROOT" ]; then
  echo "architecture-debt lint: scan root not found: $SCAN_ROOT" >&2
  exit 1
fi
if [ ! -f "$RULES_FILE" ]; then
  echo "architecture-debt lint: rules file not found: $RULES_FILE" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_arch_lint.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

matches_file="$tmp_dir/matches.tsv"
findings="$tmp_dir/findings.tsv"
stale="$tmp_dir/stale.tsv"
baseline="$tmp_dir/baseline.tsv"
allowlist_in="$tmp_dir/allowlist.tsv"
: > "$matches_file"
# The seed line keeps this file non-empty. The join below distinguishes the two
# inputs with `FNR == NR`, which silently reads the SECOND file as the first
# when the first has no records at all -- an empty allowlist would make every
# finding parse as a malformed allowlist row.
printf '# copy of %s\n' "$ALLOWLIST_FILE" > "$allowlist_in"
if [ -f "$ALLOWLIST_FILE" ]; then
  cat "$ALLOWLIST_FILE" >> "$allowlist_in"
fi

while IFS=$'\t' read -r rule_id severity scope pattern message issue rest; do
  case "$rule_id" in
    ""|\#*) continue ;;
  esac
  if [ -n "${rest:-}" ] || [ -z "${issue:-}" ]; then
    echo "architecture-debt lint: invalid rule row for $rule_id" >&2
    exit 1
  fi
  case "$severity" in
    error|warn) ;;
    *)
      echo "architecture-debt lint: invalid severity for $rule_id: $severity" >&2
      exit 1
      ;;
  esac

  set +e
  matches="$(cd "$SCAN_ROOT" && rg --line-number --no-heading --glob "$scope" --regexp "$pattern" . 2>"$tmp_dir/rg.err")"
  rg_status=$?
  set -e
  if [ "$rg_status" -eq 1 ]; then
    continue
  fi
  if [ "$rg_status" -ne 0 ]; then
    echo "architecture-debt lint: rg failed for $rule_id" >&2
    cat "$tmp_dir/rg.err" >&2
    exit "$rg_status"
  fi

  # The match TEXT, trimmed, is the allowlist key -- not the line number. See
  # the allowlist header for why. Splitting is positional (path:line:text) so
  # that a colon inside the matched source text stays in the text.
  printf '%s\n' "$matches" | awk \
    -v sev="$severity" -v rid="$rule_id" -v msg="$message" -v iss="$issue" '
      {
        if ($0 == "") next
        p = index($0, ":")
        if (p == 0) next
        path = substr($0, 1, p - 1)
        rest = substr($0, p + 1)
        q = index(rest, ":")
        if (q == 0) next
        line = substr(rest, 1, q - 1)
        text = substr(rest, q + 1)
        sub(/^\.\//, "", path)
        gsub(/\t/, " ", text)
        gsub(/^ +| +$/, "", text)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sev, rid, path, line, msg, iss, text
      }
    ' >> "$matches_file"
done < "$RULES_FILE"

# Join matches against the allowlist. A `(rule_id, path, text)` group is allowed
# up to its recorded count; occurrences beyond it are violations, and a group
# with no entry is a violation outright.
: > "$findings"
: > "$stale"
: > "$baseline"
set +e
awk -F '\t' \
  -v viol_out="$findings" \
  -v stale_out="$stale" \
  -v baseline_out="$baseline" '
    function gkey(rid, path, text) { return rid SUBSEP path SUBSEP text }

    FNR == NR {
      if ($0 ~ /^[ \t]*$/ || $1 ~ /^#/) next
      if (NF == 3 && $3 == "*") { wide[$1 SUBSEP $2] = 1; next }
      if (NF == 4 && $3 ~ /^[0-9]+$/) {
        allow[gkey($1, $2, $4)] = $3 + 0
        next
      }
      printf("architecture-debt lint: bad allowlist row at line %d: %s\n", FNR - 1, $0) > "/dev/stderr"
      printf("  rows are `rule_id<TAB>path<TAB>*` or `rule_id<TAB>path<TAB>count<TAB>text`.\n") > "/dev/stderr"
      printf("  line-number keys were removed in #1729 -- they went stale on every edit above them.\n") > "/dev/stderr"
      bad = 1
      next
    }

    {
      sev = $1; rid = $2; path = $3; line = $4; msg = $5; iss = $6; text = $7
      if ((rid SUBSEP path) in wide) next
      k = gkey(rid, path, text)
      seen[k] += 1
      g_sev[k] = sev
      if (seen[k] <= allow[k]) next
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sev, rid, path, line, msg, iss, text > viol_out
    }

    END {
      if (bad) exit 3
      for (k in allow) {
        if (allow[k] > seen[k]) {
          split(k, parts, SUBSEP)
          printf "%s\t%s\t%d\t%d\t%s\n", parts[1], parts[2], allow[k], seen[k], parts[3] > stale_out
        }
      }
      # Only `error` groups are baselined. Writing `warn` groups here would
      # silence the very rules whose job is to stay visible and countable.
      for (k in seen) {
        if (g_sev[k] != "error") continue
        split(k, parts, SUBSEP)
        printf "%s\t%s\t%d\t%s\n", parts[1], parts[2], seen[k], parts[3] > baseline_out
      }
    }
  ' "$allowlist_in" "$matches_file"
join_status=$?
set -e
if [ "$join_status" -ne 0 ]; then
  echo "architecture-debt lint: allowlist is unusable, refusing to report" >&2
  exit 1
fi

if [ "$update_mode" -eq 1 ]; then
  # Regenerate only below the marker; hand-written notes and file-wide `*`
  # exceptions above it are preserved verbatim.
  new_allowlist="$tmp_dir/allowlist.new"
  existing="$tmp_dir/allowlist.existing"
  : > "$existing"
  [ -f "$ALLOWLIST_FILE" ] && cat "$ALLOWLIST_FILE" > "$existing"
  if grep -Fqx "$BASELINE_MARKER" "$existing"; then
    awk -v marker="$BASELINE_MARKER" '$0 == marker { exit } { print }' "$existing" > "$new_allowlist"
  else
    cat "$existing" > "$new_allowlist"
    printf '\n' >> "$new_allowlist"
  fi
  printf '%s\n' "$BASELINE_MARKER" >> "$new_allowlist"
  LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k4,4 "$baseline" >> "$new_allowlist"
  if [ -f "$ALLOWLIST_FILE" ] && cmp -s "$new_allowlist" "$ALLOWLIST_FILE"; then
    echo "architecture-debt lint: baseline already current"
    exit 0
  fi
  cat "$new_allowlist" > "$ALLOWLIST_FILE"
  echo "architecture-debt lint: baseline updated ($(wc -l < "$baseline" | tr -d ' ') entries)"
  exit 0
fi

if [ -s "$stale" ]; then
  # Not a failure: a change that REMOVES debt should not be forced to also
  # update the baseline. But the entry is now covering nothing, so say so --
  # a ratchet that only ever loosens is not a ratchet.
  while IFS=$'\t' read -r rule_id rel_path allowed actual text; do
    printf 'architecture-debt lint: stale allowlist entry (%s %s: allows %s, found %s): %s\n' \
      "$rule_id" "$rel_path" "$allowed" "$actual" "$text" >&2
  done < "$stale"
  echo "architecture-debt lint: run \`bash scripts/lint_architecture_debt.sh --update\` to tighten the baseline" >&2
fi

if [ ! -s "$findings" ]; then
  echo "architecture-debt lint: ok"
  exit 0
fi

# `warn` is a standing REPORT of shapes worth a second look; only `error`
# fails the run. Before this both severities exited 1, so `warn` was parsed
# and validated but behaved identically to `error` -- a declaration nobody
# read, which is the same class of defect several of these rules look for.
#
# The split is what makes a rule adoptable. A shape with dozens of existing
# matches cannot start as `error` (the allowlist would need an entry per line
# and would churn on every edit above one), and a fatal warn just gets the
# whole lint switched off. A rule starts as `warn`, its matches get fixed or
# justified, and it is promoted to `error` once the count reaches zero.
error_count=0
warn_count=0
while IFS=$'\t' read -r severity rule_id rel_path line_no message issue text; do
  printf '%s:%s: %s %s: %s (%s)\n' \
    "$rel_path" "$line_no" "$severity" "$rule_id" "$message" "$issue" >&2
  printf '  %s\n' "$text" >&2
  if [ "$severity" = "error" ]; then
    error_count=$((error_count + 1))
  else
    warn_count=$((warn_count + 1))
  fi
done < "$findings"

if [ "$error_count" -gt 0 ]; then
  echo "architecture-debt lint: found new violations ($error_count error, $warn_count warn)" >&2
  exit 1
fi
echo "architecture-debt lint: ok ($warn_count warn -- review, not a failure)"
exit 0
