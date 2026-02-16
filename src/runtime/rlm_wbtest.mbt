///|
test "LlmConfig::from_env returns None when VIBE_LLM_PROVIDER not set" {
  // Ensure env var is not set (it shouldn't be in test environment)
  let saved = @sys.get_env_var("VIBE_LLM_PROVIDER")
  match saved {
    Some(_) => @sys.unset_env_var("VIBE_LLM_PROVIDER")
    None => ()
  }
  let config = LlmConfig::from_env()
  assert_true(config is None)
  // Restore
  match saved {
    Some(v) => @sys.set_env_var("VIBE_LLM_PROVIDER", v)
    None => ()
  }
}

///|
test "LlmConfig::from_env parses provider and defaults" {
  let saved_provider = @sys.get_env_var("VIBE_LLM_PROVIDER")
  let saved_key = @sys.get_env_var("VIBE_LLM_API_KEY")
  let saved_model = @sys.get_env_var("VIBE_LLM_MODEL")
  let saved_url = @sys.get_env_var("VIBE_LLM_BASE_URL")
  // Clean
  @sys.set_env_var("VIBE_LLM_PROVIDER", "openai")
  @sys.set_env_var("VIBE_LLM_API_KEY", "sk-test123")
  @sys.unset_env_var("VIBE_LLM_MODEL")
  @sys.unset_env_var("VIBE_LLM_BASE_URL")
  let config = LlmConfig::from_env()
  match config {
    Some(c) => {
      assert_eq(c.provider, "openai")
      assert_eq(c.api_key, "sk-test123")
      assert_eq(c.model, "gpt-4.1-mini")
      assert_eq(c.base_url, "https://api.openai.com")
    }
    None => fail("expected Some config")
  }
  // Restore
  match saved_provider {
    Some(v) => @sys.set_env_var("VIBE_LLM_PROVIDER", v)
    None => @sys.unset_env_var("VIBE_LLM_PROVIDER")
  }
  match saved_key {
    Some(v) => @sys.set_env_var("VIBE_LLM_API_KEY", v)
    None => @sys.unset_env_var("VIBE_LLM_API_KEY")
  }
  match saved_model {
    Some(v) => @sys.set_env_var("VIBE_LLM_MODEL", v)
    None => ()
  }
  match saved_url {
    Some(v) => @sys.set_env_var("VIBE_LLM_BASE_URL", v)
    None => ()
  }
}

///|
test "LlmConfig::from_env anthropic defaults" {
  let saved_provider = @sys.get_env_var("VIBE_LLM_PROVIDER")
  let saved_key = @sys.get_env_var("VIBE_LLM_API_KEY")
  let saved_model = @sys.get_env_var("VIBE_LLM_MODEL")
  let saved_url = @sys.get_env_var("VIBE_LLM_BASE_URL")
  @sys.set_env_var("VIBE_LLM_PROVIDER", "anthropic")
  @sys.set_env_var("VIBE_LLM_API_KEY", "sk-ant-test")
  @sys.unset_env_var("VIBE_LLM_MODEL")
  @sys.unset_env_var("VIBE_LLM_BASE_URL")
  let config = LlmConfig::from_env()
  match config {
    Some(c) => {
      assert_eq(c.provider, "anthropic")
      assert_eq(c.model, "claude-sonnet-4-5-20250929")
      assert_eq(c.base_url, "https://api.anthropic.com")
    }
    None => fail("expected Some config")
  }
  // Restore
  match saved_provider {
    Some(v) => @sys.set_env_var("VIBE_LLM_PROVIDER", v)
    None => @sys.unset_env_var("VIBE_LLM_PROVIDER")
  }
  match saved_key {
    Some(v) => @sys.set_env_var("VIBE_LLM_API_KEY", v)
    None => @sys.unset_env_var("VIBE_LLM_API_KEY")
  }
  match saved_model {
    Some(v) => @sys.set_env_var("VIBE_LLM_MODEL", v)
    None => ()
  }
  match saved_url {
    Some(v) => @sys.set_env_var("VIBE_LLM_BASE_URL", v)
    None => ()
  }
}

///|
test "RlmBudget::default values" {
  let budget = RlmBudget::default()
  assert_eq(budget.steps_used, 0)
  assert_eq(budget.max_steps, 32)
  assert_eq(budget.depth, 0)
  assert_eq(budget.max_depth, 4)
}

///|
test "RlmBudget::check within budget" {
  let budget = RlmBudget::default()
  assert_true(budget.check() is None)
}

///|
test "RlmBudget::check steps exceeded" {
  let budget = RlmBudget::default()
  budget.steps_used = 32
  match budget.check() {
    Some(msg) => assert_true(msg.contains("max_steps"))
    None => fail("expected budget exceeded")
  }
}

///|
test "RlmBudget::check depth exceeded" {
  let budget = RlmBudget::default()
  budget.depth = 4
  match budget.check() {
    Some(msg) => assert_true(msg.contains("max_depth"))
    None => fail("expected budget exceeded")
  }
}

///|
test "rlm_extract_code strips markdown fences" {
  let code = "```vibe\nlet x = 42\n```"
  let result = rlm_extract_code(code)
  assert_eq(result, "let x = 42")
}

///|
test "rlm_extract_code passes plain code through" {
  let code = "let x = 42"
  let result = rlm_extract_code(code)
  assert_eq(result, "let x = 42")
}

///|
test "rlm_extract_code strips fences without language tag" {
  let code = "```\nlet y = \"hello\"\n```"
  let result = rlm_extract_code(code)
  assert_eq(result, "let y = \"hello\"")
}

///|
test "truncate_preview short string unchanged" {
  let result = truncate_preview("hello", 10)
  assert_eq(result, "hello")
}

///|
test "truncate_preview long string truncated" {
  let result = truncate_preview("hello world this is a long string", 10)
  assert_eq(result, "hello worl...")
}

///|
test "CapabilitySet::can_call_llm with wildcard" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::llm_call(["*"]),
  ])
  assert_true(caps.can_call_llm("gpt-4.1-mini"))
  assert_true(caps.can_call_llm("claude-sonnet-4-5-20250929"))
}

///|
test "CapabilitySet::can_call_llm with specific model" {
  let caps = @capability.CapabilitySet::from_array([
    @capability.Capability::llm_call(["gpt-4.1-mini"]),
  ])
  assert_true(caps.can_call_llm("gpt-4.1-mini"))
  assert_false(caps.can_call_llm("claude-sonnet-4-5-20250929"))
}

///|
test "CapabilitySet::can_call_llm empty set" {
  let caps = @capability.CapabilitySet::new()
  assert_false(caps.can_call_llm("gpt-4.1-mini"))
}

///|
test "extract_openai_content parses valid response" {
  let body = "{\"choices\":[{\"message\":{\"content\":\"let x = 42\"}}]}"
  let result = extract_openai_content(body)
  assert_eq(result, "let x = 42")
}

///|
test "extract_anthropic_content parses valid response" {
  let body = "{\"content\":[{\"type\":\"text\",\"text\":\"let x = 42\"}]}"
  let result = extract_anthropic_content(body)
  assert_eq(result, "let x = 42")
}

///|
test "build_openai_request_body format" {
  let body = build_openai_request_body("gpt-4.1-mini", "system", "user")
  // json_escape_string wraps in quotes, so model becomes "gpt-4.1-mini"
  assert_true(body.contains("\"model\":\"gpt-4.1-mini\""))
  assert_true(body.contains("\"messages\""))
  assert_true(body.contains("\"content\":\"system\""))
}

///|
test "build_anthropic_request_body format" {
  let body = build_anthropic_request_body(
    "claude-sonnet-4-5-20250929", "system", "user",
  )
  assert_true(body.contains("\"model\":\"claude-sonnet-4-5-20250929\""))
  assert_true(body.contains("\"max_tokens\""))
  assert_true(body.contains("\"system\":\"system\""))
}

///|
test "llm_complete/rlm_run/rlm_finalize type check" {
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  // llm_complete needs Llm effect guard in the type system
  let result = try? rt.eval_script(
    "let f = () -> String with { Llm } { do { llm_complete(\"sys\", \"usr\") } }",
  )
  match result {
    Ok(_) => ()
    Err(e) => fail("type check failed: " + e.to_string())
  }
}

///|
test "rlm_run type check" {
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  let result = try? rt.eval_script(
    "let f = () -> String with { Llm } { do { rlm_run(\"task\", \"prompt\") } }",
  )
  match result {
    Ok(_) => ()
    Err(e) => fail("type check failed: " + e.to_string())
  }
}

///|
test "rlm_finalize type check and passthrough" {
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  let result = try? rt.eval_script("rlm_finalize(\"done\")")
  match result {
    Ok(r) =>
      match r.last {
        Some(@core.Value::String(s)) => assert_eq(s, "done")
        _ => fail("expected string result")
      }
    Err(e) => fail("eval failed: " + e.to_string())
  }
}

///|
test "rlm_collect_bindings excludes prelude names" {
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  // Prelude is loaded automatically in Runtime::new
  // Bind a user variable
  let _ = try? rt.eval_script("let my_var = 42")
  let bindings = rlm_collect_bindings(rt)
  // Should include user binding
  let mut found_my_var = false
  let mut found_prelude = false
  for binding in bindings {
    if binding.0 == "my_var" {
      found_my_var = true
    }
    if binding.0 == "add" ||
      binding.0 == "sub" ||
      binding.0 == "eq" ||
      binding.0 == "to_string" {
      found_prelude = true
    }
  }
  assert_true(found_my_var)
  assert_false(found_prelude)
}

///|
test "rlm_collect_bindings excludes prompt" {
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  let _ = try? rt.eval_script("let prompt = \"test\"")
  let _ = try? rt.eval_script("let result = \"ok\"")
  let bindings = rlm_collect_bindings(rt)
  let mut found_prompt = false
  let mut found_result = false
  for binding in bindings {
    if binding.0 == "prompt" {
      found_prompt = true
    }
    if binding.0 == "result" {
      found_result = true
    }
  }
  assert_false(found_prompt)
  assert_true(found_result)
}

///|
test "rlm_is_prelude_name identifies prelude" {
  assert_true(rlm_is_prelude_name("add"))
  assert_true(rlm_is_prelude_name("sub"))
  assert_true(rlm_is_prelude_name("array_map"))
  assert_true(rlm_is_prelude_name("to_string"))
  assert_false(rlm_is_prelude_name("my_var"))
  assert_false(rlm_is_prelude_name("prompt"))
}

///|
test "prompt binding with json_escape_string" {
  // Verify that json_escape_string wraps in quotes
  let escaped = json_escape_string("hello world")
  assert_eq(escaped, "\"hello world\"")
  // The prompt_script should be valid vibe: let prompt = "hello world"
  let script = "let prompt = " + escaped
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  let result = try? rt.eval_script(script)
  match result {
    Ok(_) =>
      match rt.get("prompt") {
        Some(@core.Value::String(s)) => assert_eq(s, "hello world")
        _ => fail("expected string prompt binding")
      }
    Err(e) => fail("eval failed: " + e.to_string())
  }
}

///|
test "prompt binding with special characters" {
  let escaped = json_escape_string("line1\nline2\ttab")
  let script = "let prompt = " + escaped
  let rt = Runtime::new(@capability.CapabilitySet::unrestricted())
  let result = try? rt.eval_script(script)
  match result {
    Ok(_) =>
      match rt.get("prompt") {
        Some(@core.Value::String(s)) => assert_eq(s, "line1\nline2\ttab")
        _ => fail("expected string prompt binding")
      }
    Err(e) => fail("eval failed: " + e.to_string())
  }
}
