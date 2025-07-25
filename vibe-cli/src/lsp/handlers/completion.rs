use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::*;
use tracing::debug;

use crate::lsp::backend::XSLanguageServer;

pub async fn handle_completion(
    server: &XSLanguageServer,
    params: CompletionParams,
) -> Result<Option<CompletionResponse>> {
    let uri = &params.text_document_position.text_document.uri;
    let position = params.text_document_position.position;

    debug!("Completion request at {:?} position {:?}", uri, position);

    // Get document content
    let _content = match server.documents().get(uri) {
        Some(doc) => doc,
        None => return Ok(None),
    };

    // Create basic completions
    let mut items = vec![];

    // Add XS language keywords
    let keywords = vec![
        "let", "rec", "in", "fn", "if", "then", "else", "match", "case", "of", "type", "module",
        "import", "export", "perform", "handle", "with", "end",
    ];

    for keyword in keywords {
        items.push(CompletionItem {
            label: keyword.to_string(),
            kind: Some(CompletionItemKind::KEYWORD),
            detail: Some(format!("XS keyword: {}", keyword)),
            ..Default::default()
        });
    }

    // Add builtin functions
    let builtins = vec![
        ("String.concat", "String -> String -> String"),
        ("List.car", "List a -> a"),
        ("List.cdr", "List a -> List a"),
        ("List.null", "List a -> Bool"),
        ("cons", "a -> List a -> List a"),
        ("print", "String -> IO ()"),
    ];

    for (name, type_sig) in builtins {
        items.push(CompletionItem {
            label: name.to_string(),
            kind: Some(CompletionItemKind::FUNCTION),
            detail: Some(type_sig.to_string()),
            documentation: Some(Documentation::String(format!(
                "Built-in function: {}",
                name
            ))),
            ..Default::default()
        });
    }

    Ok(Some(CompletionResponse::Array(items)))
}
