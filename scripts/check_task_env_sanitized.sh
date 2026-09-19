#!/usr/bin/env bash
# #2877: a `pkf` task must not inherit the nix wrapper's LD_LIBRARY_PATH.
#
# `/root/.nix-profiles/pkfire/bin/pkf` is a nix wrapper that exports
# LD_LIBRARY_PATH before exec'ing the real binary, unscoped, so every task
# inherits it. A system binary that reaches the dynamic loader then resolves
# out of the nix closure while linked against the system glibc:
#
#   sort: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_ABI_DT_X86_64_PLT'
#         not found (required by /nix/store/...-glibc-2.42-67/lib/libdl.so.2)
#
# `/usr/bin/sort` exits non-zero writing NOTHING, so a `find | sort` expansion
# comes back empty and reads as "no files matched". That is what made the
# original instance take six steps to isolate, and why this gate asserts the
# BINARY RUNS rather than just grepping the variable: an empty variable that
# some future wrapper repopulates differently would still pass a grep.
#
# `Taskfile.pkl`'s `defaults.env` clears it for every task. This gate exists
# because that row is one line in a 2000-line file with nothing else pointing
# at it, and its absence fails SILENTLY -- tasks keep running, some of them
# just stop seeing their own inputs.
set -euo pipefail
ROOT_DIR="${VIBE_TASK_ENV_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

PKF="${VIBE_TASK_ENV_PKF:-pkf}"
out="$("$PKF" run check-task-env 2>&1)" || true

# 1. The canary binary must actually run. This is the property; everything
#    below is diagnosis.
if ! printf '%s\n' "$out" | grep -q 'task-env: sort ok'; then
  echo "[task-env] FAIL: a system binary does not run inside a pkf task (#2877)" >&2
  echo "  LD_LIBRARY_PATH leaking from the nix wrapper breaks the dynamic loader;" >&2
  echo "  the symptom is empty output and a non-zero status, not a named cause." >&2
  echo "  Fix: keep the LD_LIBRARY_PATH row in Taskfile.pkl's \`defaults.env\`." >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# 2. And the variable itself must carry no nix store path, so the next system
#    binary nobody thought to canary is safe too.
leaked="$(printf '%s\n' "$out" | sed -n 's/^task-env: LD_LIBRARY_PATH=//p')"
case "$leaked" in
  *"/nix/store/"*)
    echo "[task-env] FAIL: a pkf task inherits a nix store path in LD_LIBRARY_PATH (#2877)" >&2
    echo "  got: $leaked" >&2
    echo "  Fix: keep the LD_LIBRARY_PATH row in Taskfile.pkl's \`defaults.env\`." >&2
    exit 1
    ;;
esac

echo "[task-env] ok (a pkf task inherits no nix store path; a system binary runs)"
