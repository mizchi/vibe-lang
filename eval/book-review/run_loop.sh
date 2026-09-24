#!/usr/bin/env bash
# Chapter loop and full-read loop for the book-review rubric.
#
#   bash eval/book-review/run_loop.sh check [chapter_id]
#   bash eval/book-review/run_loop.sh status
#   bash eval/book-review/run_loop.sh blob <chapter_id>
#   bash eval/book-review/run_loop.sh pass [--record]
#
# check exits 1 when a chapter's English/Japanese pair has a broken
# relative link, a ```vibe run without ```output, a ```vibe skip whose
# first line is not `// skip`, or fence counts that differ across the
# pair. status always exits 0. pass exits 2 until every chapter has a
# current score on prose_fidelity and surface_agreement, and exits 1
# when check would fail. It does not average a missing chapter in as 5.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$ROOT/eval/book-review/loop.py" "$@"
