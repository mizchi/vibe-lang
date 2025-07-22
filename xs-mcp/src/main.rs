//! XS MCP Server Binary
//!
//! Run the MCP server for XS language.

use tracing_subscriber;
use xs_mcp::McpServer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize tracing
    tracing_subscriber::fmt::init();
    
    // Get server address from environment or use default
    let addr = std::env::var("XS_MCP_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:3000".to_string());
    
    // Create and run server
    let server = McpServer::new();
    println!("Starting XS MCP server on {}", addr);
    
    server.run(&addr).await?;
    
    Ok(())
}