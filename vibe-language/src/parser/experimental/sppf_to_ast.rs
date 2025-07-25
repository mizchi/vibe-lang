use super::gll::sppf::{SharedPackedParseForest, SPPFNode, SPPFNodeType};
use crate::{Expr, Pattern, Literal, Span};
use crate::metadata::NodeId;
use std::collections::HashMap;

/// Converts SPPF (Shared Packed Parse Forest) to AST (Abstract Syntax Tree)
pub struct SPPFToASTConverter<'a> {
    /// SPPF instance reference
    sppf: &'a SharedPackedParseForest,
    /// Original tokens for reconstructing literals
    tokens: Vec<String>,
    /// Metadata collector (unused for now)
    _metadata: HashMap<NodeId, String>,
    /// Next node ID
    next_node_id: NodeId,
}

impl<'a> SPPFToASTConverter<'a> {
    pub fn new(sppf: &'a SharedPackedParseForest, tokens: Vec<String>) -> Self {
        Self {
            sppf,
            tokens,
            _metadata: HashMap::new(),
            next_node_id: NodeId(0),
        }
    }

    /// Convert SPPF roots to AST expressions
    pub fn convert(&mut self, roots: Vec<usize>) -> Result<Vec<Expr>, ConversionError> {
        let mut expressions = Vec::new();
        
        for root_id in roots {
            if let Some(root_node) = self.sppf.get_node(root_id) {
                match &root_node.node_type {
                    SPPFNodeType::NonTerminal(name) if name == "program" => {
                        // Parse top-level program
                        let exprs = self.convert_program(root_id)?;
                        expressions.extend(exprs);
                    }
                    SPPFNodeType::NonTerminal(name) if name == "expr" => {
                        // Single expression
                        let expr = self.convert_expr(root_id)?;
                        expressions.push(expr);
                    }
                    _ => {
                        return Err(ConversionError::UnexpectedNode(
                            format!("Expected program or expr, got {:?}", root_node.node_type)
                        ));
                    }
                }
            }
        }
        
        Ok(expressions)
    }

    /// Convert program node to list of expressions
    fn convert_program(&mut self, node_id: usize) -> Result<Vec<Expr>, ConversionError> {
        let node = self.get_node(node_id)?;
        let mut expressions = Vec::new();
        
        // Program is a list of top-level declarations
        for children in &node.children {
            for &child_id in children {
                let child = self.get_node(child_id)?;
                match &child.node_type {
                    SPPFNodeType::NonTerminal(name) => match name.as_str() {
                        "let_decl" => expressions.push(self.convert_let_decl(child_id)?),
                        "type_decl" => expressions.push(self.convert_type_decl(child_id)?),
                        "module_decl" => expressions.push(self.convert_module_decl(child_id)?),
                        "expr" => expressions.push(self.convert_expr(child_id)?),
                        _ => continue, // Skip separators
                    },
                    _ => continue,
                }
            }
        }
        
        Ok(expressions)
    }

    /// Convert expression node
    fn convert_expr(&mut self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id)?;
        
        // Handle ambiguity by taking the first derivation
        if node.children.is_empty() {
            return Err(ConversionError::EmptyNode);
        }
        
        let children = &node.children[0];
        if children.is_empty() {
            return Err(ConversionError::EmptyNode);
        }
        
        // Determine expression type by looking at children
        let first_child = self.get_node(children[0])?;
        
        match &first_child.node_type {
            SPPFNodeType::Terminal(token) => {
                // Literal or identifier
                self.convert_literal_or_identifier(token, node.start, node.end)
            }
            SPPFNodeType::NonTerminal(name) => {
                match name.as_str() {
                    "let_expr" => self.convert_let_expr(children[0]),
                    "if_expr" => self.convert_if_expr(children[0]),
                    "case_expr" => self.convert_case_expr(children[0]),
                    "lambda_expr" => self.convert_lambda_expr(children[0]),
                    "app_expr" => self.convert_app_expr(children[0]),
                    "binary_expr" => self.convert_binary_expr(children[0]),
                    "list_expr" => self.convert_list_expr(children[0]),
                    "record_expr" => self.convert_record_expr(children[0]),
                    _ => self.convert_expr(children[0]), // Try recursively
                }
            }
            _ => Err(ConversionError::UnexpectedNode(
                format!("Unexpected node type in expr: {:?}", first_child.node_type)
            )),
        }
    }

    /// Convert let declaration
    fn convert_let_decl(&mut self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id)?;
        let children = self.get_first_children(node)?;
        
        // Expected: "let" pattern "=" expr
        if children.len() < 4 {
            return Err(ConversionError::InvalidStructure("let declaration".to_string()));
        }
        
        let pattern = self.convert_pattern(children[1])?;
        let value = self.convert_expr(children[3])?;
        
        Ok(Expr::Let {
            pattern,
            value: Box::new(value),
            body: None,
            node_id: self.next_node_id(),
        })
    }

    /// Convert let expression (let ... in ...)
    fn convert_let_expr(&mut self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id)?;
        let children = self.get_first_children(node)?;
        
        // Expected: "let" pattern "=" expr "in" expr
        if children.len() < 6 {
            return Err(ConversionError::InvalidStructure("let expression".to_string()));
        }
        
        let pattern = self.convert_pattern(children[1])?;
        let value = self.convert_expr(children[3])?;
        let body = self.convert_expr(children[5])?;
        
        Ok(Expr::Let {
            pattern,
            value: Box::new(value),
            body: Some(Box::new(body)),
            node_id: self.next_node_id(),
        })
    }

    /// Convert if-then-else expression
    fn convert_if_expr(&mut self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id)?;
        let children = self.get_first_children(node)?;
        
        // Expected: "if" expr "then" expr "else" expr
        if children.len() < 6 {
            return Err(ConversionError::InvalidStructure("if expression".to_string()));
        }
        
        let condition = self.convert_expr(children[1])?;
        let then_branch = self.convert_expr(children[3])?;
        let else_branch = self.convert_expr(children[5])?;
        
        Ok(Expr::If {
            condition: Box::new(condition),
            then_branch: Box::new(then_branch),
            else_branch: Box::new(else_branch),
            node_id: self.next_node_id(),
        })
    }

    /// Convert case expression (match)
    fn convert_case_expr(&mut self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id)?;
        let children = self.get_first_children(node)?;
        
        // Expected: "case" expr "of" branches
        if children.len() < 4 {
            return Err(ConversionError::InvalidStructure("case expression".to_string()));
        }
        
        let scrutinee = self.convert_expr(children[1])?;
        let branches = self.convert_branches(children[3])?;
        
        Ok(Expr::Match {
            expr: Box::new(scrutinee),
            branches,
            node_id: self.next_node_id(),
        })
    }

    /// Convert pattern
    fn convert_pattern(&mut self, node_id: usize) -> Result<Pattern, ConversionError> {
        let node = self.get_node(node_id)?;
        
        if node.children.is_empty() {
            // Terminal pattern
            if let SPPFNodeType::Terminal(token) = &node.node_type {
                return self.convert_pattern_terminal(token);
            }
        }
        
        let children = self.get_first_children(node)?;
        if children.is_empty() {
            return Err(ConversionError::EmptyNode);
        }
        
        let first_child = self.get_node(children[0])?;
        
        match &first_child.node_type {
            SPPFNodeType::Terminal(token) => self.convert_pattern_terminal(token),
            SPPFNodeType::NonTerminal(name) => match name.as_str() {
                "list_pattern" => self.convert_list_pattern(children[0]),
                "cons_pattern" => self.convert_cons_pattern(children[0]),
                "tuple_pattern" => self.convert_tuple_pattern(children[0]),
                _ => self.convert_pattern(children[0]), // Try recursively
            },
            _ => Err(ConversionError::UnexpectedNode(
                format!("Unexpected node in pattern: {:?}", first_child.node_type)
            )),
        }
    }

    /// Convert terminal to pattern
    fn convert_pattern_terminal(&mut self, token: &str) -> Result<Pattern, ConversionError> {
        match token {
            "_" => Ok(Pattern::Wildcard),
            "identifier" => {
                // TODO: Get actual identifier name from tokens
                Ok(Pattern::Var("x".to_string()))
            }
            "number" => {
                // TODO: Get actual number from tokens
                Ok(Pattern::Literal(Literal::Int(0)))
            }
            "string" => {
                // TODO: Get actual string from tokens
                Ok(Pattern::Literal(Literal::String("".to_string())))
            }
            "true" => Ok(Pattern::Literal(Literal::Bool(true))),
            "false" => Ok(Pattern::Literal(Literal::Bool(false))),
            "[" => Ok(Pattern::List(vec![])), // Empty list
            _ => Err(ConversionError::UnknownToken(token.to_string())),
        }
    }

    /// Convert literal or identifier
    fn convert_literal_or_identifier(&mut self, token: &str, start: usize, end: usize) -> Result<Expr, ConversionError> {
        match token {
            "identifier" => {
                // Get actual identifier from token position
                let name = self.get_token_text(start)?;
                Ok(Expr::Var {
                    name,
                    node_id: self.next_node_id(),
                })
            }
            "number" => {
                let text = self.get_token_text(start)?;
                if text.contains('.') {
                    let value: f64 = text.parse()
                        .map_err(|_| ConversionError::InvalidLiteral(text.clone()))?;
                    Ok(Expr::Literal {
                        value: Literal::Float(value),
                        node_id: self.next_node_id(),
                    })
                } else {
                    let value: i64 = text.parse()
                        .map_err(|_| ConversionError::InvalidLiteral(text.clone()))?;
                    Ok(Expr::Literal {
                        value: Literal::Int(value),
                        node_id: self.next_node_id(),
                    })
                }
            }
            "string" => {
                let text = self.get_token_text(start)?;
                // Remove quotes
                let content = text.trim_start_matches('"').trim_end_matches('"');
                Ok(Expr::Literal {
                    value: Literal::String(content.to_string()),
                    node_id: self.next_node_id(),
                })
            }
            "true" => Ok(Expr::Literal {
                value: Literal::Bool(true),
                node_id: self.next_node_id(),
            }),
            "false" => Ok(Expr::Literal {
                value: Literal::Bool(false),
                node_id: self.next_node_id(),
            }),
            _ => Err(ConversionError::UnknownToken(token.to_string())),
        }
    }

    /// Convert type declaration (placeholder)
    fn convert_type_decl(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement type declaration conversion
        Ok(Expr::Literal {
            value: Literal::Unit,
            node_id: self.next_node_id(),
        })
    }

    /// Convert module declaration (placeholder)
    fn convert_module_decl(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement module declaration conversion
        Ok(Expr::Literal {
            value: Literal::Unit,
            node_id: self.next_node_id(),
        })
    }

    /// Convert lambda expression (placeholder)
    fn convert_lambda_expr(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement lambda conversion
        Ok(Expr::Lambda {
            param: Pattern::Var("x".to_string()),
            body: Box::new(Expr::Var {
                name: "x".to_string(),
                node_id: self.next_node_id(),
            }),
            node_id: self.next_node_id(),
        })
    }

    /// Convert application expression (placeholder)
    fn convert_app_expr(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement application conversion
        Ok(Expr::App {
            func: Box::new(Expr::Var {
                name: "f".to_string(),
                node_id: self.next_node_id(),
            }),
            arg: Box::new(Expr::Var {
                name: "x".to_string(),
                node_id: self.next_node_id(),
            }),
            node_id: self.next_node_id(),
        })
    }

    /// Convert binary expression (placeholder)
    fn convert_binary_expr(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement binary expression conversion
        Ok(Expr::Literal {
            value: Literal::Int(0),
            node_id: self.next_node_id(),
        })
    }

    /// Convert list expression (placeholder)
    fn convert_list_expr(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement list conversion
        Ok(Expr::List {
            elements: vec![],
            node_id: self.next_node_id(),
        })
    }

    /// Convert record expression (placeholder)
    fn convert_record_expr(&mut self, _node_id: usize) -> Result<Expr, ConversionError> {
        // TODO: Implement record conversion
        Ok(Expr::Record {
            fields: vec![],
            node_id: self.next_node_id(),
        })
    }

    /// Convert branches (placeholder)
    fn convert_branches(&mut self, _node_id: usize) -> Result<Vec<(Pattern, Expr)>, ConversionError> {
        // TODO: Implement branch conversion
        Ok(vec![])
    }

    /// Convert list pattern (placeholder)
    fn convert_list_pattern(&mut self, _node_id: usize) -> Result<Pattern, ConversionError> {
        Ok(Pattern::List(vec![]))
    }

    /// Convert cons pattern (placeholder)
    fn convert_cons_pattern(&mut self, _node_id: usize) -> Result<Pattern, ConversionError> {
        Ok(Pattern::Cons(
            Box::new(Pattern::Wildcard),
            Box::new(Pattern::Wildcard),
        ))
    }

    /// Convert tuple pattern (placeholder)
    fn convert_tuple_pattern(&mut self, _node_id: usize) -> Result<Pattern, ConversionError> {
        Ok(Pattern::Tuple(vec![]))
    }

    // Helper methods

    /// Get node by ID
    fn get_node(&self, node_id: usize) -> Result<&SPPFNode, ConversionError> {
        self.sppf.get_node(node_id)
            .ok_or(ConversionError::NodeNotFound(node_id))
    }

    /// Get first children (handle ambiguity by taking first derivation)
    fn get_first_children(&self, node: &SPPFNode) -> Result<&Vec<usize>, ConversionError> {
        node.children.first()
            .ok_or(ConversionError::EmptyNode)
    }

    /// Get token text at position
    fn get_token_text(&self, position: usize) -> Result<String, ConversionError> {
        self.tokens.get(position)
            .cloned()
            .ok_or(ConversionError::InvalidTokenPosition(position))
    }

    /// Generate next node ID
    fn next_node_id(&mut self) -> NodeId {
        let id = self.next_node_id;
        self.next_node_id = NodeId(id.0 + 1);
        id
    }
}

/// Conversion error types
#[derive(Debug, Clone)]
pub enum ConversionError {
    NodeNotFound(usize),
    EmptyNode,
    InvalidStructure(String),
    UnexpectedNode(String),
    UnknownToken(String),
    InvalidLiteral(String),
    InvalidTokenPosition(usize),
}

impl std::fmt::Display for ConversionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConversionError::NodeNotFound(id) => write!(f, "SPPF node {} not found", id),
            ConversionError::EmptyNode => write!(f, "Empty SPPF node"),
            ConversionError::InvalidStructure(s) => write!(f, "Invalid structure for {}", s),
            ConversionError::UnexpectedNode(s) => write!(f, "Unexpected node: {}", s),
            ConversionError::UnknownToken(s) => write!(f, "Unknown token: {}", s),
            ConversionError::InvalidLiteral(s) => write!(f, "Invalid literal: {}", s),
            ConversionError::InvalidTokenPosition(p) => write!(f, "Invalid token position: {}", p),
        }
    }
}

impl std::error::Error for ConversionError {}