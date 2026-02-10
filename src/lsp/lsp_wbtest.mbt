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
  let source = "let x = 42\nx"
  let (diagnostics, ok) = check_document("file://test.xsh", source)
  assert_true(ok)
  assert_eq(diagnostics.length(), 0)
}

///|
test "check_document/warning" {
  let source = "let unused = 42"
  let (diagnostics, ok) = check_document("file://test.xsh", source)
  assert_true(ok)
  assert_eq(diagnostics.length(), 1)
  let diag = diagnostics[0]
  assert_eq(diag.severity, Some(2))
  assert_true(diag.message.contains("unused variable: unused"))
}

///|
test "check_document/warning_unnecessary_mut" {
  let source = "let mut value = 1\nvalue"
  let (diagnostics, ok) = check_document("file://test.xsh", source)
  assert_true(ok)
  assert_eq(diagnostics.length(), 1)
  let diag = diagnostics[0]
  assert_eq(diag.severity, Some(2))
  assert_true(diag.message.contains("unnecessary `mut` binding: value"))
}

///|
test "handle_initialize" {
  let resp = handle_initialize(Some(JsonRpcId::Num(1)))
  assert_eq(resp.jsonrpc, "2.0")
  assert_eq(resp.id, Some(JsonRpcId::Num(1)))
  assert_true(resp.result is Some(_))
  assert_true(resp.error is None)
  match resp.result {
    Some(Json::Object(obj)) =>
      match obj.get("capabilities") {
        Some(Json::Object(capabilities)) => {
          match capabilities.get("hoverProvider") {
            Some(Json::True) => ()
            _ => fail("missing hoverProvider")
          }
          match capabilities.get("completionProvider") {
            Some(Json::Object(_)) => ()
            _ => fail("missing completionProvider")
          }
        }
        _ => fail("missing capabilities")
      }
    _ => fail("missing initialize result")
  }
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
test "parse_position/valid" {
  let parsed = parse_position(
    Some(
      Json::object({
        "line": Json::number(3.0),
        "character": Json::number(7.0),
      }),
    ),
  )
  match parsed {
    Some(pos) => {
      assert_eq(pos.line, 3)
      assert_eq(pos.character, 7)
    }
    None => fail("expected position")
  }
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
test "LspServer/handle_message/completion returns symbols with hash info" {
  let server = LspServer::new()
  let uri = "file://completion_test.xsh"
  let source =
    #|let alpha = 1
    #|let beta = alpha
    #|al
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
  let completion_json = Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(20.0),
    "method": Json::string("textDocument/completion"),
    "params": Json::object({
      "textDocument": Json::object({ "uri": Json::string(uri) }),
      "position": Json::object({
        "line": Json::number(2.0),
        "character": Json::number(2.0),
      }),
    }),
  })
  let (resp, notifications) = server.handle_message(completion_json)
  assert_eq(notifications.length(), 0)
  match resp {
    Some(response) =>
      match response.result {
        Some(Json::Array(items)) => {
          assert_true(items.length() > 0)
          let mut has_alpha = false
          let mut has_hash_doc = false
          for item in items {
            match item {
              Json::Object(obj) => {
                match obj.get("label") {
                  Some(Json::String(label)) =>
                    if label == "alpha" {
                      has_alpha = true
                    }
                  _ => ()
                }
                match obj.get("documentation") {
                  Some(Json::String(doc)) =>
                    if doc.contains("hash: ") {
                      has_hash_doc = true
                    }
                  _ => ()
                }
              }
              _ => ()
            }
          }
          assert_true(has_alpha)
          assert_true(has_hash_doc)
        }
        _ => fail("expected completion array")
      }
    None => fail("expected completion response")
  }
}

///|
test "LspServer/handle_message/hover includes hash" {
  let server = LspServer::new()
  let uri = "file://hover_test.xsh"
  let source =
    #|let alpha = 1
    #|alpha
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
  let hover_req = Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(21.0),
    "method": Json::string("textDocument/hover"),
    "params": Json::object({
      "textDocument": Json::object({ "uri": Json::string(uri) }),
      "position": Json::object({
        "line": Json::number(1.0),
        "character": Json::number(2.0),
      }),
    }),
  })
  let (resp, notifications) = server.handle_message(hover_req)
  assert_eq(notifications.length(), 0)
  match resp {
    Some(response) =>
      match response.result {
        Some(Json::Object(obj)) =>
          match obj.get("contents") {
            Some(Json::Object(contents)) =>
              match contents.get("value") {
                Some(Json::String(value)) => {
                  assert_true(value.contains("alpha"))
                  assert_true(value.contains("hash: `"))
                }
                _ => fail("hover contents value missing")
              }
            _ => fail("hover contents missing")
          }
        _ => fail("expected hover object")
      }
    None => fail("expected hover response")
  }
}

///|
test "trait_import_code_actions skips already imported trait" {
  let source =
    #|import { Eq } from "./xsh/std/builtin_traits.xsh"
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
