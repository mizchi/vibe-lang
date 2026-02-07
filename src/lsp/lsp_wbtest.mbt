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
test "LspServer/handle_message/codeAction trait import quickfix" {
  let server = LspServer::new()
  let uri = "file://test.xsh"
  let source = "let same = [T: Eq](x: T, y: T) -> Bool { x == y }"
  let open_json = Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string("textDocument/didOpen"),
    "params": Json::object({
      "textDocument": Json::object({
        "uri": Json::string(uri),
        "languageId": Json::string("xsh"),
        "version": Json::number(1.0),
        "text": Json::string(source),
      }),
    }),
  })
  let _ = server.handle_message(open_json)
  let action_json = Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(10.0),
    "method": Json::string("textDocument/codeAction"),
    "params": Json::object({
      "textDocument": Json::object({ "uri": Json::string(uri) }),
      "range": Json::object({
        "start": Json::object({
          "line": Json::number(0.0),
          "character": Json::number(0.0),
        }),
        "end": Json::object({
          "line": Json::number(0.0),
          "character": Json::number(0.0),
        }),
      }),
      "context": Json::object({ "diagnostics": Json::array([]) }),
    }),
  })
  let (resp, notifications) = server.handle_message(action_json)
  assert_eq(notifications.length(), 0)
  match resp {
    Some(response) =>
      match response.result {
        Some(Json::Array(actions)) => {
          assert_true(actions.length() > 0)
          match actions[0] {
            Json::Object(obj) =>
              match obj.get("title") {
                Some(Json::String(title)) =>
                  assert_true(title.contains("Import Eq"))
                _ => fail("missing title")
              }
            _ => fail("code action must be object")
          }
        }
        _ => fail("expected code actions")
      }
    None => fail("expected response")
  }
}

///|
test "trait_import_code_actions skips already imported trait" {
  let source =
    #|import { Eq } from "./examples/std/trait_api.xsh"
    #|let same = [T: Eq](x: T, y: T) -> Bool { x == y }
  let actions = trait_import_code_actions("file://test.xsh", source)
  match actions {
    Json::Array(items) => assert_eq(items.length(), 0)
    _ => fail("expected array")
  }
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
