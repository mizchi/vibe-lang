///|
/// Self-contained compile harness for moon-pprof (#402). Compiles an
/// embedded known-good source (base64.vibe) in-memory in a loop so a
/// sampling profiler captures the compile hot path. No fs / args.
let harness_source : String =
  #|
  #|let table: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  #|let to_b64: (Int) -> String = (i) -> {
  #|  String::substring(table, i, i + 1)
  #|}
  #|let encode_pair: (Int, Int) -> String = (a, b) -> {
  #|  let c0 = to_b64(a / 4)
  #|  let x1 = a % 4 * 16
  #|  let y1 = b / 16
  #|  let c1 = to_b64(x1 + y1)
  #|  let c2 = to_b64(b % 16 * 4)
  #|  String::concat(String::concat(String::concat(c0, c1), c2), "=")
  #|}
  #|let encode_single: (Int) -> String = (a) -> {
  #|  let c0 = to_b64(a / 4)
  #|  let c1 = to_b64(a % 4 * 16)
  #|  String::concat(String::concat(c0, c1), "==")
  #|}
  #|let encode_triplet: (Int, Int, Int) -> String = (a, b, c) -> {
  #|  let c0 = to_b64(a / 4)
  #|  let x1 = a % 4 * 16
  #|  let y1 = b / 16
  #|  let c1 = to_b64(x1 + y1)
  #|  let x2 = b % 16 * 4
  #|  let y2 = c / 64
  #|  let c2 = to_b64(x2 + y2)
  #|  let c3 = to_b64(c % 64)
  #|  String::concat(String::concat(String::concat(c0, c1), c2), c3)
  #|}
  #|let rec enc_loop: (String, Int, String) -> String = (s, i, out) -> {
  #|  let len = String::length(s)
  #|  if i + 3 <= len {
  #|    let j = i + 1
  #|    let k = i + 2
  #|    let a = String::char_code_at(s, i)
  #|    let b = String::char_code_at(s, j)
  #|    let c = String::char_code_at(s, k)
  #|    enc_loop(s, i + 3, String::concat(out, encode_triplet(a, b, c)))
  #|  } else if i + 2 <= len {
  #|    let j = i + 1
  #|    let a = String::char_code_at(s, i)
  #|    let b = String::char_code_at(s, j)
  #|    String::concat(out, encode_pair(a, b))
  #|  } else if i + 1 <= len {
  #|    let a = String::char_code_at(s, i)
  #|    String::concat(out, encode_single(a))
  #|  } else {
  #|    out
  #|  }
  #|}
  #|export let encode: (String) -> String = (s) -> {
  #|  enc_loop(s, 0, "")
  #|}
  #|test "encode 3 bytes" {
  #|  assert(String::equals(encode("Man"), "TWFu"))
  #|}
  #|test "encode 2 bytes padding" {
  #|  assert(String::equals(encode("Ma"), "TWE="))
  #|}
  #|test "encode 1 byte padding" {
  #|  assert(String::equals(encode("M"), "TQ=="))
  #|}
  #|test "encode empty" {
  #|  assert(String::equals(encode(""), ""))
  #|}
  #|test "encode longer string" {
  #|  assert(String::equals(encode("Hello World"), "SGVsbG8gV29ybGQ="))
  #|}
  #|test "encode example" {
  #|  assert(String::equals(encode("Man"), "TWFu"))
  #|}

///|
fn main {
  let iters = 1500
  let mut acc = 0
  for i in 0..<iters {
    // Vary BOTH the module path and the source content each iteration so the
    // global compile_module_cache (path-keyed) and wasm_artifact_cache
    // (content-keyed) in runtime_compile miss every time — otherwise iterations
    // 2..N would be cache hits and the samples would describe the cache-hit
    // path instead of a fresh compile. The appended `//` line is an inert
    // comment; the prelude/builtin caches (keyed on prelude source) stay warm,
    // matching production where each user file compiles fresh against a warm
    // standard library.
    let path = "m" + i.to_string()
    let db = @runtime.VibeDb::new()
    db.set_source(path, harness_source + "\n// iter " + i.to_string())
    // Abort on failure rather than swallowing it — a silent b"" would profile
    // the error/recovery path and hide a broken embedded source.
    let wasm = @runtime_compile.compile_module_wasm_with_opt_level(
      db,
      path,
      no_dce=true,
    ) catch {
      e => abort("harness compile failed: " + e.to_string())
    }
    acc = acc + wasm.length()
  }
  println("compiled bytes acc=" + acc.to_string())
}
