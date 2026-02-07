///|
/// LSP method handlers

///|
pub fn handle_initialize(id : JsonRpcId?) -> JsonRpcResponse {
  let capabilities : Map[String, Json] = {}

  // Text document sync - full sync mode
  let sync_options : Map[String, Json] = {}
  sync_options["openClose"] = Json::boolean(true)
  sync_options["change"] = Json::number(1.0) // Full sync
  capabilities["textDocumentSync"] = Json::object(sync_options)
  let result : Map[String, Json] = {}
  result["capabilities"] = Json::object(capabilities)
  make_response(id, Json::object(result))
}

///|
pub fn handle_shutdown(id : JsonRpcId?) -> JsonRpcResponse {
  make_response(id, Json::null())
}

///|
/// Check document and return diagnostics
pub fn check_document(
  _uri : String,
  source : String,
) -> (Array[LspDiagnostic], Bool) {
  let diagnostics : Array[LspDiagnostic] = []

  // Parse
  let ast = @parser.parse_ast(source) catch {
    e => {
      let diag = e.diagnostic()
      diagnostics.push(to_lsp_diagnostic(diag, source))
      return (diagnostics, false)
    }
  }

  // Type check
  let type_result = Ok(@checker.type_check(ast)) catch { e => Err(e) }
  match type_result {
    Err(e) => {
      let diag = e.diagnostic()
      diagnostics.push(to_lsp_diagnostic(diag, source))
      (diagnostics, false)
    }
    Ok(_) => (diagnostics, true)
  }
}
