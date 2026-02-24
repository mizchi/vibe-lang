///|
/// Deno FFI: detect if running under Deno runtime
extern "js" fn js_is_deno() -> Bool =
  #| function() {
  #|   return typeof Deno !== 'undefined';
  #| }

///|
/// Deno FFI: check if stdin has reached EOF (set by js_deno_read_line)
extern "js" fn js_deno_stdin_eof() -> Bool =
  #| function() {
  #|   return globalThis.__deno_stdin_eof === true;
  #| }

///|
/// Deno FFI: read one line from stdin synchronously (byte-by-byte).
/// Sets EOF flag readable via js_deno_stdin_eof().
extern "js" fn js_deno_read_line() -> String =
  #| function() {
  #|   globalThis.__deno_stdin_eof = false;
  #|   const buf = new Uint8Array(1);
  #|   const chars = [];
  #|   while (true) {
  #|     const n = Deno.stdin.readSync(buf);
  #|     if (n === null || n === 0) { globalThis.__deno_stdin_eof = true; break; }
  #|     if (buf[0] === 10) break;
  #|     if (buf[0] === 13) continue;
  #|     chars.push(buf[0]);
  #|   }
  #|   return new TextDecoder().decode(new Uint8Array(chars));
  #| }

///|
/// Deno FFI: write string to stdout synchronously
extern "js" fn js_deno_write(s : String) -> Unit =
  #| function(s) {
  #|   Deno.stdout.writeSync(new TextEncoder().encode(s));
  #| }

///|
/// Deno FFI: get current working directory
extern "js" fn js_deno_cwd() -> String =
  #| function() {
  #|   return Deno.cwd();
  #| }

///|
/// Deno FFI: read text file synchronously, returns "" on error
extern "js" fn js_deno_read_text_file(path : String) -> String =
  #| function(path) {
  #|   try { return Deno.readTextFileSync(path); }
  #|   catch (_) { return ""; }
  #| }

///|
/// Deno FFI: write text file synchronously
extern "js" fn js_deno_write_text_file(path : String, s : String) -> Unit =
  #| function(path, s) {
  #|   Deno.writeTextFileSync(path, s);
  #| }

///|
/// Deno FFI: mkdir -p (recursive)
extern "js" fn js_deno_mkdir_p(path : String) -> Unit =
  #| function(path) {
  #|   try { Deno.mkdirSync(path, { recursive: true }); }
  #|   catch (_) {}
  #| }

///|
/// Deno FFI: check if file exists
extern "js" fn js_deno_file_exists(path : String) -> Bool =
  #| function(path) {
  #|   try { Deno.statSync(path); return true; }
  #|   catch (_) { return false; }
  #| }

///|
fn deno_short_hash(hash : String) -> String {
  if hash.length() <= 7 {
    hash
  } else {
    hash.unsafe_substring(start=0, end=7)
  }
}

///|
fn deno_print_eval_result(result : @runtime.EvalResult) -> Unit {
  match result.last {
    Some(value) => println("last: " + value.to_string())
    None => ()
  }
  for effect in result.effects {
    match effect {
      @runtime.Effect::PosixDesugar(message) => println("note: " + message)
      _ => println("effect: " + effect.to_string())
    }
  }
}

///|
fn deno_append_eval_db_source(base_source : String, expr : String) -> String {
  let trimmed = expr.trim().to_string()
  if trimmed.length() == 0 {
    return base_source
  }
  let out = StringBuilder::new()
  if base_source.length() > 0 {
    out.write_string(base_source)
    if not(base_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string(trimmed)
  if not(trimmed.has_suffix("\n")) {
    out.write_char('\n')
  }
  out.to_string()
}

///|
fn deno_write_eval_db_source(path : String, source : String) -> Unit {
  let parent = @vibe_fs.parent_path(path)
  if parent.length() > 0 && parent != "." {
    js_deno_mkdir_p(parent)
  }
  js_deno_write_text_file(path, source)
}

///|
fn deno_print_ai_symbols(path : String, source : String) -> Unit {
  if source.trim().to_string().length() == 0 {
    return
  }
  let db = @runtime.VibeDb::new()
  db.set_source(path, source)
  let index = @runtime.build_symbol_index(db, [path])
  let mut has_symbols = false
  for entry in index.entries {
    if entry.path == path {
      has_symbols = true
      break
    }
  }
  if has_symbols {
    println("symbols:")
    for entry in index.entries {
      if entry.path != path {
        continue
      }
      println(
        "  " +
        @frontend.symbol_kind_name(entry.kind) +
        "\t" +
        entry.name +
        "\t" +
        entry.signature,
      )
    }
  }
}

///|
fn repl_deno_cmd(args : Array[String]) -> Unit {
  let mut ai_mode = false
  let mut prompt_enabled = true
  let mut enable_llm = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--ai" => {
        ai_mode = true
        i += 1
      }
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "--llm" => {
        enable_llm = true
        i += 1
      }
      _ => abort("shell: unknown arg " + args[i])
    }
  }
  let syntax_mode = @runtime.ParserMode::VibeMode
  let features = @runtime.RuntimeFeatureFlags::new(false, false)
  let caps = if enable_llm {
    @capability.CapabilitySet::developer()
    .add(@capability.Capability::llm_call(["*"]))
    .add(@capability.Capability::net_connect("*", None))
  } else {
    @capability.CapabilitySet::developer()
  }
  let rt = @runtime.Runtime::new_with_features(caps, features)
  let cwd = js_deno_cwd()
  let ns_name = "scratch"
  let scratch_db_path = @vibe_fs.normalize_path(
    cwd + "/.vibe/namespaces/scratch.db",
  )
  let mut scratch_source = ""
  if js_deno_file_exists(scratch_db_path) {
    scratch_source = js_deno_read_text_file(scratch_db_path)
  }
  if scratch_source.trim().length() > 0 {
    try rt.eval_script_with_mode(scratch_source, syntax_mode) |> ignore catch {
      e => println("warn: failed to restore db: " + e.to_string())
    }
  }
  // header
  println("cwd: " + cwd)
  println("namespace: " + ns_name + " db=" + scratch_db_path)
  deno_print_ai_symbols(scratch_db_path, scratch_source)
  let prompt = if ai_mode { "> " } else { "vibe> " }
  if prompt_enabled {
    js_deno_write(prompt)
  }
  // REPL loop
  while true {
    let line = js_deno_read_line()
    if js_deno_stdin_eof() {
      break
    }
    let trimmed = line.trim().to_string()
    if trimmed.length() == 0 {
      if prompt_enabled {
        js_deno_write(prompt)
      }
      continue
    }
    match trimmed {
      ":q" | ":quit" | ":exit" | "exit" => break
      _ => {
        let result = rt.eval_script_with_mode(trimmed, syntax_mode) catch {
          e => {
            println("error: " + e.to_string())
            if prompt_enabled {
              js_deno_write(prompt)
            }
            continue
          }
        }
        deno_print_eval_result(result)
        let let_name = extract_let_name(trimmed)
        match let_name {
          Some(name) =>
            match rt.get_addr(name) {
              Some(addr) =>
                println("addr: " + name + "#" + deno_short_hash(addr))
              None => ()
            }
          None => ()
        }
        scratch_source = deno_append_eval_db_source(scratch_source, trimmed)
        deno_write_eval_db_source(scratch_db_path, scratch_source)
        if let_name is Some(_) {
          deno_print_ai_symbols(scratch_db_path, scratch_source)
        }
      }
    }
    if prompt_enabled {
      js_deno_write(prompt)
    }
  }
}
