//! MCP Tools for XS Language
//!
//! Provides tools that AI assistants can use to interact with XS code.

use serde::Deserialize;
use serde_json::{json, Value};
use xs_compiler::type_check;
use crate::protocol::{Tool, ToolResult};

/// Get all available tools
pub fn get_tools() -> Vec<Tool> {
    vec![
        Tool {
            name: "xs_parse".to_string(),
            description: Some("Parse XS code and return the AST".to_string()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "XS code to parse"
                    }
                },
                "required": ["code"]
            }),
        },
        Tool {
            name: "xs_typecheck".to_string(),
            description: Some("Type check XS code and return the type".to_string()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "XS code to type check"
                    }
                },
                "required": ["code"]
            }),
        },
        Tool {
            name: "xs_search".to_string(),
            description: Some("Search XS codebase using various queries".to_string()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "query_type": {
                        "type": "string",
                        "enum": ["type_pattern", "ast_pattern", "depends_on", "depended_by", "name_pattern"],
                        "description": "Type of search query"
                    },
                    "pattern": {
                        "type": "string",
                        "description": "Search pattern"
                    },
                    "transitive": {
                        "type": "boolean",
                        "description": "Include transitive dependencies",
                        "default": false
                    }
                },
                "required": ["query_type", "pattern"]
            }),
        },
        Tool {
            name: "xs_ast_transform".to_string(),
            description: Some("Apply AST transformations to XS code".to_string()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "XS code to transform"
                    },
                    "transform": {
                        "type": "object",
                        "properties": {
                            "type": {
                                "type": "string",
                                "enum": ["rename", "replace", "extract", "inline", "wrap"],
                                "description": "Type of transformation"
                            },
                            "params": {
                                "type": "object",
                                "description": "Parameters for the transformation"
                            }
                        },
                        "required": ["type", "params"]
                    }
                },
                "required": ["code", "transform"]
            }),
        },
        Tool {
            name: "xs_analyze_dependencies".to_string(),
            description: Some("Analyze dependencies of XS code".to_string()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "XS code to analyze"
                    },
                    "include_stdlib": {
                        "type": "boolean",
                        "description": "Include standard library dependencies",
                        "default": false
                    }
                },
                "required": ["code"]
            }),
        },
        Tool {
            name: "xs_effect_analysis".to_string(),
            description: Some("Analyze effects and required permissions".to_string()),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "code": {
                        "type": "string",
                        "description": "XS code to analyze for effects"
                    }
                },
                "required": ["code"]
            }),
        },
    ]
}

/// Execute a tool with given arguments
pub async fn execute_tool(tool_name: &str, arguments: Value) -> Result<Vec<ToolResult>, String> {
    match tool_name {
        "xs_parse" => execute_parse(arguments).await,
        "xs_typecheck" => execute_typecheck(arguments).await,
        "xs_search" => execute_search(arguments).await,
        "xs_ast_transform" => execute_ast_transform(arguments).await,
        "xs_analyze_dependencies" => execute_analyze_dependencies(arguments).await,
        "xs_effect_analysis" => execute_effect_analysis(arguments).await,
        _ => Err(format!("Unknown tool: {}", tool_name)),
    }
}

/// Parse XS code
async fn execute_parse(args: Value) -> Result<Vec<ToolResult>, String> {
    #[derive(Deserialize)]
    struct ParseArgs {
        code: String,
    }
    
    let args: ParseArgs = serde_json::from_value(args)
        .map_err(|e| format!("Invalid arguments: {}", e))?;
    
    match xs_core::parser::parse(&args.code) {
        Ok(expr) => {
            let ast_json = serde_json::to_string_pretty(&expr)
                .map_err(|e| format!("Failed to serialize AST: {}", e))?;
            
            Ok(vec![ToolResult::Text { 
                text: format!("Successfully parsed XS code:\n```json\n{}\n```", ast_json)
            }])
        }
        Err(e) => Err(format!("Parse error: {}", e))
    }
}

/// Type check XS code
async fn execute_typecheck(args: Value) -> Result<Vec<ToolResult>, String> {
    #[derive(Deserialize)]
    struct TypeCheckArgs {
        code: String,
    }
    
    let args: TypeCheckArgs = serde_json::from_value(args)
        .map_err(|e| format!("Invalid arguments: {}", e))?;
    
    let expr = xs_core::parser::parse(&args.code)
        .map_err(|e| format!("Parse error: {}", e))?;
    
    match type_check(&expr) {
        Ok(ty) => {
            Ok(vec![ToolResult::Text { 
                text: format!("Type check successful!\nType: {}", ty)
            }])
        }
        Err(e) => Err(format!("Type error: {}", e))
    }
}

/// Search codebase
async fn execute_search(args: Value) -> Result<Vec<ToolResult>, String> {
    #[derive(Deserialize)]
    struct SearchArgs {
        query_type: String,
        pattern: String,
        transitive: Option<bool>,
    }
    
    let args: SearchArgs = serde_json::from_value(args)
        .map_err(|e| format!("Invalid arguments: {}", e))?;
    
    // Save pattern for later use
    let pattern = args.pattern.clone();
    
    // Create a temporary workspace to demonstrate search
    // In a real implementation, this would use an existing workspace
    use xs_workspace::code_query::{CodeQuery, TypePattern, AstPattern, AstNodeType};
    use xs_workspace::namespace::DefinitionPath;
    
    let _query = match args.query_type.as_str() {
        "type_pattern" => {
            // Parse type pattern
            match args.pattern.as_str() {
                "Int -> Int" => CodeQuery::TypePattern(TypePattern::Function {
                    input: Some(Box::new(TypePattern::Exact(xs_core::Type::Int))),
                    output: Some(Box::new(TypePattern::Exact(xs_core::Type::Int))),
                }),
                pattern => {
                    return Err(format!("Unsupported type pattern: {}", pattern));
                }
            }
        }
        "ast_pattern" => {
            match args.pattern.as_str() {
                "match" => CodeQuery::AstPattern(AstPattern::Contains(AstNodeType::Match)),
                "rec" | "recursive" => CodeQuery::AstPattern(AstPattern::Contains(AstNodeType::Lambda)), // Rec functions are lambdas
                pattern => {
                    return Err(format!("Unsupported AST pattern: {}", pattern));
                }
            }
        }
        "name_pattern" => {
            CodeQuery::NamePattern(args.pattern)
        }
        "depends_on" => {
            // Parse definition path
            let parts: Vec<&str> = args.pattern.split('.').collect();
            if parts.is_empty() {
                return Err("Invalid definition path".to_string());
            }
            
            let path = DefinitionPath {
                namespace: if parts.len() > 1 {
                    xs_workspace::namespace::NamespacePath(
                        parts[..parts.len()-1].iter().map(|s| s.to_string()).collect()
                    )
                } else {
                    xs_workspace::namespace::NamespacePath(vec![])
                },
                name: parts.last().unwrap().to_string(),
            };
            
            CodeQuery::DependsOn {
                target: path,
                transitive: args.transitive.unwrap_or(false),
            }
        }
        _ => {
            return Err(format!("Unknown query type: {}", args.query_type));
        }
    };
    
    // For now, return a placeholder result
    // In a real implementation, this would search the actual codebase
    let mut result = String::new();
    result.push_str(&format!("Search Results for {} query '{}'\n\n", args.query_type, pattern));
    result.push_str("Found 0 matches\n");
    result.push_str("\n(Note: This is a placeholder. Connect to an actual workspace for real results)");
    
    Ok(vec![ToolResult::Text { text: result }])
}

/// Apply AST transformation
async fn execute_ast_transform(args: Value) -> Result<Vec<ToolResult>, String> {
    #[derive(Deserialize)]
    struct TransformArgs {
        code: String,
        transform: TransformSpec,
    }
    
    #[derive(Deserialize)]
    struct TransformSpec {
        #[serde(rename = "type")]
        transform_type: String,
        params: Value,
    }
    
    let args: TransformArgs = serde_json::from_value(args)
        .map_err(|e| format!("Invalid arguments: {}", e))?;
    
    // Parse the input code
    let expr = xs_core::parser::parse(&args.code)
        .map_err(|e| format!("Parse error: {}", e))?;
    
    // Apply transformation based on type
    let transformed_expr = match args.transform.transform_type.as_str() {
        "rename" => {
            #[derive(Deserialize)]
            struct RenameParams {
                old_name: String,
                new_name: String,
            }
            let params: RenameParams = serde_json::from_value(args.transform.params)
                .map_err(|e| format!("Invalid rename params: {}", e))?;
            
            // Simple rename implementation (placeholder)
            // In a real implementation, this would use AST transformation utilities
            use xs_core::pretty_print::pretty_print;
            let pretty = pretty_print(&expr);
            let transformed = pretty.replace(&params.old_name, &params.new_name);
            
            format!("Renamed '{}' to '{}' in code:\n\n{}", 
                   params.old_name, params.new_name, transformed)
        }
        
        "extract" => {
            #[derive(Deserialize)]
            struct ExtractParams {
                function_name: String,
                start_line: Option<usize>,
                end_line: Option<usize>,
            }
            let params: ExtractParams = serde_json::from_value(args.transform.params)
                .map_err(|e| format!("Invalid extract params: {}", e))?;
            
            format!("Extract function '{}' (not yet implemented)", params.function_name)
        }
        
        "inline" => {
            #[derive(Deserialize)]
            struct InlineParams {
                function_name: String,
            }
            let params: InlineParams = serde_json::from_value(args.transform.params)
                .map_err(|e| format!("Invalid inline params: {}", e))?;
            
            format!("Inline function '{}' (not yet implemented)", params.function_name)
        }
        
        "wrap" => {
            #[derive(Deserialize)]
            struct WrapParams {
                wrapper_name: String,
                wrapper_type: Option<String>,
            }
            let params: WrapParams = serde_json::from_value(args.transform.params)
                .map_err(|e| format!("Invalid wrap params: {}", e))?;
            
            format!("Wrap in '{}' (not yet implemented)", params.wrapper_name)
        }
        
        _ => {
            return Err(format!("Unknown transformation type: {}", args.transform.transform_type));
        }
    };
    
    Ok(vec![ToolResult::Text { text: transformed_expr }])
}

/// Analyze dependencies
async fn execute_analyze_dependencies(args: Value) -> Result<Vec<ToolResult>, String> {
    #[derive(Deserialize)]
    struct AnalyzeArgs {
        code: String,
        include_stdlib: Option<bool>,
    }
    
    let args: AnalyzeArgs = serde_json::from_value(args)
        .map_err(|e| format!("Invalid arguments: {}", e))?;
    
    let _expr = xs_core::parser::parse(&args.code)
        .map_err(|e| format!("Parse error: {}", e))?;
    
    // TODO: Implement actual dependency analysis
    Ok(vec![ToolResult::Text { 
        text: "Dependency analysis completed (implementation pending)".to_string()
    }])
}

/// Analyze effects and permissions
async fn execute_effect_analysis(args: Value) -> Result<Vec<ToolResult>, String> {
    #[derive(Deserialize)]
    struct EffectArgs {
        code: String,
    }
    
    let args: EffectArgs = serde_json::from_value(args)
        .map_err(|e| format!("Invalid arguments: {}", e))?;
    
    let expr = xs_core::parser::parse(&args.code)
        .map_err(|e| format!("Parse error: {}", e))?;
    
    match type_check(&expr) {
        Ok(ty) => {
            let effects = xs_core::effect_extraction::extract_all_possible_effects(&ty);
            let permissions = xs_core::permission::PermissionSet::from_effects(&effects);
            
            let mut result = String::new();
            result.push_str("Effect Analysis Results:\n\n");
            
            if effects.is_pure() {
                result.push_str("This code is pure (no side effects)\n");
            } else {
                result.push_str(&format!("Effects: {}\n", effects));
                result.push_str(&format!("Required permissions: {}\n", permissions));
            }
            
            Ok(vec![ToolResult::Text { text: result }])
        }
        Err(e) => Err(format!("Type error during effect analysis: {}", e))
    }
}