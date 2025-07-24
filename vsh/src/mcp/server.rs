//! MCP Server Implementation
//!
//! HTTP server that handles MCP protocol requests.

use axum::{
    extract::State,
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use std::sync::Arc;
use tokio::sync::RwLock;
use tower::ServiceBuilder;
use tracing::{info, error};

use super::{
    handlers,
    protocol::{McpRequest, McpResponse},
};
use anyhow;

/// MCP Server state
pub struct McpServerState {
    /// Server version
    pub version: String,
    /// Workspace manager (if initialized)
    pub workspace: Option<vibe_workspace::CodebaseManager>,
}

/// MCP Server
pub struct McpServer {
    state: Arc<RwLock<McpServerState>>,
}

impl Default for McpServer {
    fn default() -> Self {
        Self::new()
    }
}

impl McpServer {
    /// Create a new MCP server
    pub fn new() -> Self {
        let state = McpServerState {
            version: env!("CARGO_PKG_VERSION").to_string(),
            workspace: None,
        };
        
        Self {
            state: Arc::new(RwLock::new(state)),
        }
    }
    
    /// Build the router
    pub fn router(self) -> Router {
        Router::new()
            .route("/mcp", post(handle_mcp_request))
            .layer(
                ServiceBuilder::new()
                    .layer(axum::middleware::from_fn(logging_middleware))
            )
            .with_state(self.state)
    }
    
    /// Run the server
    pub async fn run(self, addr: &str) -> Result<(), Box<dyn std::error::Error>> {
        let listener = tokio::net::TcpListener::bind(addr).await?;
        info!("MCP server listening on {}", addr);
        
        axum::serve(listener, self.router()).await?;
        Ok(())
    }
}

/// Main MCP request handler
async fn handle_mcp_request(
    State(state): State<Arc<RwLock<McpServerState>>>,
    Json(request): Json<McpRequest>,
) -> impl IntoResponse {
    let response = match handlers::handle_request(&state, request).await {
        Ok(response) => response,
        Err(e) => {
            error!("Error handling MCP request: {}", e);
            McpResponse::Error {
                code: -32603,
                message: format!("Internal error: {e}"),
                data: None,
            }
        }
    };
    
    Json(response)
}

/// Run the MCP server
pub async fn run_server(port: u16) -> anyhow::Result<()> {
    let server = McpServer::new();
    let state = server.state.clone();
    
    let app = Router::new()
        .route("/", post(handle_mcp_request))
        .layer(
            ServiceBuilder::new()
                .layer(axum::middleware::from_fn(logging_middleware))
        )
        .with_state(state);
    
    let addr = format!("0.0.0.0:{}", port);
    info!("MCP server listening on {}", addr);
    
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;
    
    Ok(())
}

/// Logging middleware
async fn logging_middleware(
    request: axum::http::Request<axum::body::Body>,
    next: axum::middleware::Next,
) -> impl IntoResponse {
    let method = request.method().clone();
    let uri = request.uri().clone();
    
    info!("Request: {} {}", method, uri);
    
    let response = next.run(request).await;
    
    info!("Response: {}", response.status());
    
    response
}