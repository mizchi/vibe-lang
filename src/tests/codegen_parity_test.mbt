///|
/// Registry-driven codegen parity gate (#415, Phase B-1).
///
/// The linear and wasm-gc backends implement builtins in two parallel
/// dispatchers (`src/codegen/wasm_codegen_builtin_*.mbt` and
/// `src/codegen/wasm_gc_codegen.mbt`). This test scans both backends'
/// source for builtin name literals, computes the core-namespace
/// divergences, and requires every divergence to be declared in
/// `@codegen.builtins()` with a `DivergenceReason`.
///
/// Adding a builtin to one backend without the other (the silent-
/// regression failure mode that motivated `scripts/check_codegen_parity.sh`)
/// fails here unless it is recorded in the registry table. This makes the
/// typed registry the single source of truth, replacing the old text
/// allowlist (`scripts/codegen_parity_allowlist.txt`).

///|
fn pq_is_alpha(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

///|
fn pq_is_ident(c : Char) -> Bool {
  pq_is_alpha(c) || (c >= '0' && c <= '9') || c == '_'
}

///|
fn pq_is_lower_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || c == '_'
}

///|
fn pq_is_lower_ident(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

///|
/// Collect every `"Namespace::method"` literal (matching the grep pattern
/// `"[A-Za-z][A-Za-z_0-9]*::[a-z_][a-z_0-9]*"` used by the shell report)
/// into `into`.
fn pq_extract_names(content : String, into : Map[String, Unit]) -> Unit {
  let a = content.to_array()
  let n = a.length()
  let mut i = 0
  while i < n {
    if a[i] == '"' && i + 1 < n && pq_is_alpha(a[i + 1]) {
      let mut k = i + 1
      while k < n && pq_is_ident(a[k]) {
        k = k + 1
      }
      if k + 2 < n &&
        a[k] == ':' &&
        a[k + 1] == ':' &&
        pq_is_lower_start(a[k + 2]) {
        let mut p = k + 2
        while p < n && pq_is_lower_ident(a[p]) {
          p = p + 1
        }
        if p < n && a[p] == '"' {
          into.set(String::from_array(a[i + 1:p]), ())
          i = p + 1
          continue
        }
      }
    }
    i = i + 1
  }
}

///|
/// Namespace part of a `Namespace::method` name (text before the first
/// `::`).
fn pq_namespace(name : String) -> String {
  let a = name.to_array()
  let n = a.length()
  let mut i = 0
  while i + 1 < n {
    if a[i] == ':' && a[i + 1] == ':' {
      return String::from_array(a[0:i])
    }
    i = i + 1
  }
  name
}

///|
fn pq_has(m : Map[String, Unit], k : String) -> Bool {
  m.get(k) is Some(_)
}

///|
/// Scan both backends' builtin dispatch source. Returns (linear, gc) name
/// sets. Reads from the repo root (tests run with CWD at the project root,
/// same as `fixture_test.mbt`).
fn pq_load_backends() -> (Map[String, Unit], Map[String, Unit]) raise {
  let dir = "src/codegen"
  let linear : Map[String, Unit] = Map::new()
  for entry in @os_fs.read_dir(dir) {
    if entry.has_prefix("wasm_codegen_builtin_") && entry.has_suffix(".mbt") {
      pq_extract_names(@os_fs.read_file_to_string("\{dir}/\{entry}"), linear)
    }
  }
  let gc : Map[String, Unit] = Map::new()
  pq_extract_names(@os_fs.read_file_to_string("\{dir}/wasm_gc_codegen.mbt"), gc)
  (linear, gc)
}

///|
fn pq_is_core(name : String) -> Bool {
  let core : Map[String, Unit] = Map::new()
  for
    ns in [
      "Array", "Bytes", "Map", "String", "Int", "Bool", "Char", "Double", "Float",
      "Option", "Result", "StringBuilder", "ArrayBuilder", "MapBuilder",
    ] {
    core.set(ns, ())
  }
  pq_has(core, pq_namespace(name))
}

///|
test "codegen parity: core divergences are declared in the registry" {
  let (linear, gc) = pq_load_backends()

  // Sanity: the scan must have found a meaningful number of names, or the
  // file paths / extraction are broken and the gate would silently pass.
  @debug.assert_eq(linear.size() > 50, true)
  @debug.assert_eq(gc.size() > 30, true)
  let problems : Array[String] = []

  // linear has a dedicated arm, wasm-gc does not.
  for name, _ in linear {
    if pq_is_core(name) && !pq_has(gc, name) {
      match @codegen.find_builtin(name) {
        Some(d) =>
          if !(d.has_linear && !d.has_gc) {
            problems.push(
              "\{name}: source is linear-only but registry says linear=\{d.has_linear} gc=\{d.has_gc}",
            )
          }
        None =>
          problems.push("\{name}: linear-only core divergence, not in registry")
      }
    }
  }

  // wasm-gc has a dedicated arm, linear does not.
  for name, _ in gc {
    if pq_is_core(name) && !pq_has(linear, name) {
      match @codegen.find_builtin(name) {
        Some(d) =>
          if !(!d.has_linear && d.has_gc) {
            problems.push(
              "\{name}: source is gc-only but registry says linear=\{d.has_linear} gc=\{d.has_gc}",
            )
          }
        None =>
          problems.push("\{name}: gc-only core divergence, not in registry")
      }
    }
  }
  if problems.length() > 0 {
    let mut msg =
      #|undeclared core-namespace codegen divergence(s):
      #|
    for p in problems {
      msg = msg + "  - " + p + "\n"
    }
    msg = msg +
      "Declare each in src/codegen/builtin_registry.mbt::builtins() with a " +
      "DivergenceReason, or implement the builtin in the missing backend. " +
      "See docs/spec/codegen-dual-backend.md."
    fail(msg)
  }
}

///|
test "codegen parity: registry divergence entries match backend source" {
  let (linear, gc) = pq_load_backends()
  let stale : Array[String] = []
  for decl in @codegen.builtins() {
    // Only entries that declare a divergence are cross-checked here.
    if decl.has_linear != decl.has_gc {
      let in_linear = pq_has(linear, decl.name)
      let in_gc = pq_has(gc, decl.name)
      // The backend the registry says implements it must actually have an
      // arm; the other must not (otherwise the entry is stale).
      if decl.has_linear != in_linear || decl.has_gc != in_gc {
        stale.push(
          "\{decl.name}: registry says linear=\{decl.has_linear} gc=\{decl.has_gc} but source has linear=\{in_linear} gc=\{in_gc}",
        )
      }
    }
  }
  if stale.length() > 0 {
    let mut msg =
      #|stale registry divergence entry(ies) — source no longer matches:
      #|
    for s in stale {
      msg = msg + "  - " + s + "\n"
    }
    msg = msg +
      "Update src/codegen/builtin_registry.mbt::builtins() to match the backends."
    fail(msg)
  }
}
