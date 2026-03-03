///|
test "fallback: echo hello" {
  let result = execute_shell_lines_fallback("echo hello")
  assert_eq(result, ["hello"])
}

///|
test "fallback: echo no args" {
  let result = execute_shell_lines_fallback("echo")
  assert_eq(result, [""])
}

///|
test "fallback: empty command" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_eq(detail, "empty command")
}

///|
test "fallback: unsupported command" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("git status")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_true(detail.contains("not available on this target"))
  assert_true(detail.contains("fallback mode"))
}

///|
test "fallback: ls too many args" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("ls a b")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_eq(detail, "ls: expected 0 or 1 arguments, got 2")
}

///|
test "fallback: cat without file" {
  let mut detail = ""
  try {
    let _ = execute_shell_lines_fallback("cat")
  } catch {
    EvalError::BadCall(Io(detail=d, ..)) => detail = d
    other => fail("unexpected error: " + other.to_string())
  }
  assert_eq(detail, "cat: expected exactly 1 file argument, got 0")
}

///|
test "fallback: ls cwd" {
  let result = execute_shell_lines_fallback("ls .")
  assert_true(result.length() > 0)
}

///|
fn builtin_test_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn builtin_test_int_arg(value : Int) -> @core.CallArg {
  let span = builtin_test_span()
  @core.CallArg::{
    label: None,
    expr: @core.Expr::Int(value=value.to_int64(), span~),
    span,
  }
}

///|
fn builtin_test_string_arg(value : String) -> @core.CallArg {
  let span = builtin_test_span()
  @core.CallArg::{ label: None, expr: @core.Expr::String(value~, span~), span }
}

///|
fn eval_builtin_for_contract(
  name : String,
  args : Array[@core.CallArg],
) -> Result[EvalOutput, EvalError] {
  eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::developer(),
    name,
    args,
  )
}

///|
fn eval_builtin_for_contract_with_caps(
  caps : @capability.CapabilitySet,
  name : String,
  args : Array[@core.CallArg],
) -> Result[EvalOutput, EvalError] {
  let rt = Runtime::new(caps)
  try? eval_builtin_call(rt, name, args, builtin_test_span())
}

///|
test "http builtins contract: http_listen bad arg maps to BuiltinDetail" {
  let result = eval_builtin_for_contract("http_listen", [
    builtin_test_string_arg("8080"),
  ])
  match result {
    Ok(_) => fail("expected bad call")
    Err(EvalError::BadCall(BuiltinDetail(fn_name~, detail~))) => {
      assert_eq(fn_name, "http_listen")
      assert_eq(detail, "bad call")
    }
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_accept bad arg maps to BuiltinDetail" {
  let result = eval_builtin_for_contract("http_accept", [
    builtin_test_string_arg("1"),
  ])
  match result {
    Ok(_) => fail("expected bad call")
    Err(EvalError::BadCall(BuiltinDetail(fn_name~, detail~))) => {
      assert_eq(fn_name, "http_accept")
      assert_eq(detail, "bad call")
    }
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_respond bad arg maps to BuiltinDetail" {
  let result = eval_builtin_for_contract("http_respond", [
    builtin_test_int_arg(1),
    builtin_test_string_arg("200"),
    builtin_test_string_arg(""),
    builtin_test_string_arg(""),
  ])
  match result {
    Ok(_) => fail("expected bad call")
    Err(EvalError::BadCall(BuiltinDetail(fn_name~, detail~))) => {
      assert_eq(fn_name, "http_respond")
      assert_eq(detail, "bad call")
    }
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_accept backend error maps to Io(http_accept)" {
  let result = eval_builtin_for_contract("http_accept", [
    builtin_test_int_arg(-1),
  ])
  match result {
    Ok(_) => fail("expected io bad call")
    Err(EvalError::BadCall(Io(op~, detail~))) => {
      assert_eq(op, "http_accept")
      assert_true(detail.length() > 0)
    }
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_respond backend error maps to Io(http_respond)" {
  let result = eval_builtin_for_contract("http_respond", [
    builtin_test_int_arg(-1),
    builtin_test_int_arg(200),
    builtin_test_string_arg("content-type: text/plain"),
    builtin_test_string_arg("ok"),
  ])
  match result {
    Ok(_) => fail("expected io bad call")
    Err(EvalError::BadCall(Io(op~, detail~))) => {
      assert_eq(op, "http_respond")
      assert_true(detail.length() > 0)
    }
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_listen requires net listen capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "http_listen",
    [builtin_test_int_arg(8080)],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) =>
      assert_eq(detail, "net_listen:8080")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_accept requires net listen capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "http_accept",
    [builtin_test_int_arg(1)],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) => assert_eq(detail, "net_accept")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_respond requires net listen capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "http_respond",
    [
      builtin_test_int_arg(1),
      builtin_test_int_arg(200),
      builtin_test_string_arg(""),
      builtin_test_string_arg("ok"),
    ],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) => assert_eq(detail, "net_respond")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_request requires net connect capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "http_request",
    [
      builtin_test_string_arg("GET"),
      builtin_test_string_arg("https://example.com"),
      builtin_test_string_arg(""),
      builtin_test_string_arg(""),
    ],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) =>
      assert_eq(detail, "net_connect:example.com:443")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_request rejects invalid URL before backend" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::developer(),
    "http_request",
    [
      builtin_test_string_arg("GET"),
      builtin_test_string_arg("example.com"),
      builtin_test_string_arg(""),
      builtin_test_string_arg(""),
    ],
  )
  match result {
    Ok(_) => fail("expected bad call")
    Err(EvalError::BadCall(Io(op~, detail~))) => {
      assert_eq(op, "http_request")
      assert_true(detail.contains("invalid URL for network capability check"))
    }
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_response_status requires net connect capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "http_response_status",
    [builtin_test_int_arg(1)],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) =>
      assert_eq(detail, "net_response_status")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "http builtins contract: http_request_method requires net listen capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "http_request_method",
    [builtin_test_int_arg(1)],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) =>
      assert_eq(detail, "net_request_method")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}

///|
test "socket builtins contract: connect requires net connect capability" {
  let result = eval_builtin_for_contract_with_caps(
    @capability.CapabilitySet::new(),
    "socket_tcp_connect",
    [builtin_test_string_arg("example.com"), builtin_test_int_arg(443)],
  )
  match result {
    Ok(_) => fail("expected permission denied")
    Err(EvalError::PermissionDenied(detail)) =>
      assert_eq(detail, "net_connect:example.com:443")
    Err(other) => fail("unexpected error: " + other.to_string())
  }
}
