#!/usr/bin/env bash
# `vibe pkg` runs each subcommand with only the host imports it is granted
# (#3673), and the grant is enforced by the host, not by an effect row:
#
#   bash scripts/test_pkg_authority.sh <stage2.wasm>
#
# 1. The CLI states a grant per subcommand (`pkg authority <sub>`), and the
#    statement is complete: every `vibe.*` import the CLI wasm declares, and
#    every one the compiler can emit, is a field the table knows. A field it
#    did not know would stay linked for every subcommand.
# 2. The grants are the ones documented: `spec` touches no file (only the
#    CLI's own working-directory read), the store subcommands get `Fs`, and no
#    subcommand gets stdin, a process beyond its exit status, the network or
#    the profiler.
# 3. The launcher applies it: every pkg call reaches the runner with the
#    subcommand's withheld set in VIBE_HOST_WITHHOLD.
# 4. Sufficient: publish and install succeed with their grant in force.
# 5. Enforced: withholding one more import a subcommand needs makes it fail,
#    naming that import; and a compiler that cannot state the grant is refused
#    rather than run with its full authority.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${1:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "usage: test_pkg_authority.sh <stage2.wasm>" >&2; exit 2; }
case "$CLI" in /*) ;; *) CLI="$ROOT_DIR/$CLI" ;; esac
unset VIBE_HOST_WITHHOLD || true

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-pkg-authority.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[pkg-authority] FAIL $*" >&2; exit 1; }

# A runner that records the withheld set each CLI call ran under, then runs it.
cat > "$WORK/recording_runner.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${VIBE_HOST_WITHHOLD:-}" >> "$WORK/withheld.log"
exec bash "$ROOT_DIR/scripts/viberun_node.sh" "\$@"
EOF
chmod +x "$WORK/recording_runner.sh"
vibe_pkg() {
  VIBE_RUNNER="$WORK/recording_runner.sh" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" pkg "$@"
}
authority_row() { # <sub> <row>
  VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" pkg authority "$1" | awk -F'\t' -v r="$2" '$1 == r { print $2 }'
}
has() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

emitted_import_names() {
  grep -Eho 'emit_name\((buf[[:space:]]*=[[:space:]]*)?import_content,[[:space:]]*(name[[:space:]]*=[[:space:]]*)?"[^"]*"\)' "$1" \
    | sed 's/^[^"]*"//; s/".*$//' | sort -u | grep -vx 'vibe\|wasi_snapshot_preview1\|fd_write'
}

# Both call spellings name imports. A different buffer or parameter does not.
cat > "$WORK/emitter-probe.vibe" <<'EOF'
emit_name(import_content, "positional_probe")
emit_name(buf = import_content, name = "named_probe")
emit_name(buf = export_content, name = "wrong_buffer")
emit_name(buf = import_content, other = "wrong_parameter")
EOF
probe_emitted="$(emitted_import_names "$WORK/emitter-probe.vibe")" \
  || fail "the import-name extractor rejected its valid probes"
[ "$probe_emitted" = $'named_probe\npositional_probe' ] \
  || fail "the import-name extractor missed a call spelling or accepted the wrong buffer/parameter"

# --- 1. the table knows every import ----------------------------------------
known="$(authority_row spec known)"
[ -n "$known" ] || fail "pkg authority names no known imports"
python3 - "$CLI" "$known" <<'PY' || fail "the CLI wasm imports a vibe.* field the authority table does not know"
import sys
b = open(sys.argv[1], "rb").read()
known = set(sys.argv[2].split(","))
def uleb(i):
    r = s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7F) << s
        if not x & 0x80: return r, i
        s += 7
i, unknown = 8, []
while i < len(b):
    sid = b[i]; i += 1
    size, i = uleb(i); end = i + size
    if sid == 2:
        n, j = uleb(i)
        for _ in range(n):
            ml, j = uleb(j); mod = b[j:j + ml].decode(); j += ml
            fl, j = uleb(j); field = b[j:j + fl].decode(); j += fl
            kind = b[j]; j += 1
            if kind == 0: _, j = uleb(j)
            elif kind == 1:
                j += 1; flags = b[j]; j += 1; _, j = uleb(j)
                if flags & 1: _, j = uleb(j)
            elif kind == 2:
                flags = b[j]; j += 1; _, j = uleb(j)
                if flags & 1: _, j = uleb(j)
            elif kind == 3: j += 2
            if mod == "vibe" and field not in known: unknown.append(field)
    i = end
if unknown:
    print("  unknown: " + ", ".join(unknown), file=sys.stderr)
    sys.exit(1)
PY
emitted="$(emitted_import_names lib/@vibe/compiler/codegen/wasi/linked_compile_module_sections.vibe)" \
  || fail "could not extract emitted import names (the emitter moved?)"
[ -n "$emitted" ] || fail "found no emitted import names (the emitter moved?)"
for f in $emitted; do
  has "$known" "$f" || fail "the compiler can emit vibe.$f, which the authority table does not know"
done

# --- 2. the stated grants ----------------------------------------------------
spec_grant="$(authority_row spec grant)"
for f in fs_read_file fs_write_file fs_read_dir_nul fs_remove_tree; do
  has "$spec_grant" "$f" && fail "spec is granted $f"
done
has "$spec_grant" fs_getcwd || fail "spec lost the CLI's own working-directory read"
for sub in publish install add-fetched fetch-pins yank update; do
  g="$(authority_row "$sub" grant)"
  for f in fs_read_file fs_write_file fs_mkdir_p; do has "$g" "$f" || fail "$sub is not granted $f"; done
done
for sub in spec publish install add-fetched fetch-pins yank update nonsense; do
  w="$(authority_row "$sub" withhold)"
  for f in stdin_read_char stdin_read_stream sh sh_capture http_request tcp_connect profile-now-us; do
    has "$w" "$f" || fail "$sub does not withhold $f"
  done
done

# --- 3 and 4. applied, and sufficient ----------------------------------------
pkg_home="$WORK/home"
src="$pkg_home/src/@auth3673/mathx"
mkdir -p "$src"
printf 'name = @auth3673/mathx\nversion = 1.0.0\n\nfn quad(x: Int) -> Int\n' > "$src/index.vpkg"
printf 'export fn quad(x: Int) -> Int { x * 4 }\n' > "$src/impl.vibe"
: > "$WORK/withheld.log"
VIBE_HOME="$pkg_home" vibe_pkg spec github:a/b@main > "$WORK/spec.out" 2>&1 || { cat "$WORK/spec.out" >&2; fail "spec failed under its grant"; }
grep -q $'^url\thttps://github.com/a/b.git$' "$WORK/spec.out" || fail "spec printed: $(cat "$WORK/spec.out")"
spec_withheld="$(sed -n '2p' "$WORK/withheld.log")"
has "$spec_withheld" fs_read_file || fail "spec ran without fs_read_file withheld (got: $spec_withheld)"
: > "$WORK/withheld.log"
VIBE_HOME="$pkg_home" vibe_pkg publish "$src" > "$WORK/pub.out" 2>&1 || { cat "$WORK/pub.out" >&2; fail "publish failed under its grant"; }
pub_withheld="$(sed -n '2p' "$WORK/withheld.log")"
has "$pub_withheld" stdin_read_char || fail "publish ran without stdin withheld (got: $pub_withheld)"
has "$pub_withheld" fs_write_file && fail "publish ran with fs_write_file withheld"
VIBE_HOME="$pkg_home" vibe_pkg install @auth3673/mathx@1.0.0 > "$WORK/inst.out" 2>&1 || { cat "$WORK/inst.out" >&2; fail "install failed under its grant"; }
[ -f "$pkg_home/lib/@auth3673/mathx/index.vpkg" ] || fail "install materialized nothing"

# --- 5. enforced --------------------------------------------------------------
rm -rf "$pkg_home/lib/@auth3673"
status=0
VIBE_HOST_WITHHOLD=fs_copy VIBE_HOME="$pkg_home" vibe_pkg install @auth3673/mathx@1.0.0 > "$WORK/denied.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "install succeeded with fs_copy withheld"
grep -q 'capability withheld: fs_copy' "$WORK/denied.out" || { cat "$WORK/denied.out" >&2; fail "the refusal does not name fs_copy"; }
seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
if [ -s "$seed" ] && ! VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$seed" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" pkg authority spec >/dev/null 2>&1; then
  status=0
  VIBE_RUNNER="$ROOT_DIR/scripts/viberun_node.sh" VIBE_CLI_WASM="$seed" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" pkg spec github:a/b@main > "$WORK/old.out" 2>&1 || status=$?
  [ "$status" != 0 ] || fail "a compiler without 'pkg authority' ran 'pkg spec' anyway"
  grep -q 'does not state the authority' "$WORK/old.out" || { cat "$WORK/old.out" >&2; fail "the refusal of an old compiler does not say why"; }
fi

echo "[pkg-authority] ok (grants stated and complete; spec has no file access; applied per call; publish/install sufficient; a withheld import and an old compiler refused)"
