///| RLM (Recursive Language Models) loop for vibe runtime

///|
pub(all) struct RlmBudget {
  mut steps_used : Int
  max_steps : Int
  mut depth : Int
  max_depth : Int
}

///|
pub fn RlmBudget::default() -> RlmBudget {
  { steps_used: 0, max_steps: 32, depth: 0, max_depth: 4 }
}

///|
fn RlmBudget::check(self : RlmBudget) -> String? {
  if self.steps_used >= self.max_steps {
    Some("budget exceeded: max_steps=" + self.max_steps.to_string())
  } else if self.depth >= self.max_depth {
    Some("budget exceeded: max_depth=" + self.max_depth.to_string())
  } else {
    None
  }
}

///|
fn rlm_system_prompt() -> String {
  let syntax =
    #|## Vibe Language Syntax
    #|
    #|### Bindings
    #|- `let x = expr` immutable binding
    #|- `let mut x = expr` mutable binding (reassign with `x = new_val`)
    #|- `let x: Type = expr` with type annotation
    #|- `let rec f = (n: Int) -> Int { if n < 2 { 1 } else { n * f(n - 1) } }` recursive function
    #|
    #|### Functions
    #|- Named: `let add = (a: Int, b: Int) -> Int { a + b }`
    #|- Generic: `let id = [T](x: T) -> T { x }`
    #|- Lambda: `fn(x) { x + 1 }` or `(x: Int) -> x + 1`
    #|- Last expression is the return value (no `return` keyword)
    #|
    #|### Control Flow
    #|- `if cond { expr } else { expr }`
    #|- `while cond { body }`
    #|- `for x in arr { body }` / `for i, x in arr { body }` (`iter_require` + `iter_length` / `iter_get` protocol。現状 `Iterable` は prelude 側で Array 実装のみ有効)
    #|- `match value { Some(x) => x, None => 0 }` (must be exhaustive)
    #|
    #|### Types
    #|- Primitives: Int, Float, Double, Bool, Char, String, Unit
    #|- Collections: Array[T], Map[T] (string-keyed)
    #|- Composite: (A, B) tuple, record { x: Int, y: String }
    #|- Option[T]: Some(value) | None
    #|- Result[T, E]: Ok(value) | Err(error)
    #|
    #|### Operators
    #|- Arithmetic: +, -, *, /, %
    #|- Comparison: ==, !=, <, >, <=, >=
    #|- Logical: &&, ||, !
    #|- Pipe: `expr |> func` (passes as first argument)
    #|
    #|### Literals
    #|- Array: [1, 2, 3]
    #|- Record: record { name: "Alice", age: 30 }
    #|- Map: { "a": 1, "b": 2 }
    #|- Tuple: (1, "two", true)
    #|- String interpolation: "hello \(name)"
  let builtins =
    #|## Builtin Functions
    #|
    #|### String
    #|- String::length(s) -> Int
    #|- String::substring(s, start, end) -> String
    #|- String::concat(s1, s2) -> String
    #|- String::split(s, sep) -> Array[String]
    #|- String::join(arr, sep) -> String
    #|- String::contains(s, sub) -> Bool
    #|- String::index_of(s, sub) -> Int (-1 if not found)
    #|- String::trim(s) -> String
    #|- String::starts_with(s, prefix) -> Bool
    #|- String::ends_with(s, suffix) -> Bool
    #|- String::replace(s, old, new) -> String
    #|- String::replace_all(s, old, new) -> String
    #|- String::char_code_at(s, i) -> Int
    #|- String::from_char_code(code) -> String
    #|
    #|### Array
    #|- Array::length(arr) -> Int
    #|- Array::get(arr, index) -> T
    #|- Array::slice(arr, start, end) -> Array[T]
    #|
    #|### Map
    #|- Map::get(m, key) -> T
    #|- Map::keys(m) -> Array[String]
    #|- Map::values(m) -> Array[T]
    #|- Map::has_key(m, key) -> Bool
    #|
    #|### Conversion
    #|- to_string(value) -> String
    #|- Int::to_float(n) -> Float
    #|- Int::to_double(n) -> Double
    #|- Float::to_int(f) -> Int
    #|- Double::to_int(d) -> Int
    #|
    #|### Math
    #|- Int::abs(n) -> Int
    #|- Int::max(a, b) -> Int
    #|- Int::min(a, b) -> Int
    #|- Double::abs(d) -> Double
    #|- Double::floor(d) -> Double
    #|- Double::ceil(d) -> Double
    #|
    #|### JSON
    #|- Json::stringify(value) -> String
    #|- Json::parse(s) -> Value
    #|- Json::get(obj, key) -> Value
    #|- Json::keys(obj) -> Array[String]
  let rules =
    #|## RLM Rules
    #|
    #|1. Write ONE let binding or expression per turn.
    #|2. Each binding accumulates in the session — use previous bindings freely.
    #|3. When the task is complete, call `Rlm::finalize(result_string)` with the final answer as a String.
    #|4. If you get an error, read the error message and try a different approach.
    #|5. Do NOT write multiple statements in one turn.
    #|6. Do NOT use markdown code fences or explanations — respond with ONLY vibe code.
    #|7. Use `to_string(value)` to convert non-string values before passing to Rlm::finalize.
  syntax + "\n\n" + builtins + "\n\n" + rules
}

///|
fn rlm_build_user_message(
  task : String,
  bindings : Array[(String, String)],
  budget : RlmBudget,
  error_feedback : String,
) -> String {
  let mut msg = "Task: " + task + "\n"
  if bindings.length() > 0 {
    msg = msg + "\nCurrent bindings:\n"
    for binding in bindings {
      msg = msg + "  let " + binding.0 + " = " + binding.1 + "\n"
    }
    msg = msg +
      "\nYou already have the above bindings. Do NOT redefine them. Build on them or call Rlm::finalize if the task is done.\n"
  }
  let next_step = budget.steps_used + 1
  let remaining = budget.max_steps - budget.steps_used
  msg = msg +
    "\nBudget: step " +
    next_step.to_string() +
    "/" +
    budget.max_steps.to_string() +
    " (" +
    remaining.to_string() +
    " remaining)\n"
  if remaining <= budget.max_steps / 2 {
    msg = msg +
      "WARNING: Budget is running low. Finalize soon with Rlm::finalize(to_string(result)).\n"
  }
  if error_feedback.length() > 0 {
    msg = msg +
      "\nPrevious error:\n" +
      error_feedback +
      "\nFix: try a different syntax. Remember: `let rec f = (args) -> Type { body }` for recursion.\n"
  }
  msg = msg +
    "\nWrite your next vibe statement (ONE statement only). When done, call: Rlm::finalize(to_string(your_result))\n"
  msg
}

///|
fn rlm_is_prelude_name(name : String) -> Bool {
  let names = @checker.prelude_names()
  for n in names {
    if n == name {
      return true
    }
  }
  false
}

///|
fn rlm_collect_bindings(rt : Runtime) -> Array[(String, String)] {
  let bindings : Array[(String, String)] = []
  for name, _hash in rt.env {
    // Skip internal/prelude bindings, prompt, and PromptText values
    if name.has_prefix("_") || name == "prompt" || rlm_is_prelude_name(name) {
      continue
    }
    match rt.get(name) {
      Some(@core.Value::PromptText(_)) => () // skip PromptText bindings
      Some(value) => {
        let value_str = value.to_string()
        let preview = truncate_preview(value_str, 120)
        bindings.push((name, preview))
      }
      None => ()
    }
  }
  bindings
}

///|
fn rlm_collect_prompt_bindings(rt : Runtime) -> Array[(String, String)] {
  let prompts : Array[(String, String)] = []
  for name, _hash in rt.env {
    if name.has_prefix("_") || rlm_is_prelude_name(name) {
      continue
    }
    match rt.get(name) {
      Some(@core.Value::PromptText(pt)) => prompts.push((name, pt.as_string()))
      _ => ()
    }
  }
  prompts
}

///|
fn rlm_extract_code(response : String) -> String {
  // Strip markdown code fences if present
  let trimmed = string_trim_simple(response)
  if trimmed.has_prefix("```") {
    // Find end of first line (language tag)
    let chars = trimmed.to_array()
    let mut start = 3
    // Skip optional language tag (e.g. ```vibe)
    while start < chars.length() && chars[start] != '\n' {
      start = start + 1
    }
    if start < chars.length() {
      start = start + 1 // skip newline
    }
    // Find closing ```
    let mut end = chars.length()
    if trimmed.has_suffix("```") {
      end = chars.length() - 3
    }
    // Extract content
    let mut code = ""
    for i = start; i < end; i = i + 1 {
      code = code + chars[i].to_string()
    }
    string_trim_simple(code)
  } else {
    trimmed
  }
}

///|
fn string_trim_simple(s : String) -> String {
  let chars = s.to_array()
  let len = chars.length()
  let mut start = 0
  while start < len &&
        (
          chars[start] == ' ' ||
          chars[start] == '\t' ||
          chars[start] == '\n' ||
          chars[start] == '\r'
        ) {
    start = start + 1
  }
  let mut end = len
  while end > start &&
        (
          chars[end - 1] == ' ' ||
          chars[end - 1] == '\t' ||
          chars[end - 1] == '\n' ||
          chars[end - 1] == '\r'
        ) {
    end = end - 1
  }
  let mut result = ""
  for i = start; i < end; i = i + 1 {
    result = result + chars[i].to_string()
  }
  result
}

///|
fn rlm_run_loop(
  parent_rt : Runtime,
  task : String,
  prompt : String,
  budget : RlmBudget,
) -> String raise EvalError {
  // Create a sandbox runtime with LLM capability
  let sandbox_caps = @capability.CapabilitySet::from_array([
    @capability.Capability::llm_call(["*"]),
    @capability.Capability::env_read(["*"]),
    @capability.Capability::net_connect("*", None),
  ])
  let sandbox = Runtime::new(sandbox_caps)

  // TODO(#20): migrate to compiled backend (needs REPL session support)
  // Bind the prompt in the sandbox
  // json_escape_string returns a quoted string like "\"hello world\""
  let prompt_script = "let prompt = " + json_escape_string(prompt)
  let _ = try? sandbox.eval_script(prompt_script)

  // Get LLM config
  let config = match LlmConfig::from_env() {
    Some(c) => c
    None =>
      raise EvalError::BadCall(E("Rlm::run: VIBE_LLM_PROVIDER env var not set"))
  }

  // Check parent capability
  if not(parent_rt.caps().can_call_llm(config.model)) {
    raise EvalError::PermissionDenied("llm_call:" + config.model)
  }

  let prompt_bindings = rlm_collect_prompt_bindings(sandbox)
  let extra_context = if prompt_bindings.length() > 0 {
    let buf = StringBuilder::new()
    buf.write_string("\n\nEnvironment prompts:\n")
    for binding in prompt_bindings {
      buf.write_string("- ")
      buf.write_string(binding.0)
      buf.write_string(": ")
      buf.write_string(binding.1)
      buf.write_char('\n')
    }
    buf.to_string()
  } else {
    ""
  }
  let system = rlm_system_prompt() + extra_context
  let mut error_feedback = ""
  let trace : Array[String] = []

  // Main loop
  while true {
    // Budget check
    match budget.check() {
      Some(err) => raise EvalError::BadCall(Io(op="Rlm::run", detail=err))
      None => ()
    }

    // Collect current bindings
    let bindings = rlm_collect_bindings(sandbox)

    // Build user message
    let user_msg = rlm_build_user_message(
      task, bindings, budget, error_feedback,
    )

    // Call LLM
    let response = llm_complete(config, system, user_msg)
    budget.steps_used = budget.steps_used + 1

    // Extract code from response
    let code = rlm_extract_code(response)

    // Debug trace
    println(
      "[rlm step " +
      budget.steps_used.to_string() +
      "/" +
      budget.max_steps.to_string() +
      "] " +
      truncate_preview(code, 200),
    )

    // Record trace
    trace.push(
      "{\"step\":" +
      budget.steps_used.to_string() +
      ",\"code\":" +
      json_escape_string(code) +
      "}",
    )

    // Wrap effectful code in effect guard if needed
    let eval_code = if code.contains("Llm::complete") ||
      code.contains("Rlm::run") {
      "{ " + code + " }"
    } else {
      code
    }

    // Check for rlm_finalize call
    if code.contains("Rlm::finalize") {
      let finalize_result = try? sandbox.eval_script(eval_code)
      match finalize_result {
        Ok(result) =>
          match result.last {
            Some(@core.Value::String(s)) => return s
            Some(v) => return v.to_string()
            None =>
              raise EvalError::BadCall(
                E("Rlm::run: Rlm::finalize returned no value"),
              )
          }
        Err(e) => {
          error_feedback = e.to_string()
          continue
        }
      }
    }

    // Evaluate the code in sandbox
    let eval_result = try? sandbox.eval_script(eval_code)
    match eval_result {
      Ok(_) => {
        error_feedback = ""
        println("[rlm] => ok")
      }
      Err(e) => {
        error_feedback = e.to_string()
        println("[rlm] => error: " + truncate_preview(error_feedback, 200))
      }
    }
  }
  raise EvalError::BadCall(E("Rlm::run: unexpected loop exit"))
}
