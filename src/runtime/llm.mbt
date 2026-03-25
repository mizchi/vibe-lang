///| LLM client for vibe runtime

///|
pub(all) struct LlmConfig {
  provider : String // "openai" | "anthropic" | "ollama"
  api_key : String
  model : String
  base_url : String
}

///|
pub fn LlmConfig::from_env() -> LlmConfig? {
  let provider = match @sys.get_env_var("VIBE_LLM_PROVIDER") {
    Some(v) => v
    None => return None
  }
  let api_key = match @sys.get_env_var("VIBE_LLM_API_KEY") {
    Some(v) => v
    None => ""
  }
  let model = match @sys.get_env_var("VIBE_LLM_MODEL") {
    Some(v) => v
    None =>
      match provider {
        "anthropic" => "claude-sonnet-4-5-20250929"
        "ollama" => "llama3"
        _ => "gpt-4.1-mini"
      }
  }
  let base_url = match @sys.get_env_var("VIBE_LLM_BASE_URL") {
    Some(v) => v
    None =>
      match provider {
        "anthropic" => "https://api.anthropic.com"
        "ollama" => "http://localhost:11434"
        _ => "https://api.openai.com"
      }
  }
  Some({ provider, api_key, model, base_url })
}

///|
fn build_openai_request_body(
  model : String,
  system : String,
  user : String,
) -> String {
  // json_escape_string returns quoted string like "\"foo\""
  let sys_escaped = json_escape_string(system)
  let user_escaped = json_escape_string(user)
  let model_escaped = json_escape_string(model)
  "{\"model\":" +
  model_escaped +
  ",\"messages\":[{\"role\":\"system\",\"content\":" +
  sys_escaped +
  "},{\"role\":\"user\",\"content\":" +
  user_escaped +
  "}]}"
}

///|
fn build_anthropic_request_body(
  model : String,
  system : String,
  user : String,
) -> String {
  let sys_escaped = json_escape_string(system)
  let user_escaped = json_escape_string(user)
  let model_escaped = json_escape_string(model)
  "{\"model\":" +
  model_escaped +
  ",\"max_tokens\":4096,\"system\":" +
  sys_escaped +
  ",\"messages\":[{\"role\":\"user\",\"content\":" +
  user_escaped +
  "}]}"
}

///|
fn extract_openai_content(body : String) -> String raise EvalError {
  // Parse JSON and extract choices[0].message.content
  let parsed = parse_json_value(body)
  let fields = match parsed {
    @core.Value::Map(f) => f
    @core.Value::Record(f) => f
    _ =>
      raise EvalError::BadCall(E("Llm::complete: invalid response JSON format"))
  }
  let choices = match fields.get("choices") {
    Some(@core.Value::Array(arr)) => arr
    _ =>
      raise EvalError::BadCall(E("Llm::complete: missing choices in response"))
  }
  if choices.length() == 0 {
    raise EvalError::BadCall(E("Llm::complete: empty choices array"))
  }
  let choice = match choices[0] {
    @core.Value::Map(f) => f
    @core.Value::Record(f) => f
    _ => raise EvalError::BadCall(E("Llm::complete: invalid choice format"))
  }
  let msg = match choice.get("message") {
    Some(@core.Value::Map(f)) => f
    Some(@core.Value::Record(f)) => f
    _ =>
      raise EvalError::BadCall(E("Llm::complete: missing message in response"))
  }
  match msg.get("content") {
    Some(@core.Value::String(content)) => content
    _ =>
      raise EvalError::BadCall(E("Llm::complete: missing content in response"))
  }
}

///|
fn extract_anthropic_content(body : String) -> String raise EvalError {
  // Parse JSON and extract content[0].text
  let parsed = parse_json_value(body)
  let fields = match parsed {
    @core.Value::Map(f) => f
    @core.Value::Record(f) => f
    _ =>
      raise EvalError::BadCall(E("Llm::complete: invalid response JSON format"))
  }
  let content_blocks = match fields.get("content") {
    Some(@core.Value::Array(arr)) => arr
    _ =>
      raise EvalError::BadCall(E("Llm::complete: missing content in response"))
  }
  if content_blocks.length() == 0 {
    raise EvalError::BadCall(E("Llm::complete: empty content array"))
  }
  let block = match content_blocks[0] {
    @core.Value::Map(f) => f
    @core.Value::Record(f) => f
    _ =>
      raise EvalError::BadCall(E("Llm::complete: invalid content block format"))
  }
  match block.get("text") {
    Some(@core.Value::String(text)) => text
    _ =>
      raise EvalError::BadCall(
        E("Llm::complete: missing text in content block"),
      )
  }
}

///|
fn llm_complete_openai(
  config : LlmConfig,
  system : String,
  user : String,
) -> String raise EvalError {
  let url = config.base_url + "/v1/chat/completions"
  let body = build_openai_request_body(config.model, system, user)
  let headers = "Content-Type: application/json\r\nAuthorization: Bearer " +
    config.api_key
  match @backend.http_request("POST", url, headers, body) {
    Ok(handle) => {
      match @backend.http_response_status(handle) {
        Ok(status) =>
          if status < 200 || status >= 300 {
            let err_body = match @backend.http_response_body(handle) {
              Ok(b) => b
              Err(_) => ""
            }
            let _ = @backend.http_close(handle)
            raise EvalError::BadCall(
              E("Llm::complete: HTTP " + status.to_string() + ": " + err_body),
            )
          }
        Err(e) => {
          let _ = @backend.http_close(handle)
          raise EvalError::BadCall(
            Llm(op="Llm::complete", detail="status error: " + e),
          )
        }
      }
      let resp_body = match @backend.http_response_body(handle) {
        Ok(b) => b
        Err(e) => {
          let _ = @backend.http_close(handle)
          raise EvalError::BadCall(
            Llm(op="Llm::complete", detail="body error: " + e),
          )
        }
      }
      let _ = @backend.http_close(handle)
      extract_openai_content(resp_body)
    }
    Err(e) =>
      raise EvalError::BadCall(
        Llm(op="Llm::complete", detail="request error: " + e),
      )
  }
}

///|
fn llm_complete_anthropic(
  config : LlmConfig,
  system : String,
  user : String,
) -> String raise EvalError {
  let url = config.base_url + "/v1/messages"
  let body = build_anthropic_request_body(config.model, system, user)
  let headers = "Content-Type: application/json\r\nx-api-key: " +
    config.api_key +
    "\r\nanthropic-version: 2023-06-01"
  match @backend.http_request("POST", url, headers, body) {
    Ok(handle) => {
      match @backend.http_response_status(handle) {
        Ok(status) =>
          if status < 200 || status >= 300 {
            let err_body = match @backend.http_response_body(handle) {
              Ok(b) => b
              Err(_) => ""
            }
            let _ = @backend.http_close(handle)
            raise EvalError::BadCall(
              E("Llm::complete: HTTP " + status.to_string() + ": " + err_body),
            )
          }
        Err(e) => {
          let _ = @backend.http_close(handle)
          raise EvalError::BadCall(
            Llm(op="Llm::complete", detail="status error: " + e),
          )
        }
      }
      let resp_body = match @backend.http_response_body(handle) {
        Ok(b) => b
        Err(e) => {
          let _ = @backend.http_close(handle)
          raise EvalError::BadCall(
            Llm(op="Llm::complete", detail="body error: " + e),
          )
        }
      }
      let _ = @backend.http_close(handle)
      extract_anthropic_content(resp_body)
    }
    Err(e) =>
      raise EvalError::BadCall(
        Llm(op="Llm::complete", detail="request error: " + e),
      )
  }
}

///|
fn llm_complete(
  config : LlmConfig,
  system : String,
  user : String,
) -> String raise EvalError {
  match config.provider {
    "anthropic" => llm_complete_anthropic(config, system, user)
    "openai" | "ollama" | _ => llm_complete_openai(config, system, user)
  }
}

///|
fn truncate_preview(s : String, max_len : Int) -> String {
  if s.length() <= max_len {
    s
  } else {
    let chars = s.to_array()
    let mut result = ""
    for i = 0; i < max_len; i = i + 1 {
      result = result + chars[i].to_string()
    }
    result + "..."
  }
}
