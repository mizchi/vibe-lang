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
  "You are a vibe language agent. You write vibe code to accomplish the given task.\n\nVibe syntax basics:\n- `let x = expr` binds a value\n- `let x: Type = expr` with type annotation\n- String, Int, Bool, Array, Record types\n- `string_split(s, delim)` splits string\n- `string_length(s)` returns length\n- `string_join(arr, sep)` joins array with separator\n- `string_contains(s, sub)` checks substring\n- `string_trim(s)` trims whitespace\n- `string_slice(s, start, end)` extracts substring\n- `array_length(arr)` returns array length\n- `to_string(v)` converts value to string\n- `int_parse(s)` parses string to int\n- Arithmetic: +, -, *, /, %\n- Comparison: ==, !=, <, >, <=, >=\n- Boolean: &&, ||, !\n- If: `if cond { expr } else { expr }`\n- Array literal: [1, 2, 3]\n- Record literal: { key: value }\n\nRules:\n1. Write ONE statement per turn (let binding or expression).\n2. Each let binding accumulates in the session.\n3. When done, call `rlm_finalize(result_string)` with the final answer.\n4. If you encounter an error, try a different approach.\n5. Keep answers concise and focused on the task.\n\nRespond with ONLY vibe code, no explanation or markdown."
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
  }
  msg = msg +
    "\nBudget: step " +
    (budget.steps_used + 1).to_string() +
    "/" +
    budget.max_steps.to_string() +
    "\n"
  if error_feedback.length() > 0 {
    msg = msg + "\nPrevious error:\n" + error_feedback + "\n"
  }
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
    // Skip internal/prelude bindings and prompt
    if name.has_prefix("_") || name == "prompt" || rlm_is_prelude_name(name) {
      continue
    }
    match rt.get(name) {
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
pub fn rlm_run_loop(
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

  // Bind the prompt in the sandbox
  // json_escape_string returns a quoted string like "\"hello world\""
  let prompt_script = "let prompt = " + json_escape_string(prompt)
  let _ = try? sandbox.eval_script(prompt_script)

  // Get LLM config
  let config = match LlmConfig::from_env() {
    Some(c) => c
    None =>
      raise EvalError::BadCall("rlm_run: VIBE_LLM_PROVIDER env var not set")
  }

  // Check parent capability
  if not(parent_rt.caps().can_call_llm(config.model)) {
    raise EvalError::PermissionDenied("llm_call:" + config.model)
  }

  let system = rlm_system_prompt()
  let mut error_feedback = ""
  let trace : Array[String] = []

  // Main loop
  while true {
    // Budget check
    match budget.check() {
      Some(err) => raise EvalError::BadCall("rlm_run: " + err)
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

    // Record trace
    trace.push(
      "{\"step\":" +
      budget.steps_used.to_string() +
      ",\"code\":" +
      json_escape_string(code) +
      "}",
    )

    // Wrap effectful code in effect guard if needed
    let eval_code = if code.contains("llm_complete") || code.contains("rlm_run") {
      "do { " + code + " }"
    } else {
      code
    }

    // Check for rlm_finalize call
    if code.contains("rlm_finalize") {
      let finalize_result = try? sandbox.eval_script(eval_code)
      match finalize_result {
        Ok(result) =>
          match result.last {
            Some(@core.Value::String(s)) => return s
            Some(v) => return v.to_string()
            None =>
              raise EvalError::BadCall(
                "rlm_run: rlm_finalize returned no value",
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
      Ok(_) => error_feedback = ""
      Err(e) => error_feedback = e.to_string()
    }
  }
  raise EvalError::BadCall("rlm_run: unexpected loop exit")
}
