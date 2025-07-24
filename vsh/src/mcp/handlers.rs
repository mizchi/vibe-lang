//! MCP Request Handlers
//!
//! Handles different types of MCP protocol requests.

use std::sync::Arc;
use tokio::sync::RwLock;
use serde_json::json;

use super::{
    protocol::*,
    server::McpServerState,
    tools,
};

/// Handle an MCP request
pub async fn handle_request(
    state: &Arc<RwLock<McpServerState>>,
    request: McpRequest,
) -> Result<McpResponse, String> {
    match request {
        McpRequest::Initialize { protocol_version, capabilities } => {
            handle_initialize(state, protocol_version, capabilities).await
        }
        McpRequest::ToolsList => {
            handle_tools_list().await
        }
        McpRequest::ToolsCall { tool_name, arguments } => {
            handle_tools_call(tool_name, arguments).await
        }
        McpRequest::ResourcesList => {
            handle_resources_list(state).await
        }
        McpRequest::ResourcesRead { uri } => {
            handle_resources_read(state, uri).await
        }
        McpRequest::PromptsList => {
            handle_prompts_list().await
        }
        McpRequest::PromptsGet { name, arguments } => {
            handle_prompts_get(name, arguments).await
        }
        McpRequest::Completion { ref_, context } => {
            handle_completion(ref_, context).await
        }
        McpRequest::Cancel { request_id: _ } => {
            // TODO: Implement request cancellation
            Err("Cancellation not yet implemented".to_string())
        }
    }
}

/// Handle initialization
async fn handle_initialize(
    state: &Arc<RwLock<McpServerState>>,
    protocol_version: String,
    _capabilities: ClientCapabilities,
) -> Result<McpResponse, String> {
    let state = state.read().await;
    
    Ok(McpResponse::Initialize {
        protocol_version,
        capabilities: ServerCapabilities {
            tools: Some(ToolsCapability {
                list_changed: Some(false),
            }),
            resources: Some(ResourcesCapability {
                subscribe: Some(false),
                list_changed: Some(false),
            }),
            prompts: Some(PromptsCapability {
                list_changed: Some(false),
            }),
            logging: None,
        },
        server_info: ServerInfo {
            name: "xs-mcp-server".to_string(),
            version: state.version.clone(),
        },
    })
}

/// Handle tools list request
async fn handle_tools_list() -> Result<McpResponse, String> {
    Ok(McpResponse::ToolsList {
        tools: tools::get_tools(),
    })
}

/// Handle tool execution
async fn handle_tools_call(
    tool_name: String,
    arguments: serde_json::Value,
) -> Result<McpResponse, String> {
    let content = tools::execute_tool(&tool_name, arguments).await?;
    Ok(McpResponse::ToolsCall { content })
}

/// Handle resources list
async fn handle_resources_list(
    _state: &Arc<RwLock<McpServerState>>,
) -> Result<McpResponse, String> {
    Ok(McpResponse::ResourcesList {
        resources: vec![
            Resource {
                uri: "xs://workspace/definitions".to_string(),
                name: "Workspace Definitions".to_string(),
                description: Some("All definitions in the XS workspace".to_string()),
                mime_type: Some("application/json".to_string()),
            },
            Resource {
                uri: "xs://workspace/types".to_string(),
                name: "Type Definitions".to_string(),
                description: Some("All type definitions in the workspace".to_string()),
                mime_type: Some("application/json".to_string()),
            },
            Resource {
                uri: "xs://workspace/dependencies".to_string(),
                name: "Dependency Graph".to_string(),
                description: Some("Function dependency relationships".to_string()),
                mime_type: Some("application/json".to_string()),
            },
            Resource {
                uri: "xs://workspace/namespaces".to_string(),
                name: "Namespace Structure".to_string(),
                description: Some("Hierarchical namespace organization".to_string()),
                mime_type: Some("application/json".to_string()),
            },
        ],
    })
}

/// Handle resource read
async fn handle_resources_read(
    state: &Arc<RwLock<McpServerState>>,
    uri: String,
) -> Result<McpResponse, String> {
    let state = state.read().await;
    
    match uri.as_str() {
        "xs://workspace/definitions" => {
            // Get definitions from workspace if available
            let definitions = if let Some(_workspace) = &state.workspace {
                // In a real implementation, this would query the workspace
                json!({
                    "definitions": [
                        {
                            "name": "add",
                            "path": "Math.add",
                            "type": "(-> Int Int Int)",
                            "hash": "abc123...",
                            "dependencies": []
                        },
                        {
                            "name": "fibonacci",
                            "path": "Math.Utils.fibonacci",
                            "type": "(-> Int Int)",
                            "hash": "def456...",
                            "dependencies": ["Math.add"]
                        }
                    ],
                    "total": 2
                })
            } else {
                json!({
                    "definitions": [],
                    "total": 0,
                    "error": "No workspace loaded"
                })
            };
            
            Ok(McpResponse::ResourcesRead {
                contents: vec![ResourceContent {
                    uri,
                    mime_type: Some("application/json".to_string()),
                    text: Some(serde_json::to_string_pretty(&definitions).unwrap()),
                    blob: None,
                }],
            })
        }
        
        "xs://workspace/types" => {
            // Get type definitions
            let types = json!({
                "types": [
                    {
                        "name": "Option",
                        "kind": "ADT",
                        "params": ["a"],
                        "constructors": [
                            {"name": "None", "fields": []},
                            {"name": "Some", "fields": ["a"]}
                        ]
                    },
                    {
                        "name": "Result",
                        "kind": "ADT",
                        "params": ["e", "a"],
                        "constructors": [
                            {"name": "Error", "fields": ["e"]},
                            {"name": "Ok", "fields": ["a"]}
                        ]
                    }
                ],
                "total": 2
            });
            
            Ok(McpResponse::ResourcesRead {
                contents: vec![ResourceContent {
                    uri,
                    mime_type: Some("application/json".to_string()),
                    text: Some(serde_json::to_string_pretty(&types).unwrap()),
                    blob: None,
                }],
            })
        }
        
        "xs://workspace/dependencies" => {
            // Get dependency graph
            let deps = json!({
                "dependencies": {
                    "Math.Utils.fibonacci": ["Math.add"],
                    "Math.Utils.factorial": ["Math.mul"],
                    "List.map": [],
                    "List.foldLeft": []
                },
                "reverse_dependencies": {
                    "Math.add": ["Math.Utils.fibonacci", "Math.sum"],
                    "Math.mul": ["Math.Utils.factorial", "Math.product"]
                }
            });
            
            Ok(McpResponse::ResourcesRead {
                contents: vec![ResourceContent {
                    uri,
                    mime_type: Some("application/json".to_string()),
                    text: Some(serde_json::to_string_pretty(&deps).unwrap()),
                    blob: None,
                }],
            })
        }
        
        "xs://workspace/namespaces" => {
            // Get namespace structure
            let namespaces = json!({
                "namespaces": {
                    "": {
                        "definitions": ["add", "sub", "mul", "div"],
                        "subnamespaces": ["Math", "List", "String"]
                    },
                    "Math": {
                        "definitions": ["pi", "e", "sin", "cos"],
                        "subnamespaces": ["Utils"]
                    },
                    "Math.Utils": {
                        "definitions": ["fibonacci", "factorial", "gcd", "lcm"],
                        "subnamespaces": []
                    },
                    "List": {
                        "definitions": ["map", "filter", "foldLeft", "foldRight"],
                        "subnamespaces": []
                    },
                    "String": {
                        "definitions": ["concat", "length", "substring"],
                        "subnamespaces": []
                    }
                }
            });
            
            Ok(McpResponse::ResourcesRead {
                contents: vec![ResourceContent {
                    uri,
                    mime_type: Some("application/json".to_string()),
                    text: Some(serde_json::to_string_pretty(&namespaces).unwrap()),
                    blob: None,
                }],
            })
        }
        
        _ => Err(format!("Unknown resource: {uri}"))
    }
}

/// Handle prompts list
async fn handle_prompts_list() -> Result<McpResponse, String> {
    Ok(McpResponse::PromptsList {
        prompts: vec![
            Prompt {
                name: "explain_type".to_string(),
                description: Some("Explain an XS type signature".to_string()),
                arguments: Some(vec![
                    PromptArgument {
                        name: "type".to_string(),
                        description: Some("The type signature to explain".to_string()),
                        required: Some(true),
                    }
                ]),
            },
            Prompt {
                name: "generate_test".to_string(),
                description: Some("Generate test cases for XS code".to_string()),
                arguments: Some(vec![
                    PromptArgument {
                        name: "code".to_string(),
                        description: Some("The code to generate tests for".to_string()),
                        required: Some(true),
                    }
                ]),
            },
            Prompt {
                name: "suggest_refactoring".to_string(),
                description: Some("Suggest refactoring for XS code".to_string()),
                arguments: Some(vec![
                    PromptArgument {
                        name: "code".to_string(),
                        description: Some("The code to analyze".to_string()),
                        required: Some(true),
                    }
                ]),
            },
        ],
    })
}

/// Handle prompt get
async fn handle_prompts_get(
    name: String,
    arguments: Option<serde_json::Value>,
) -> Result<McpResponse, String> {
    let messages = match name.as_str() {
        "explain_type" => {
            let type_sig = arguments
                .as_ref()
                .and_then(|v| v.get("type"))
                .and_then(|v| v.as_str())
                .ok_or("Missing 'type' argument")?
                .to_string();
            
            vec![PromptMessage {
                role: "user".to_string(),
                content: PromptContent::Text {
                    text: format!("Please explain the following XS type signature:\n\n{type_sig}"),
                },
            }]
        }
        "generate_test" => {
            let code = arguments
                .as_ref()
                .and_then(|v| v.get("code"))
                .and_then(|v| v.as_str())
                .ok_or("Missing 'code' argument")?
                .to_string();
            
            vec![PromptMessage {
                role: "user".to_string(),
                content: PromptContent::Text {
                    text: format!("Please generate comprehensive test cases for the following XS code:\n\n```lisp\n{code}\n```"),
                },
            }]
        }
        "suggest_refactoring" => {
            let code = arguments
                .as_ref()
                .and_then(|v| v.get("code"))
                .and_then(|v| v.as_str())
                .ok_or("Missing 'code' argument")?
                .to_string();
            
            vec![PromptMessage {
                role: "user".to_string(),
                content: PromptContent::Text {
                    text: format!("Please suggest refactoring improvements for the following XS code:\n\n```lisp\n{code}\n```"),
                },
            }]
        }
        _ => return Err(format!("Unknown prompt: {name}"))
    };
    
    Ok(McpResponse::PromptsGet { messages })
}

/// Handle completion request
async fn handle_completion(
    ref_: ResourceReference,
    context: Option<serde_json::Value>,
) -> Result<McpResponse, String> {
    // Analyze context to provide completions
    let completions = match ref_.ref_type.as_str() {
        "function" => {
            // Function name completions
            vec![
                json!({
                    "label": "add",
                    "kind": "function",
                    "detail": "(-> Int Int Int)",
                    "documentation": "Add two integers"
                }),
                json!({
                    "label": "foldLeft",
                    "kind": "function", 
                    "detail": "(-> (List a) b (-> b a b) b)",
                    "documentation": "Left fold over a list"
                }),
                json!({
                    "label": "map",
                    "kind": "function",
                    "detail": "(-> (List a) (-> a b) (List b))",
                    "documentation": "Map a function over a list"
                }),
            ]
        }
        "type" => {
            // Type completions
            vec![
                json!({
                    "label": "Int",
                    "kind": "type",
                    "detail": "Integer type",
                    "documentation": "64-bit signed integer"
                }),
                json!({
                    "label": "String",
                    "kind": "type",
                    "detail": "String type",
                    "documentation": "UTF-8 encoded string"
                }),
                json!({
                    "label": "List",
                    "kind": "type",
                    "detail": "(List a)",
                    "documentation": "Homogeneous list type"
                }),
                json!({
                    "label": "Option",
                    "kind": "type",
                    "detail": "(Option a)",
                    "documentation": "Optional value type"
                }),
            ]
        }
        "keyword" => {
            // Keyword completions
            vec![
                json!({
                    "label": "let",
                    "kind": "keyword",
                    "detail": "Variable binding",
                    "insertText": "let ${1:name} ${2:value}"
                }),
                json!({
                    "label": "rec",
                    "kind": "keyword",
                    "detail": "Recursive function",
                    "insertText": "rec ${1:name} (${2:params}) ${3:body}"
                }),
                json!({
                    "label": "match",
                    "kind": "keyword",
                    "detail": "Pattern matching",
                    "insertText": "match ${1:expr}\n  (${2:pattern} ${3:result})"
                }),
                json!({
                    "label": "type",
                    "kind": "keyword",
                    "detail": "Type definition",
                    "insertText": "type ${1:Name} ${2:params}\n  (${3:Constructor} ${4:fields})"
                }),
            ]
        }
        _ => {
            // Default completions based on context
            if let Some(ctx) = context {
                if let Some(prefix) = ctx.get("prefix").and_then(|v| v.as_str()) {
                    // Filter completions based on prefix
                    match prefix {
                        "Int." => vec![
                            json!({
                                "label": "Int.add",
                                "kind": "function",
                                "detail": "(-> Int Int Int)"
                            }),
                            json!({
                                "label": "Int.toString",
                                "kind": "function",
                                "detail": "(-> Int String)"
                            }),
                        ],
                        "List." => vec![
                            json!({
                                "label": "List.map",
                                "kind": "function",
                                "detail": "(-> (List a) (-> a b) (List b))"
                            }),
                            json!({
                                "label": "List.filter",
                                "kind": "function",
                                "detail": "(-> (List a) (-> a Bool) (List a))"
                            }),
                        ],
                        _ => vec![]
                    }
                } else {
                    vec![]
                }
            } else {
                vec![]
            }
        }
    };
    
    let total = completions.len() as i32;
    
    Ok(McpResponse::Completion {
        completion: CompletionResult {
            values: completions,
            total: Some(total),
            has_more: Some(false),
        },
    })
}