use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::*;
use tracing::debug;

use crate::lsp::backend::XSLanguageServer;

pub async fn handle_references(
    server: &XSLanguageServer,
    params: ReferenceParams,
) -> Result<Option<Vec<Location>>> {
    let uri = &params.text_document_position.text_document.uri;
    let position = params.text_document_position.position;

    debug!("References request at {:?} position {:?}", uri, position);

    // Get document content
    let _content = match server.documents().get(uri) {
        Some(doc) => doc,
        None => return Ok(None),
    };

    // TODO: Implement actual references finding logic
    // This requires:
    // 1. Finding the identifier at the position
    // 2. Searching for all references to that identifier
    // 3. Converting to LSP Locations

    // For now, return empty list
    Ok(Some(vec![]))
}
