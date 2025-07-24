use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::*;
use tracing::debug;

use crate::backend::XSLanguageServer;
use vibe_core::parser;

pub async fn handle_hover(
    server: &XSLanguageServer,
    params: HoverParams,
) -> Result<Option<Hover>> {
    let uri = &params.text_document_position_params.text_document.uri;
    let position = params.text_document_position_params.position;
    
    debug!("Hover request at {:?} position {:?}", uri, position);
    
    // Get document content
    let content = match server.documents().get(uri) {
        Some(doc) => doc,
        None => return Ok(None),
    };
    
    // Get source map
    let source_map = match server.source_maps().get(uri) {
        Some(map) => map,
        None => return Ok(None),
    };
    
    // Find the node at the hover position
    let node_range = match source_map.find_node_at_position(position) {
        Some(range) => range,
        None => return Ok(None),
    };
    
    // Parse the document
    let expr = match parser::parse(&content) {
        Ok(result) => result,
        Err(_) => return Ok(None),
    };
    
    // Type check to get type information
    let expr_type = match vibe_compiler::type_check(&expr) {
        Ok(t) => t,
        Err(_) => return Ok(None),
    };
    
    // Create hover content
    let hover_text = format!(
        "**Type**: `{}`\n\n**Vibe Language**",
        expr_type
    );
    
    let hover = Hover {
        contents: HoverContents::Markup(MarkupContent {
            kind: MarkupKind::Markdown,
            value: hover_text,
        }),
        range: Some(node_range),
    };
    
    Ok(Some(hover))
}