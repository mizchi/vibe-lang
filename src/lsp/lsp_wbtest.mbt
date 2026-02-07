///|
/// LSP tests

///|
test "check_document/parse_error" {
  let source = "let x = " // Incomplete expression
  let (diagnostics, ok) = check_document("file://test.xsh", source)
  assert_false(ok)
  assert_true(diagnostics.length() > 0)
}

///|
test "check_document/type_error" {
  let source = "let x: Int = \"hello\"" // Type mismatch
  let (diagnostics, ok) = check_document("file://test.xsh", source)
  assert_false(ok)
  assert_true(diagnostics.length() > 0)
}

///|
test "check_document/valid" {
  let source = "let x = 42"
  let (diagnostics, ok) = check_document("file://test.xsh", source)
  assert_true(ok)
  assert_eq(diagnostics.length(), 0)
}

///|
test "handle_initialize" {
  let resp = handle_initialize(Some(JsonRpcId::Num(1)))
  assert_eq(resp.jsonrpc, "2.0")
  assert_eq(resp.id, Some(JsonRpcId::Num(1)))
  assert_true(resp.result is Some(_))
  assert_true(resp.error is None)
}

///|
test "handle_shutdown" {
  let resp = handle_shutdown(Some(JsonRpcId::Num(2)))
  assert_eq(resp.jsonrpc, "2.0")
  assert_eq(resp.id, Some(JsonRpcId::Num(2)))
  assert_true(resp.error is None)
}

///|
test "parse_request/valid" {
  let json = Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(1.0),
    "method": Json::string("initialize"),
    "params": Json::object({}),
  })
  let req = parse_request(json)
  assert_true(req is Some(_))
  let r = req.unwrap()
  assert_eq(r.jsonrpc, "2.0")
  assert_eq(r.meth, "initialize")
}

///|
test "parse_request/notification" {
  let json = Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string("initialized"),
  })
  let req = parse_request(json)
  assert_true(req is Some(_))
  let r = req.unwrap()
  assert_true(r.id is None)
}

///|
test "LspServer/handle_message/initialize" {
  let server = LspServer::new()
  let json = Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(1.0),
    "method": Json::string("initialize"),
    "params": Json::object({}),
  })
  let (resp, notifications) = server.handle_message(json)
  assert_true(resp is Some(_))
  assert_eq(notifications.length(), 0)
  assert_true(server.initialized)
}

///|
test "offset_to_position/simple" {
  let source = "abc\ndef\nghi"
  // Position at start of second line
  let pos = offset_to_position(source, 4)
  assert_eq(pos.line, 1)
  assert_eq(pos.character, 0)
}

///|
test "offset_to_position/middle" {
  let source = "abc\ndef\nghi"
  // Position in middle of second line
  let pos = offset_to_position(source, 5)
  assert_eq(pos.line, 1)
  assert_eq(pos.character, 1)
}

///|
test "DocumentManager/basic" {
  let dm = DocumentManager::new()
  dm.open("file://test.xsh", "let x = 1", 1)
  assert_eq(dm.get("file://test.xsh"), Some("let x = 1"))
  assert_eq(dm.get_version("file://test.xsh"), Some(1))
  dm.update("file://test.xsh", "let x = 2", 2)
  assert_eq(dm.get("file://test.xsh"), Some("let x = 2"))
  assert_eq(dm.get_version("file://test.xsh"), Some(2))
  dm.close("file://test.xsh")
  assert_true(dm.get("file://test.xsh") is None)
}
