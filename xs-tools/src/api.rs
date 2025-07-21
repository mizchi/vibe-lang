//! API mode for AI code manipulation
//!
//! This module provides a JSON-based API for AI tools to interact with the XS codebase.
//! All commands return structured JSON responses for easy parsing.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum ApiCommand {
    // Code manipulation
    Add {
        name: String,
        expr: String,
    },
    Update {
        name: String,
        expr: String,
    },
    Delete {
        name: String,
    },
    Rename {
        old_name: String,
        new_name: String,
    },

    // Query operations
    View {
        name: String,
    },
    List {
        pattern: Option<String>,
    },
    Find {
        query: String,
    },
    TypeOf {
        expr: String,
    },

    // Analysis operations
    Dependencies {
        name: String,
    },
    Dependents {
        name: String,
    },
    References {
        name: String,
    },

    // Transformation operations
    Inline {
        name: String,
        at: String,
    },
    Extract {
        expr: String,
        as_name: String,
    },
    Refactor {
        target: String,
        operation: RefactorOperation,
    },

    // Navigation
    Definition {
        name: String,
    },
    Hover {
        expr: String,
    },

    // Project management
    Commit {
        message: String,
    },
    Branch {
        name: String,
    },
    Merge {
        branch: String,
    },
    Status,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefactorOperation {
    RenameParameter { old: String, new: String },
    AddParameter { name: String, typ: String },
    RemoveParameter { name: String },
    ChangeType { new_type: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ApiResponse {
    Success {
        #[serde(flatten)]
        data: serde_json::Value,
    },
    Error {
        error: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        details: Option<String>,
    },
}

impl ApiResponse {
    pub fn success(data: impl Serialize) -> Self {
        ApiResponse::Success {
            data: serde_json::to_value(data).unwrap_or(json!({})),
        }
    }

    pub fn error(error: impl ToString) -> Self {
        ApiResponse::Error {
            error: error.to_string(),
            details: None,
        }
    }

    pub fn error_with_details(error: impl ToString, details: impl ToString) -> Self {
        ApiResponse::Error {
            error: error.to_string(),
            details: Some(details.to_string()),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct DefinitionInfo {
    pub name: String,
    pub hash: String,
    pub expr: String,
    pub typ: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ReferenceInfo {
    pub location: String,
    pub context: String,
    pub line: usize,
}

#[derive(Debug, Serialize)]
pub struct DependencyInfo {
    pub direct: Vec<String>,
    pub transitive: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct StatusInfo {
    pub branch: String,
    pub pending_changes: Vec<String>,
    pub definitions: usize,
}

/// Process an API command and return a JSON response
pub fn process_api_command(shell_state: &mut crate::ShellState, command: ApiCommand) -> String {
    let response = match command {
        ApiCommand::Add { name, expr } => {
            let full_expr = format!("(let {} {})", name, expr);
            match shell_state.evaluate_line(&full_expr) {
                Ok(_) => {
                    let _ = shell_state.update_codebase();
                    ApiResponse::success(json!({
                        "name": name,
                        "message": format!("Added definition: {}", name)
                    }))
                }
                Err(e) => ApiResponse::error_with_details("Failed to add definition", e),
            }
        }

        ApiCommand::View { name } => {
            match shell_state.view_definition(&name) {
                Ok(result) => {
                    // Parse the result to extract structured data
                    let info = DefinitionInfo {
                        name: name.clone(),
                        hash: "unknown".to_string(), // TODO: Extract from result
                        expr: result.clone(),
                        typ: "unknown".to_string(), // TODO: Extract type
                        value: None,
                    };
                    ApiResponse::success(info)
                }
                Err(e) => ApiResponse::error(e),
            }
        }

        ApiCommand::List { pattern } => {
            let definitions = shell_state.list_definitions(pattern.as_deref());
            let defs: Vec<_> = definitions
                .lines()
                .filter(|l| !l.is_empty() && !l.contains("No definitions"))
                .map(|line| {
                    // Parse "name : type [hash]"
                    let parts: Vec<&str> = line.split(" : ").collect();
                    if parts.len() >= 2 {
                        let name = parts[0].to_string();
                        let rest = parts[1];
                        let type_and_hash: Vec<&str> = rest.split(" [").collect();
                        let typ = type_and_hash
                            .get(0)
                            .map(|s| s.to_string())
                            .unwrap_or_default();
                        let hash = type_and_hash
                            .get(1)
                            .and_then(|s| s.strip_suffix(']'))
                            .map(|s| s.to_string())
                            .unwrap_or_default();
                        json!({
                            "name": name,
                            "type": typ,
                            "hash": hash
                        })
                    } else {
                        json!({ "raw": line })
                    }
                })
                .collect();
            ApiResponse::success(json!({ "definitions": defs }))
        }

        ApiCommand::TypeOf { expr } => match shell_state.type_of_expr(&expr) {
            Ok(result) => {
                let parts: Vec<&str> = result.split(" : ").collect();
                if parts.len() >= 2 {
                    ApiResponse::success(json!({
                        "expr": parts[0],
                        "type": parts[1]
                    }))
                } else {
                    ApiResponse::success(json!({ "result": result }))
                }
            }
            Err(e) => ApiResponse::error(e),
        },

        ApiCommand::Dependencies { name } => {
            let _deps = shell_state.show_dependencies(&name);
            ApiResponse::success(json!({
                "name": name,
                "dependencies": DependencyInfo {
                    direct: vec![],
                    transitive: vec![],
                }
            }))
        }

        ApiCommand::References { name } => {
            let refs = shell_state.find_references(&name);
            ApiResponse::success(json!({
                "name": name,
                "references": refs
            }))
        }

        ApiCommand::Hover { expr } => match shell_state.show_hover_info(&expr) {
            Ok(info) => ApiResponse::success(json!({ "info": info })),
            Err(e) => ApiResponse::error(e),
        },

        ApiCommand::Status => {
            let info = StatusInfo {
                branch: "main".to_string(),
                pending_changes: vec![],
                definitions: shell_state.named_exprs.len(),
            };
            ApiResponse::success(info)
        }

        _ => ApiResponse::error("Command not implemented yet"),
    };

    serde_json::to_string_pretty(&response).unwrap_or_else(|_| {
        r#"{"status":"error","error":"Failed to serialize response"}"#.to_string()
    })
}

/// Parse a JSON command string
pub fn parse_api_command(json_str: &str) -> Result<ApiCommand> {
    serde_json::from_str(json_str).map_err(|e| anyhow::anyhow!("Failed to parse command: {}", e))
}
