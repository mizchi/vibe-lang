///|
/// LSP Server main loop

///|
pub(all) struct LspServer {
  documents : DocumentManager
  mut initialized : Bool
  mut shutdown_requested : Bool
} derive(Show, Eq)

///|
pub fn LspServer::new() -> LspServer {
  LspServer::{
    documents: DocumentManager::new(),
    initialized: false,
    shutdown_requested: false,
  }
}

///|
/// Process a single JSON-RPC request and return response (if any)
pub fn LspServer::handle_message(
  self : LspServer,
  json : Json,
) -> (JsonRpcResponse?, Array[Json]) {
  let notifications : Array[Json] = []
  let req = match parse_request(json) {
    Some(r) => r
    None =>
      return (
        Some(make_error_response(None, -32700, "Parse error")),
        notifications,
      )
  }
  match req.meth {
    "initialize" => {
      self.initialized = true
      (Some(handle_initialize(req.id)), notifications)
    }
    "initialized" =>
      // No response needed for notification
      (None, notifications)
    "shutdown" => {
      self.shutdown_requested = true
      (Some(handle_shutdown(req.id)), notifications)
    }
    "exit" =>
      // Exit is handled by caller
      (None, notifications)
    "textDocument/didOpen" => {
      match req.params {
        Some(Json::Object(obj)) =>
          match parse_text_document_item(obj.get("textDocument")) {
            Some(doc) => {
              self.documents.open(doc.uri, doc.text, doc.version)
              // Check and publish diagnostics
              let (diagnostics, _) = check_document(doc.uri, doc.text)
              notifications.push(publish_diagnostics_json(doc.uri, diagnostics))
            }
            None => ()
          }
        _ => ()
      }
      (None, notifications)
    }
    "textDocument/didChange" => {
      match req.params {
        Some(Json::Object(obj)) =>
          match
            parse_versioned_text_document_identifier(obj.get("textDocument")) {
            Some(doc_id) => {
              let changes = parse_content_changes(obj.get("contentChanges"))
              if changes.length() > 0 {
                let new_text = changes[changes.length() - 1].text
                self.documents.update(doc_id.uri, new_text, doc_id.version)
                // Check and publish diagnostics
                let (diagnostics, _) = check_document(doc_id.uri, new_text)
                notifications.push(
                  publish_diagnostics_json(doc_id.uri, diagnostics),
                )
              }
            }
            None => ()
          }
        _ => ()
      }
      (None, notifications)
    }
    "textDocument/didClose" => {
      match req.params {
        Some(Json::Object(obj)) =>
          match parse_text_document_identifier(obj.get("textDocument")) {
            Some(doc_id) => {
              self.documents.close(doc_id.uri)
              // Clear diagnostics
              notifications.push(publish_diagnostics_json(doc_id.uri, []))
            }
            None => ()
          }
        _ => ()
      }
      (None, notifications)
    }
    "textDocument/codeAction" =>
      match req.id {
        Some(id) => {
          let result = match req.params {
            Some(Json::Object(obj)) =>
              match parse_text_document_identifier(obj.get("textDocument")) {
                Some(doc_id) =>
                  match self.documents.get(doc_id.uri) {
                    Some(source) =>
                      trait_import_code_actions(doc_id.uri, source)
                    None => Json::array([])
                  }
                None => Json::array([])
              }
            _ => Json::array([])
          }
          (Some(make_response(Some(id), result)), notifications)
        }
        None => (None, notifications)
      }
    _ =>
      // Unknown method
      match req.id {
        Some(id) =>
          (
            Some(
              make_error_response(
                Some(id),
                -32601,
                "Method not found: " + req.meth,
              ),
            ),
            notifications,
          )
        None => (None, notifications) // Notification - ignore unknown
      }
  }
}

///|
pub fn LspServer::is_exit_requested(self : LspServer) -> Bool {
  self.shutdown_requested
}
