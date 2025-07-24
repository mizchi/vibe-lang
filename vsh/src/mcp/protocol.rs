//! MCP Protocol Definitions
//!
//! Defines the protocol messages for MCP communication.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// MCP Request types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum McpRequest {
    /// Initialize the MCP connection
    Initialize {
        protocol_version: String,
        capabilities: ClientCapabilities,
    },

    /// List available tools
    ToolsList,

    /// Execute a tool
    ToolsCall { tool_name: String, arguments: Value },

    /// List available resources
    ResourcesList,

    /// Read a resource
    ResourcesRead { uri: String },

    /// List available prompts
    PromptsList,

    /// Get a prompt
    PromptsGet {
        name: String,
        arguments: Option<Value>,
    },

    /// Completion request
    Completion {
        ref_: ResourceReference,
        context: Option<Value>,
    },

    /// Cancel a request
    Cancel { request_id: String },
}

/// MCP Response types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum McpResponse {
    /// Initialize response
    Initialize {
        protocol_version: String,
        capabilities: ServerCapabilities,
        server_info: ServerInfo,
    },

    /// Tools list response
    ToolsList { tools: Vec<Tool> },

    /// Tool execution result
    ToolsCall { content: Vec<ToolResult> },

    /// Resources list response
    ResourcesList { resources: Vec<Resource> },

    /// Resource content
    ResourcesRead { contents: Vec<ResourceContent> },

    /// Prompts list response
    PromptsList { prompts: Vec<Prompt> },

    /// Prompt content
    PromptsGet { messages: Vec<PromptMessage> },

    /// Completion response
    Completion { completion: CompletionResult },

    /// Error response
    Error {
        code: i32,
        message: String,
        data: Option<Value>,
    },
}

/// Client capabilities
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ClientCapabilities {
    pub experimental: Option<Value>,
    pub sampling: Option<Value>,
    pub roots: Option<RootsCapability>,
}

/// Server capabilities
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerCapabilities {
    pub tools: Option<ToolsCapability>,
    pub resources: Option<ResourcesCapability>,
    pub prompts: Option<PromptsCapability>,
    pub logging: Option<Value>,
}

/// Server information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
}

/// Tool definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tool {
    pub name: String,
    pub description: Option<String>,
    pub input_schema: Value,
}

/// Tool execution result
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ToolResult {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image { data: String, mime_type: String },
    #[serde(rename = "resource")]
    Resource { resource: ResourceReference },
}

/// Resource definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Resource {
    pub uri: String,
    pub name: String,
    pub description: Option<String>,
    pub mime_type: Option<String>,
}

/// Resource content
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceContent {
    pub uri: String,
    pub mime_type: Option<String>,
    pub text: Option<String>,
    pub blob: Option<String>,
}

/// Resource reference
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceReference {
    #[serde(rename = "type")]
    pub ref_type: String,
    pub uri: String,
}

/// Prompt definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Prompt {
    pub name: String,
    pub description: Option<String>,
    pub arguments: Option<Vec<PromptArgument>>,
}

/// Prompt argument
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptArgument {
    pub name: String,
    pub description: Option<String>,
    pub required: Option<bool>,
}

/// Prompt message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptMessage {
    pub role: String,
    pub content: PromptContent,
}

/// Prompt content
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum PromptContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image { data: String, mime_type: String },
    #[serde(rename = "resource")]
    Resource { resource: ResourceReference },
}

/// Completion result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionResult {
    pub values: Vec<Value>,
    pub total: Option<i32>,
    pub has_more: Option<bool>,
}

/// Roots capability
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RootsCapability {
    pub list_changed: Option<bool>,
}

/// Tools capability
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolsCapability {
    pub list_changed: Option<bool>,
}

/// Resources capability
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourcesCapability {
    pub subscribe: Option<bool>,
    pub list_changed: Option<bool>,
}

/// Prompts capability
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptsCapability {
    pub list_changed: Option<bool>,
}
