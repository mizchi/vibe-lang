///|
/// Tests for the wasm `name` custom section in the linear backend.
/// Mirrors `wasm_gc_name_section_wbtest.mbt` — same encoding, different
/// codegen path. Without this section every frame in profiler /
/// devtools renders as `<wasm function N>`.

///|
/// Parse out the function-name map from a wasm binary's `name`
/// custom section (subsection 1). Returns the (idx, name) pairs.
fn linear_parse_function_names(bytes : Bytes) -> Array[(Int, String)] {
  let view : Array[Int] = []
  for b in bytes {
    view.push(b.to_int())
  }
  let mut i = 8
  while i < view.length() {
    let id = view[i]
    i += 1
    let mut size = 0
    let mut shift = 0
    let mut continues = true
    while continues {
      let b = view[i]
      i += 1
      size = size | ((b & 0x7f).lsl(shift))
      shift += 7
      continues = (b & 0x80) != 0
    }
    let payload_end = i + size
    if id == 0 {
      let mut name_size = 0
      let mut ns_shift = 0
      let mut ns_continues = true
      while ns_continues {
        let b = view[i]
        i += 1
        name_size = name_size | ((b & 0x7f).lsl(ns_shift))
        ns_shift += 7
        ns_continues = (b & 0x80) != 0
      }
      let mut name = ""
      for k in 0..<name_size {
        name = name + Char::from_int(view[i + k]).to_string()
      }
      i += name_size
      if name == "name" {
        while i < payload_end {
          let sub_id = view[i]
          i += 1
          let mut sub_size = 0
          let mut ss_shift = 0
          let mut ss_continues = true
          while ss_continues {
            let b = view[i]
            i += 1
            sub_size = sub_size | ((b & 0x7f).lsl(ss_shift))
            ss_shift += 7
            ss_continues = (b & 0x80) != 0
          }
          if sub_id == 1 {
            let mut p = i
            let mut count = 0
            let mut cs = 0
            let mut cc = true
            while cc {
              let b = view[p]
              p += 1
              count = count | ((b & 0x7f).lsl(cs))
              cs += 7
              cc = (b & 0x80) != 0
            }
            let out : Array[(Int, String)] = []
            for _ in 0..<count {
              let mut idx = 0
              let mut isz = 0
              let mut ic = true
              while ic {
                let b = view[p]
                p += 1
                idx = idx | ((b & 0x7f).lsl(isz))
                isz += 7
                ic = (b & 0x80) != 0
              }
              let mut n_len = 0
              let mut nls = 0
              let mut nc = true
              while nc {
                let b = view[p]
                p += 1
                n_len = n_len | ((b & 0x7f).lsl(nls))
                nls += 7
                nc = (b & 0x80) != 0
              }
              let mut nm = ""
              for k in 0..<n_len {
                nm = nm + Char::from_int(view[p + k]).to_string()
              }
              p += n_len
              out.push((idx, nm))
            }
            return out
          }
          i += sub_size
        }
        return []
      }
      i = payload_end
    } else {
      i = payload_end
    }
  }
  []
}

///|
test "linear emit_module_wasm includes a name section with _start and __vibe_run" {
  // Mirrors the structure used elsewhere in capture_env_wbtest.mbt: a
  // tiny user function + the synthesised run wrapper. Both should be
  // labelled so wasmtime --profile=guest shows them by name.
  let helper_fn = wb_fn([wb_param("n")], [wb_expr(wb_ident("n"))])
  let run_fn = wb_fn([], [wb_expr(wb_call("helper", [wb_int(7L)]))])
  let ast = @core.Module::{
    stmts: [wb_let("helper", helper_fn), wb_let("run", run_fn)],
  }
  let bytes = try! emit_module_wasm(ast)
  let names = linear_parse_function_names(bytes)
  let mut has_start = false
  let mut has_run = false
  for entry in names {
    let (_, n) = entry
    if n == "_start" {
      has_start = true
    }
    if n == "__vibe_run" {
      has_run = true
    }
  }
  @debug.assert_eq(has_start, true)
  @debug.assert_eq(has_run, true)
}
