use dashmap::DashMap;
use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::*;
use tower_lsp::{Client, LanguageServer};
use tracing::{debug, error, info};

use super::source_map::SourceMap;
use super::text_document::TextDocuments;

pub struct XSLanguageServer {
    client: Client,
    documents: TextDocuments,
    source_maps: DashMap<Url, SourceMap>,
}

impl XSLanguageServer {
    pub fn new(client: Client) -> Self {
        Self {
            client,
            documents: TextDocuments::new(),
            source_maps: DashMap::new(),
        }
    }

    pub fn client(&self) -> &Client {
        &self.client
    }

    pub fn documents(&self) -> &TextDocuments {
        &self.documents
    }

    pub fn source_maps(&self) -> &DashMap<Url, SourceMap> {
        &self.source_maps
    }

    async fn analyze_document(&self, uri: &Url) -> Result<()> {
        let content = match self.documents.get(uri) {
            Some(doc) => doc,
            None => return Ok(()),
        };

        debug!("Analyzing document: {}", uri);

        // Parse the document
        match vibe_language::parser::parse(&content) {
            Ok(expr) => {
                // Generate source map
                let source_map = SourceMap::from_ast(&expr, &content);
                self.source_maps.insert(uri.clone(), source_map);

                // Type check
                match vibe_compiler::type_check(&expr) {
                    Ok(_type) => {
                        // Clear diagnostics on successful type check
                        self.client
                            .publish_diagnostics(uri.clone(), vec![], None)
                            .await;
                    }
                    Err(e) => {
                        // Convert type errors to diagnostics
                        let diagnostic = self.type_error_to_diagnostic(e, uri);
                        self.client
                            .publish_diagnostics(uri.clone(), vec![diagnostic], None)
                            .await;
                    }
                }
            }
            Err(e) => {
                // Convert parse errors to diagnostics
                let diagnostic = self.parse_error_to_diagnostic(e, uri);
                self.client
                    .publish_diagnostics(uri.clone(), vec![diagnostic], None)
                    .await;
            }
        }

        Ok(())
    }

    fn parse_error_to_diagnostic(&self, error: vibe_language::XsError, _uri: &Url) -> Diagnostic {
        let (position, message) = match error {
            vibe_language::XsError::ParseError(pos, msg) => (pos, msg),
            _ => (0, format!("{}", error)),
        };

        let range = Range {
            start: Position {
                line: 0, // TODO: Convert position to line/column
                character: position as u32,
            },
            end: Position {
                line: 0,
                character: (position + 1) as u32,
            },
        };

        Diagnostic {
            range,
            severity: Some(DiagnosticSeverity::ERROR),
            code: None,
            code_description: None,
            source: Some("xs".to_string()),
            message,
            related_information: None,
            tags: None,
            data: None,
        }
    }

    fn type_error_to_diagnostic(&self, error: vibe_language::XsError, _uri: &Url) -> Diagnostic {
        let (span, message) = match error {
            vibe_language::XsError::TypeError(span, msg) => (span, msg),
            _ => (vibe_language::Span::new(0, 0), format!("{}", error)),
        };

        let range = Range {
            start: Position {
                line: 0, // TODO: Convert span to line/column using source map
                character: span.start as u32,
            },
            end: Position {
                line: 0,
                character: span.end as u32,
            },
        };

        Diagnostic {
            range,
            severity: Some(DiagnosticSeverity::ERROR),
            code: None,
            code_description: None,
            source: Some("xs".to_string()),
            message,
            related_information: None,
            tags: None,
            data: None,
        }
    }
}

#[tower_lsp::async_trait]
impl LanguageServer for XSLanguageServer {
    async fn initialize(&self, params: InitializeParams) -> Result<InitializeResult> {
        info!("Initializing XS Language Server");

        if let Some(root_uri) = params.root_uri {
            debug!("Workspace root: {}", root_uri);
            // Initialize workspace
            // TODO: Load workspace configuration
        }

        Ok(InitializeResult {
            capabilities: super::capabilities::server_capabilities(),
            ..Default::default()
        })
    }

    async fn initialized(&self, _: InitializedParams) {
        info!("XS Language Server initialized");
    }

    async fn shutdown(&self) -> Result<()> {
        info!("Shutting down XS Language Server");
        Ok(())
    }

    async fn did_open(&self, params: DidOpenTextDocumentParams) {
        let uri = params.text_document.uri;
        let text = params.text_document.text;

        debug!("Document opened: {}", uri);
        self.documents.open(uri.clone(), text);

        if let Err(e) = self.analyze_document(&uri).await {
            error!("Failed to analyze document: {}", e);
        }
    }

    async fn did_change(&self, params: DidChangeTextDocumentParams) {
        let uri = params.text_document.uri;

        for change in params.content_changes {
            // In full sync mode, we expect the full text
            self.documents.update(uri.clone(), change.text);
        }

        if let Err(e) = self.analyze_document(&uri).await {
            error!("Failed to analyze document: {}", e);
        }
    }

    async fn did_close(&self, params: DidCloseTextDocumentParams) {
        let uri = params.text_document.uri;
        debug!("Document closed: {}", uri);
        self.documents.close(&uri);
        self.source_maps.remove(&uri);
    }

    async fn hover(&self, params: HoverParams) -> Result<Option<Hover>> {
        super::handlers::hover::handle_hover(self, params).await
    }

    async fn goto_definition(
        &self,
        params: GotoDefinitionParams,
    ) -> Result<Option<GotoDefinitionResponse>> {
        super::handlers::goto_definition::handle_goto_definition(self, params).await
    }

    async fn references(&self, params: ReferenceParams) -> Result<Option<Vec<Location>>> {
        super::handlers::references::handle_references(self, params).await
    }

    async fn completion(&self, params: CompletionParams) -> Result<Option<CompletionResponse>> {
        super::handlers::completion::handle_completion(self, params).await
    }
}
