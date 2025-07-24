use tower_lsp::{LspService, Server};
use tracing::info;

mod backend;
mod capabilities;
mod handlers;
mod source_map;
mod text_document;

use backend::XSLanguageServer;

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();

    info!("Starting Vibe Language Server");

    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();

    let (service, socket) = LspService::new(|client| XSLanguageServer::new(client));
    
    Server::new(stdin, stdout, socket)
        .serve(service)
        .await;
}