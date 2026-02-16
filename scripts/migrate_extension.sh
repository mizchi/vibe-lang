#!/usr/bin/env bash
set -euo pipefail

FROM_EXT=".vibe"
TO_EXT=".vibe"
APPLY=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/migrate_extension.sh [options]

Options:
  --from <ext>   source extension (default: .vibe)
  --to <ext>     destination extension (default: .vibe)
  --apply        perform git mv and in-file replacements
  --dry-run      print planned changes without modifying files
  -h, --help     show help

Notes:
  - Works only on git-tracked files.
  - Replaces extension literals in tracked files (e.g. ".vibe" -> target ext).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      FROM_EXT="${2:-}"
      shift 2
      ;;
    --to)
      TO_EXT="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${FROM_EXT:0:1}" != "." ]]; then
  echo "--from must start with '.'" >&2
  exit 1
fi

if [[ -n "$TO_EXT" && "${TO_EXT:0:1}" != "." ]]; then
  echo "--to must start with '.' or be empty" >&2
  exit 1
fi

if [[ $APPLY -eq 0 && $DRY_RUN -eq 0 ]]; then
  echo "Specify either --dry-run or --apply." >&2
  exit 1
fi

mapfile -d '' tracked_renames < <(git ls-files -z -- "*${FROM_EXT}")

rename_count=0
for old in "${tracked_renames[@]}"; do
  new="${old%$FROM_EXT}${TO_EXT}"
  if [[ "$old" == "$new" ]]; then
    continue
  fi
  rename_count=$((rename_count + 1))
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "mv: $old -> $new"
  else
    if [[ -e "$new" ]]; then
      echo "target already exists: $new" >&2
      exit 1
    fi
    git mv "$old" "$new"
  fi
done

mapfile -d '' files_with_refs < <(git grep -z -l -- "$FROM_EXT" -- .)

replace_count=0
for file in "${files_with_refs[@]}"; do
  replace_count=$((replace_count + 1))
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "edit: $file"
  else
    FROM_EXT="$FROM_EXT" TO_EXT="$TO_EXT" perl -0777 -i -pe '
      my $from = $ENV{FROM_EXT};
      my $to = $ENV{TO_EXT};
      s/\Q$from\E(?=$|[^A-Za-z0-9_])/$to/g;
    ' "$file"
  fi
done

echo "renamed_files=$rename_count"
echo "edited_files=$replace_count"
