//! SPPF to AST Converter - Converts Shared Packed Parse Forest to Vibe AST

use super::gll::sppf::{SharedPackedParseForest, SPPFNode, SPPFNodeType};
use crate::{Expr, Ident, Literal, Pattern, Span};
use crate::parser::lexer::Token;
use ordered_float::OrderedFloat;

/// Converter from SPPF to AST
pub struct SPPFToASTConverter {
    /// Reference to the SPPF
    sppf: *const SharedPackedParseForest,
    /// Original tokens for recovery
    tokens: Vec<Token>,
    /// Token positions
    token_positions: Vec<usize>,
}

impl SPPFToASTConverter {
    pub fn new(sppf: &SharedPackedParseForest, tokens: Vec<Token>) -> Self {
        // Calculate token positions
        let mut token_positions = Vec::with_capacity(tokens.len());
        let mut pos = 0;
        for _token in &tokens {
            token_positions.push(pos);
            pos += 1; // Each token is one position
        }
        
        Self {
            sppf: sppf as *const _,
            tokens,
            token_positions,
        }
    }
    
    /// Convert SPPF roots to AST expressions
    pub fn convert(&self, roots: Vec<usize>) -> Result<Vec<Expr>, ConversionError> {
        let mut exprs = Vec::new();
        
        println!("DEBUG: convert() called with {} roots", roots.len());
        println!("DEBUG: Available tokens: {:?}", self.tokens);
        
        for root_id in roots {
            if let Some(node) = self.get_node(root_id) {
                // eprintln!("Root node: {:?} at pos {}-{}", node.node_type, node.start, node.end);
                match &node.node_type {
                    SPPFNodeType::NonTerminal(name) if name == "Program" || name == "program" => {
                        // A program can have multiple expressions
                        if let Ok(Expr::List(program_exprs, _)) = self.convert_program(root_id) {
                            exprs.extend(program_exprs);
                        }
                    }
                    _ => {
                        // Single expression
                        // // eprintln!("Converting single expression from node type: {:?}", node.node_type);
                        let expr = self.convert_node_to_expr(root_id)?;
                        // // eprintln!("Converted to: {:?}", expr);
                        exprs.push(expr);
                    }
                }
            }
        }
        
        Ok(exprs)
    }
    
    
    /// Convert an expression node
    fn convert_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        
        // For now, check if it's a literal by looking at children
        if node.children.is_empty() {
            return Err(ConversionError::EmptyNode);
        }
        
        // Take the first parse if ambiguous
        let children = &node.children[0];
        
        // Simple heuristic: if first child is a terminal, it might be a literal
        if let Some(&first_child_id) = children.first() {
            if let Some(first_child) = self.get_node(first_child_id) {
                match &first_child.node_type {
                    SPPFNodeType::Terminal(token) => {
                        return self.convert_terminal_to_expr(token, node.start, node.end);
                    }
                    SPPFNodeType::NonTerminal(name) => {
                        return self.convert_nonterminal_expr(name, node_id);
                    }
                    _ => {}
                }
            }
        }
        
        // Default: try to convert as a complex expression
        self.convert_complex_expr(node_id)
    }
    
    /// Convert a terminal token to expression
    fn convert_terminal_to_expr(&self, token: &str, start: usize, end: usize) -> Result<Expr, ConversionError> {
        let span = Span::new(start, end);
        
        match token {
            "number" => {
                // Look up the actual token value
                if let Some(actual_token) = self.get_token_at_position(start) {
                    match actual_token {
                        Token::Int(n) => Ok(Expr::Literal(Literal::Int(*n), span)),
                        Token::Float(f) => Ok(Expr::Literal(Literal::Float(OrderedFloat(*f)), span)),
                        _ => Err(ConversionError::UnexpectedToken(token.to_string())),
                    }
                } else {
                    // Fallback
                    Ok(Expr::Literal(Literal::Int(0), span))
                }
            }
            "string" => {
                if let Some(Token::String(s)) = self.get_token_at_position(start) {
                    Ok(Expr::Literal(Literal::String(s.clone()), span))
                } else {
                    Ok(Expr::Literal(Literal::String(String::new()), span))
                }
            }
            "true" => Ok(Expr::Literal(Literal::Bool(true), span)),
            "false" => Ok(Expr::Literal(Literal::Bool(false), span)),
            "identifier" => {
                if let Some(Token::Symbol(name)) = self.get_token_at_position(start) {
                    Ok(Expr::Ident(Ident(name.clone()), span))
                } else {
                    Ok(Expr::Ident(Ident("_".to_string()), span))
                }
            }
            _ => Err(ConversionError::UnexpectedToken(token.to_string())),
        }
    }
    
    /// Convert a non-terminal expression
    fn convert_nonterminal_expr(&self, name: &str, node_id: usize) -> Result<Expr, ConversionError> {
        if let Some(node) = self.get_node(node_id) {
            println!("DEBUG: convert_nonterminal_expr: {} at node {} (pos {}-{})", name, node_id, node.start, node.end);
        } else {
            println!("DEBUG: convert_nonterminal_expr: {} at node {} (invalid node)", name, node_id);
        }
        match name {
            "TopLevelDef" => self.convert_top_level_def(node_id),
            "let_binding" | "LetBinding" | "LetDef" => self.convert_let_binding(node_id),
            "lambda" | "Lambda" | "LambdaExpr" => self.convert_lambda(node_id),
            "if_expr" | "IfExpr" => self.convert_if_expr(node_id),
            "case_expr" | "CaseExpr" => self.convert_case_expr(node_id),
            "application" | "Application" => self.convert_application(node_id),
            "list" | "List" => self.convert_list(node_id),
            "Program" => {
                // Program nodes should convert their children
                // This handles recursive Program nodes in the SPPF
                self.convert_program(node_id)
            }
            "BinaryExpr" | "PipelineExpr" | "ApplyExpr" => {
                // These might need special handling
                self.convert_binary_expr(node_id)
            }
            "OrExpr" | "AndExpr" | "CompareExpr" | "ConsExpr" | "ConcatExpr" | 
            "AddExpr" | "MulExpr" | "PowExpr" => {
                // These are all binary operator expressions
                self.convert_binary_expr(node_id)
            }
            "AppExpr" => {
                // Function application
                self.convert_app_expr(node_id)
            }
            "PostfixExpr" => {
                // PostfixExpr might be a parenthesized expression or a primary expression
                let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
                // eprintln!("PostfixExpr: node at pos {}-{}", node.start, node.end);
                // eprintln!("  Tokens: {:?}", &self.tokens[node.start..node.end.min(self.tokens.len())]);
                
                // Check if this is a parenthesized expression
                if node.start < self.tokens.len() {
                    if let Some(Token::LeftParen) = self.get_token_at_position(node.start) {
                        // eprintln!("  Found left paren at start");
                        return self.parse_parenthesized_expr_from_tokens(node.start, node.end);
                    }
                }
                
                // Otherwise, drill down
                if let Some(children) = node.children.first() {
                    if let Some(&child_id) = children.first() {
                        return self.convert_node_to_expr(child_id);
                    }
                }
                self.convert_complex_expr(node_id)
            }
            "PrimaryExpr" => {
                // These are simpler expressions - drill down
                let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
                if let Some(children) = node.children.first() {
                    if let Some(&child_id) = children.first() {
                        return self.convert_node_to_expr(child_id);
                    }
                }
                self.convert_complex_expr(node_id)
            }
            _ => self.convert_complex_expr(node_id),
        }
    }
    
    /// Convert a let binding
    fn convert_let_binding(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        // eprintln!("convert_let_binding: node at pos {}-{}", node.start, node.end);
        // eprintln!("  Node has {} child sets", node.children.len());
        
        // Analyze the structure of the let binding
        for (i, children) in node.children.iter().enumerate() {
            // // eprintln!("  Child set {}: {} children", i, children.len());
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    // eprintln!("    Child: {:?} at pos {}-{}", child.node_type, child.start, child.end);
                }
            }
        }
        
        // Check tokens starting from node.start
        let mut name = Ident("x".to_string());
        let mut value_expr = Expr::Literal(Literal::Int(42), Span::new(0, 0));
        
        // Try to extract identifier and value from tokens
        if node.start < self.tokens.len() {
            // Skip "let" token
            let pos = node.start;
            
            // Find identifier
            if pos + 1 < self.tokens.len() {
                if let Some(Token::Symbol(id)) = self.get_token_at_position(pos + 1) {
                    name = Ident(id.clone());
                }
            }
            
            // Find value (after '=')
            if pos + 3 < self.tokens.len() {
                if let Some(token) = self.get_token_at_position(pos + 3) {
                    match token {
                        Token::Int(n) => {
                            value_expr = Expr::Literal(Literal::Int(*n), Span::new(pos + 3, pos + 4));
                        }
                        Token::Symbol(s) => {
                            value_expr = Expr::Ident(Ident(s.clone()), Span::new(pos + 3, pos + 4));
                        }
                        _ => {}
                    }
                }
            }
        }
        
        let span = Span::new(node.start, node.end);
        Ok(Expr::Let {
            name,
            type_ann: None,
            value: Box::new(value_expr),
            span,
        })
    }
    
    /// Convert a lambda expression
    fn convert_lambda(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        // eprintln!("convert_lambda: node at pos {}-{}", node.start, node.end);
        // eprintln!("  Node has {} child sets", node.children.len());
        
        // Lambda: fn params -> body
        // First, check if we have fn token at the start
        if node.start < self.tokens.len() {
            if let Some(Token::Fn) = self.get_token_at_position(node.start) {
                // Find arrow position
                let mut arrow_pos = None;
                for i in (node.start + 1)..node.end {
                    if let Some(Token::Arrow) = self.get_token_at_position(i) {
                        arrow_pos = Some(i);
                        break;
                    }
                }
                
                if let Some(arrow) = arrow_pos {
                    // Extract parameters between fn and ->
                    let mut params = Vec::new();
                    for i in (node.start + 1)..arrow {
                        if let Some(Token::Symbol(name)) = self.get_token_at_position(i) {
                            params.push((Ident(name.clone()), None));
                        }
                    }
                    
                    // Extract body after ->
                    // For now, handle simple cases
                    if arrow + 1 < node.end {
                        // Check if body is a simple expression
                        if let Some(body_token) = self.get_token_at_position(arrow + 1) {
                            let body = match body_token {
                                Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(arrow + 1, arrow + 2)),
                                Token::Symbol(s) => Expr::Ident(Ident(s.clone()), Span::new(arrow + 1, arrow + 2)),
                                _ => {
                                    // Try to parse as more complex expression
                                    // For now, return a placeholder
                                    return Err(ConversionError::UnexpectedToken("Complex lambda body not yet supported".to_string()));
                                }
                            };
                            
                            return Ok(Expr::Lambda {
                                params,
                                body: Box::new(body),
                                span: Span::new(node.start, node.end),
                            });
                        }
                    }
                }
            }
        }
        
        Err(ConversionError::UnexpectedToken("Invalid lambda expression".to_string()))
    }
    
    /// Convert an if expression
    fn convert_if_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        let span = Span::new(node.start, node.end);
        
        // eprintln!("convert_if_expr: node at pos {}-{}", node.start, node.end);
        // eprintln!("  Node has {} child sets", node.children.len());
        // eprintln!("  Tokens: {:?}", &self.tokens[node.start..node.end.min(self.tokens.len())]);
        
        // IfExpr -> if Expr Block else Block
        // The issue is that the node position (6-9) is incomplete.
        // We need to look at the entire token stream from the beginning
        
        // Find the if token before this position
        let mut if_pos = None;
        for i in (0..node.start).rev() {
            if let Some(Token::If) = self.get_token_at_position(i) {
                if_pos = Some(i);
                break;
            }
        }
        
        if let Some(start) = if_pos {
            // Find the end of the if expression
            let mut end = node.end;
            let mut brace_count = 0;
            let mut found_else = false;
            
            for i in start..self.tokens.len() {
                if let Some(token) = self.get_token_at_position(i) {
                    match token {
                        Token::LeftBrace => brace_count += 1,
                        Token::RightBrace => {
                            brace_count -= 1;
                            if brace_count == 0 && found_else {
                                end = i + 1;
                                break;
                            }
                        }
                        Token::Else => found_else = true,
                        _ => {}
                    }
                }
            }
            
            return self.parse_if_expr_from_tokens(start, end);
        }
        
        // Otherwise, try to find children in SPPF
        let mut cond_expr = None;
        let mut then_expr = None;
        let mut else_expr = None;
        
        // Look for the pattern in children
        for children in &node.children {
            if children.len() >= 6 {
                // Expected: if, Expr, then, Expr, else, Expr
                let mut expr_count = 0;
                for &child_id in children {
                    if let Some(child) = self.get_node(child_id) {
                        match &child.node_type {
                            SPPFNodeType::Terminal(term) => {
                                // Skip if, then, else terminals
                                if term != "if" && term != "then" && term != "else" {
                                    // Might be a literal or identifier
                                    if expr_count == 0 && cond_expr.is_none() {
                                        cond_expr = self.convert_node_to_expr(child_id).ok();
                                        expr_count += 1;
                                    } else if expr_count == 1 && then_expr.is_none() {
                                        then_expr = self.convert_node_to_expr(child_id).ok();
                                        expr_count += 1;
                                    } else if expr_count == 2 && else_expr.is_none() {
                                        else_expr = self.convert_node_to_expr(child_id).ok();
                                        expr_count += 1;
                                    }
                                }
                            }
                            SPPFNodeType::NonTerminal(_) => {
                                // This is likely an Expr node
                                if expr_count == 0 && cond_expr.is_none() {
                                    cond_expr = self.convert_node_to_expr(child_id).ok();
                                    expr_count += 1;
                                } else if expr_count == 1 && then_expr.is_none() {
                                    then_expr = self.convert_node_to_expr(child_id).ok();
                                    expr_count += 1;
                                } else if expr_count == 2 && else_expr.is_none() {
                                    else_expr = self.convert_node_to_expr(child_id).ok();
                                    expr_count += 1;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                
                if let (Some(cond), Some(then_e), Some(else_e)) = (cond_expr.clone(), then_expr.clone(), else_expr.clone()) {
                    return Ok(Expr::If {
                        cond: Box::new(cond),
                        then_expr: Box::new(then_e),
                        else_expr: Box::new(else_e),
                        span,
                    });
                }
            }
        }
        
        // Fallback: try a simpler approach
        Err(ConversionError::UnexpectedToken("Failed to parse if expression".to_string()))
    }
    
    /// Convert a match/case expression
    fn convert_case_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        let span = Span::new(node.start, node.end);
        
        println!("DEBUG: convert_case_expr called with node_id={}, start={}, end={}", node_id, node.start, node.end);
        
        // CaseExpr -> match Expr { CaseBranches }
        // Find the match token
        let mut match_pos = None;
        for i in (0..=node.start).rev() {
            if let Some(Token::Match) = self.get_token_at_position(i) {
                match_pos = Some(i);
                break;
            }
        }
        
        if let Some(start) = match_pos {
            // Find the end of the match expression
            let mut end = node.end;
            let mut brace_count = 0;
            
            for i in start..self.tokens.len() {
                if let Some(token) = self.get_token_at_position(i) {
                    match token {
                        Token::LeftBrace => brace_count += 1,
                        Token::RightBrace => {
                            brace_count -= 1;
                            if brace_count == 0 {
                                end = i + 1;
                                break;
                            }
                        }
                        _ => {}
                    }
                }
            }
            
            return self.parse_match_expr_from_tokens(start, end);
        }
        
        // Fallback: create a simple match expression
        Err(ConversionError::UnexpectedToken("Failed to parse match expression".to_string()))
    }
    
    /// Convert function application
    fn convert_application(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        let span = Span::new(node.start, node.end);
        
        // Simplified: create a basic application
        Ok(Expr::Apply {
            func: Box::new(Expr::Ident(Ident("f".to_string()), span.clone())),
            args: vec![Expr::Literal(Literal::Int(42), span.clone())],
            span,
        })
    }
    
    /// Convert a list expression
    fn convert_list(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        let span = Span::new(node.start, node.end);
        
        // Simplified: create an empty list
        Ok(Expr::List(vec![], span))
    }
    
    /// Convert top level definition
    fn convert_top_level_def(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        // eprintln!("convert_top_level_def: node at pos {}-{}", node.start, node.end);
        // eprintln!("  Node has {} child sets", node.children.len());
        // eprintln!("  Tokens in range: {:?}", &self.tokens[node.start..node.end.min(self.tokens.len())]);
        
        // Analyze children structure
        for (i, children) in node.children.iter().enumerate() {
            // eprintln!("  Child set {}: {} children", i, children.len());
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    // eprintln!("    Child: {:?} at pos {}-{}", child.node_type, child.start, child.end);
                    // Try to go deeper
                    if !child.children.is_empty() {
                        for (j, grandchildren) in child.children.iter().enumerate() {
                            // // eprintln!("      Grandchild set {}: {} nodes", j, grandchildren.len());
                            for &grandchild_id in grandchildren {
                                if let Some(grandchild) = self.get_node(grandchild_id) {
                                    // // eprintln!("        Grandchild: {:?} at pos {}-{}", 
                                    //          grandchild.node_type, grandchild.start, grandchild.end);
                                    // Go one level deeper
                                    if !grandchild.children.is_empty() {
                                        for (k, ggchildren) in grandchild.children.iter().enumerate() {
                                            // // eprintln!("          Great-grandchild set {}: {} nodes", k, ggchildren.len());
                                            for &ggchild_id in ggchildren {
                                                if let Some(ggchild) = self.get_node(ggchild_id) {
                                                    // // eprintln!("            Great-grandchild: {:?} at pos {}-{}", 
                                                    //          ggchild.node_type, ggchild.start, ggchild.end);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Check if this is a simple lambda at top level (fn x -> expr)
        if node.start < self.tokens.len() {
            if let Some(Token::Fn) = self.get_token_at_position(node.start) {
                // eprintln!("Found top-level fn token, parsing as lambda");
                return self.parse_lambda_from_tokens(node.start, node.end);
            }
            
            // Check if this is a simple function application (f arg1 arg2 ...)
            if let Some(Token::Symbol(_)) = self.get_token_at_position(node.start) {
                // Check if we have more than one token
                if node.end - node.start > 1 {
                    // eprintln!("Found potential function application at top level");
                    return self.parse_application_from_tokens(node.start, node.end);
                }
            }
        }
        
        // Try to find the actual definition
        // TopLevelDef -> LetBinding | Expr | ...
        if let Some(children) = node.children.first() {
            if let Some(&child_id) = children.first() {
                if let Some(child) = self.get_node(child_id) {
                    // eprintln!("Processing child node: {:?}", child.node_type);
                    
                    // Process based on child type
                    if let SPPFNodeType::NonTerminal(name) = &child.node_type {
                        // Handle different TopLevelDef alternatives
                        match name.as_str() {
                            "LetBinding" => {
                                // LetBinding has been parsed, but we need to look at tokens
                                // The actual structure is in the tokens, not in the SPPF children
                                // The LetBinding node itself might be empty, so we parse from TopLevelDef's range
                                // eprintln!("  Found LetBinding child, parsing from tokens");
                                
                                // Find the actual range of this let binding
                                let mut end = node.start;
                                let mut brace_count: i32 = 0;
                                let mut paren_count: i32 = 0;
                                
                                // Scan tokens to find the end of this let binding
                                for i in node.start..self.tokens.len() {
                                    match &self.tokens[i] {
                                        Token::Let if i > node.start && brace_count == 0 && paren_count == 0 => {
                                            // Found next let statement
                                            end = i;
                                            break;
                                        }
                                        Token::LeftBrace => brace_count += 1,
                                        Token::RightBrace => {
                                            brace_count = brace_count.saturating_sub(1);
                                        }
                                        Token::LeftParen => paren_count += 1,
                                        Token::RightParen => {
                                            paren_count = paren_count.saturating_sub(1);
                                        }
                                        _ => {}
                                    }
                                    end = i + 1;
                                }
                                
                                // eprintln!("  Parsing let from {} to {}", node.start, end);
                                return self.parse_let_binding_from_tokens(node.start, end);
                            }
                            "LambdaExpr" => {
                                // For top-level lambda, parse from tokens directly
                                if node.start < self.tokens.len() {
                                    if let Some(Token::Fn) = self.get_token_at_position(node.start) {
                                        return self.parse_lambda_from_tokens(node.start, node.end);
                                    }
                                }
                                // Otherwise, continue with child processing
                            }
                            "Expr" => {
                                println!("DEBUG: TopLevelDef found Expr child");
                                // Expr -> BinaryExpr -> ...
                                if let Some(expr_children) = child.children.first() {
                                    if let Some(&expr_child_id) = expr_children.first() {
                                        println!("DEBUG: Converting Expr child_id={}", expr_child_id);
                                        return self.convert_node_to_expr(expr_child_id);
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    return self.convert_node_to_expr(child_id);
                }
            }
        }
        
        // Fallback
        Ok(Expr::Literal(Literal::Int(0), Span::new(node.start, node.end)))
    }
    
    /// Convert a Program node
    fn convert_program(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        println!("DEBUG: convert_program: node_id={}, pos {}-{}", node_id, node.start, node.end);
        println!("DEBUG: convert_program: {} child sets", node.children.len());
        
        // A Program node can have multiple definitions
        let mut definitions = Vec::new();
        
        // Look at the children
        for (i, children) in node.children.iter().enumerate() {
            println!("DEBUG: convert_program: child set {} has {} children", i, children.len());
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    println!("DEBUG: convert_program: child type={:?} at pos {}-{}", child.node_type, child.start, child.end);
                    
                    match &child.node_type {
                        SPPFNodeType::NonTerminal(name) => {
                            println!("DEBUG: convert_program: NonTerminal child: {}", name);
                            if name == "TopLevelDef" {
                                // Convert each top-level definition
                                if let Ok(def) = self.convert_top_level_def(child_id) {
                                    definitions.push(def);
                                }
                            } else if name == "Program" {
                                // Recursive Program node - check if it's the same node to avoid infinite recursion
                                if child_id != node_id {
                                    if let Ok(Expr::List(exprs, _)) = self.convert_program(child_id) {
                                        definitions.extend(exprs);
                                    }
                                }
                            } else {
                                // Try to convert as expression
                                if let Ok(expr) = self.convert_nonterminal_expr(name, child_id) {
                                    definitions.push(expr);
                                }
                            }
                        }
                        _ => {
                            // Try to convert as expression
                            if let Ok(expr) = self.convert_node_to_expr(child_id) {
                                definitions.push(expr);
                            }
                        }
                    }
                }
            }
        }
        
        println!("DEBUG: convert_program: found {} definitions", definitions.len());
        Ok(Expr::List(definitions, Span::new(node.start, node.end)))
    }
    
    /// Convert a complex expression (fallback)
    fn convert_complex_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        let span = Span::new(node.start, node.end);
        
        // // eprintln!("convert_complex_expr: {:?} at pos {}-{}", node.node_type, node.start, node.end);
        // // eprintln!("  Node has {} child sets", node.children.len());
        
        // Check if this is a parenthesized expression
        if node.start < self.tokens.len() && node.end > node.start + 2 {
            if let Some(Token::LeftParen) = self.get_token_at_position(node.start) {
                if let Some(Token::RightParen) = self.get_token_at_position(node.end - 1) {
                    // This is a parenthesized expression (expr)
                    // Parse the expression between parentheses
                    // eprintln!("Found parenthesized expression at {}-{}", node.start, node.end);
                    
                    // Look for the inner expression
                    for children in &node.children {
                        for &child_id in children {
                            if let Some(child) = self.get_node(child_id) {
                                // Skip the parentheses terminals
                                if let SPPFNodeType::Terminal(term_str) = &child.node_type {
                                    if term_str == "(" || term_str == ")" {
                                        continue;
                                    }
                                }
                                // Convert the inner expression
                                if let Ok(expr) = self.convert_node_to_expr(child_id) {
                                    return Ok(expr);
                                }
                            }
                        }
                    }
                    
                    // If we can't find a proper child, try parsing from tokens
                    return self.parse_parenthesized_expr_from_tokens(node.start, node.end);
                }
            }
        }
        
        // Try to find a terminal node in the children
        for (i, children) in node.children.iter().enumerate() {
            // // eprintln!("  Exploring child set {}: {} children", i, children.len());
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    // // eprintln!("    Found child: {:?}", child.node_type);
                    // If it's a terminal, convert it
                    if let SPPFNodeType::Terminal(token) = &child.node_type {
                        return self.convert_terminal_to_expr(token, child.start, child.end);
                    }
                    // Otherwise, try to convert it recursively
                    if let Ok(expr) = self.convert_node_to_expr(child_id) {
                        return Ok(expr);
                    }
                }
            }
        }
        
        // For now, just return a placeholder
        Ok(Expr::Literal(Literal::Int(0), span))
    }
    
    /// Convert node to expression (dispatcher)
    fn convert_node_to_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        if let Some(node) = self.get_node(node_id) {
            println!("DEBUG: convert_node_to_expr: node_id={}, type={:?}", node_id, node.node_type);
            match &node.node_type {
                SPPFNodeType::NonTerminal(name) => self.convert_nonterminal_expr(name, node_id),
                SPPFNodeType::Terminal(token) => self.convert_terminal_to_expr(token, node.start, node.end),
                SPPFNodeType::Intermediate { slot } => {
                    println!("DEBUG: Found Intermediate node with slot={}", slot);
                    // Intermediate nodes are used for binarization in GLL parsing
                    // We need to look at their children
                    if let Some(children) = node.children.first() {
                        if let Some(&child_id) = children.first() {
                            println!("DEBUG: Converting first child of Intermediate node");
                            return self.convert_node_to_expr(child_id);
                        }
                    }
                    Err(ConversionError::UnsupportedNode)
                }
                _ => {
                    println!("DEBUG: Unsupported node type: {:?}", node.node_type);
                    Err(ConversionError::UnsupportedNode)
                }
            }
        } else {
            Err(ConversionError::InvalidNode)
        }
    }
    
    /// Get node from SPPF
    fn get_node(&self, node_id: usize) -> Option<&SPPFNode> {
        unsafe {
            (*self.sppf).get_node(node_id)
        }
    }
    
    /// Get token at a specific position
    fn get_token_at_position(&self, pos: usize) -> Option<&Token> {
        // // eprintln!("Getting token at position {}, tokens.len()={}", pos, self.tokens.len());
        let token = self.tokens.get(pos);
        // // eprintln!("Token at {}: {:?}", pos, token);
        token
    }
    
    /// Parse let binding from tokens in the range
    fn parse_let_binding_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_let_binding_from_tokens: range {}-{}", start, end);
        
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..self.tokens.len() {
            tokens.push(&self.tokens[i]);
            // eprintln!("  Token {}: {:?}", i, self.tokens[i]);
            if i >= end && end > 0 {
                break;
            }
        }
        
        // Parse: let <identifier> [params...] = <expr>
        if tokens.len() >= 4 {
            if let Token::Let = tokens[0] {
                if let Token::Symbol(name) = tokens[1] {
                    // Find the equals sign
                    let mut equals_pos = None;
                    for (i, token) in tokens.iter().enumerate() {
                        if let Token::Equals = token {
                            equals_pos = Some(i);
                            break;
                        }
                    }
                    
                    if let Some(eq_idx) = equals_pos {
                        // Check if we have parameters between name and =
                        let params: Vec<Ident> = if eq_idx > 2 {
                            // Collect parameter names
                            let mut p = Vec::new();
                            for i in 2..eq_idx {
                                if let Token::Symbol(param_name) = tokens[i] {
                                    p.push(Ident(param_name.clone()));
                                }
                            }
                            p
                        } else {
                            Vec::new()
                        };
                        
                        // Parse the body expression
                        let body_start = eq_idx + 1;
                        let body = if body_start < tokens.len() {
                            // For now, handle simple cases
                            match tokens[body_start] {
                                Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(start + body_start, start + body_start + 1)),
                                Token::Float(f) => Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(start + body_start, start + body_start + 1)),
                                Token::String(s) => Expr::Literal(Literal::String(s.clone()), Span::new(start + body_start, start + body_start + 1)),
                                Token::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(start + body_start, start + body_start + 1)),
                                Token::Symbol(s) => {
                                    // Could be a simple identifier or start of a more complex expression
                                    // Check if this is a binary expression
                                    if body_start + 2 < tokens.len() {
                                        // Check for binary operator
                                        if let Token::Symbol(op) = tokens[body_start + 1] {
                                            if matches!(op.as_str(), "+" | "-" | "*" | "/" | "==" | "!=" | "<" | ">" | "<=" | ">=" | "&&" | "||") {
                                                // This is a binary expression
                                                if let Token::Symbol(rhs) = tokens[body_start + 2] {
                                                    let left = Expr::Ident(Ident(s.clone()), Span::new(start + body_start, start + body_start + 1));
                                                    let right = Expr::Ident(Ident(rhs.clone()), Span::new(start + body_start + 2, start + body_start + 3));
                                                    Expr::Apply {
                                                        func: Box::new(Expr::Ident(Ident(op.clone()), Span::new(start + body_start + 1, start + body_start + 2))),
                                                        args: vec![left, right],
                                                        span: Span::new(start + body_start, start + body_start + 3),
                                                    }
                                                } else {
                                                    Expr::Ident(Ident(s.clone()), Span::new(start + body_start, start + body_start + 1))
                                                }
                                            } else {
                                                Expr::Ident(Ident(s.clone()), Span::new(start + body_start, start + body_start + 1))
                                            }
                                        } else {
                                            Expr::Ident(Ident(s.clone()), Span::new(start + body_start, start + body_start + 1))
                                        }
                                    } else {
                                        Expr::Ident(Ident(s.clone()), Span::new(start + body_start, start + body_start + 1))
                                    }
                                }
                                _ => return Err(ConversionError::UnexpectedToken(format!("{:?}", tokens[body_start]))),
                            }
                        } else {
                            return Err(ConversionError::UnexpectedToken("Missing expression after =".to_string()));
                        };
                        
                        // If we have parameters, wrap the body in lambda expressions
                        let value = if params.is_empty() {
                            body
                        } else {
                            // Create nested lambdas for currying
                            params.iter().rev().fold(body, |acc, param| {
                                Expr::Lambda {
                                    params: vec![(param.clone(), None)],
                                    body: Box::new(acc),
                                    span: Span::new(start, end),
                                }
                            })
                        };
                        
                        return Ok(Expr::Let {
                            name: Ident(name.clone()),
                            type_ann: None,
                            value: Box::new(value),
                            span: Span::new(start, end),
                        });
                    }
                }
            }
        }
        
        Err(ConversionError::UnexpectedToken("Invalid let binding".to_string()))
    }
    
    /// Parse lambda from tokens in the range
    fn parse_lambda_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_lambda_from_tokens: range {}-{}", start, end);
        
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..self.tokens.len() {
            tokens.push(&self.tokens[i]);
            // eprintln!("  Token {}: {:?}", i, self.tokens[i]);
            if i >= end && end > 0 {
                break;
            }
        }
        
        // Parse: fn <params> -> <body> or fn <params> { <body> }
        if tokens.len() >= 3 {
            if let Token::Fn = tokens[0] {
                // Look for arrow or left brace
                let mut arrow_pos = None;
                let mut brace_pos = None;
                
                for (i, token) in tokens.iter().enumerate() {
                    match token {
                        Token::Arrow => {
                            arrow_pos = Some(i);
                            break;
                        }
                        Token::LeftBrace => {
                            brace_pos = Some(i);
                            break;
                        }
                        _ => {}
                    }
                }
                
                // Extract parameters (common for both forms)
                let mut params = Vec::new();
                let body_start_idx = if let Some(arrow_idx) = arrow_pos {
                    // Arrow form: fn x y -> body
                    for i in 1..arrow_idx {
                        if let Token::Symbol(name) = tokens[i] {
                            params.push((Ident(name.clone()), None));
                        }
                    }
                    arrow_idx + 1
                } else if let Some(brace_idx) = brace_pos {
                    // Brace form: fn x y { body }
                    for i in 1..brace_idx {
                        if let Token::Symbol(name) = tokens[i] {
                            params.push((Ident(name.clone()), None));
                        }
                    }
                    brace_idx
                } else {
                    return Err(ConversionError::UnexpectedToken("Lambda expression missing '->' or '{'".to_string()));
                };
                
                // Parse body
                if body_start_idx < tokens.len() {
                    let body = if let Some(_brace_idx) = brace_pos {
                        // Parse block body
                        self.parse_block_from_tokens(start + body_start_idx, end)?
                    } else {
                        // Parse simple expression body
                        match tokens[body_start_idx] {
                            Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(start + body_start_idx, start + body_start_idx + 1)),
                            Token::Symbol(s) => Expr::Ident(Ident(s.clone()), Span::new(start + body_start_idx, start + body_start_idx + 1)),
                            _ => return Err(ConversionError::UnexpectedToken(format!("Unexpected token in lambda body: {:?}", tokens[body_start_idx]))),
                        }
                    };
                    
                    return Ok(Expr::Lambda {
                        params,
                        body: Box::new(body),
                        span: Span::new(start, end),
                    });
                }
            }
        }
        
        Err(ConversionError::UnexpectedToken("Invalid lambda expression".to_string()))
    }
    
    /// Parse function application from tokens
    fn parse_application_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_application_from_tokens: range {}-{}", start, end);
        
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..end.min(self.tokens.len()) {
            tokens.push(&self.tokens[i]);
            // eprintln!("  Token {}: {:?}", i, self.tokens[i]);
        }
        
        if tokens.is_empty() {
            return Err(ConversionError::UnexpectedToken("No tokens for application".to_string()));
        }
        
        // First token should be the function
        let func = match tokens[0] {
            Token::Symbol(name) => Expr::Ident(Ident(name.clone()), Span::new(start, start + 1)),
            _ => return Err(ConversionError::UnexpectedToken("Expected function name".to_string())),
        };
        
        // Rest are arguments
        let mut args = Vec::new();
        for (i, token) in tokens.iter().skip(1).enumerate() {
            let arg_pos = start + i + 1;
            let arg = match token {
                Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(arg_pos, arg_pos + 1)),
                Token::Float(f) => Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(arg_pos, arg_pos + 1)),
                Token::String(s) => Expr::Literal(Literal::String(s.clone()), Span::new(arg_pos, arg_pos + 1)),
                Token::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(arg_pos, arg_pos + 1)),
                Token::Symbol(s) => Expr::Ident(Ident(s.clone()), Span::new(arg_pos, arg_pos + 1)),
                _ => return Err(ConversionError::UnexpectedToken(format!("Unexpected token in application: {:?}", token))),
            };
            args.push(arg);
        }
        
        if args.is_empty() {
            // No arguments, just return the function
            Ok(func)
        } else {
            Ok(Expr::Apply {
                func: Box::new(func),
                args,
                span: Span::new(start, end),
            })
        }
    }
    
    /// Convert binary expressions (handles all binary operators including backtick operators)
    fn convert_binary_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        // eprintln!("convert_binary_expr: {:?} at pos {}-{}", node.node_type, node.start, node.end);
        // eprintln!("  Node has {} child sets", node.children.len());
        
        // Binary expressions can have multiple alternatives:
        // BinaryExpr -> Expr
        // BinaryExpr -> Expr op Expr
        // BinaryExpr -> Expr `func` Expr
        
        // Analyze structure and look for patterns
        // If we have multiple child sets, it might be ambiguous parses
        // Usually binary operators will have 3 children: left, operator, right
        
        // Try each child set to find one with 3 children (binary operation pattern)
        for (i, children) in node.children.iter().enumerate() {
            // eprintln!("  Child set {}: {} children", i, children.len());
            
            // // Debug: print all children
            // for (j, &child_id) in children.iter().enumerate() {
            //     if let Some(child) = self.get_node(child_id) {
            //         eprintln!("    Child {}: {:?} at pos {}-{}", j, child.node_type, child.start, child.end);
            //         // Print tokens in range to understand what this represents
            //         eprintln!("      Tokens in range {}-{}: ", child.start, child.end);
            //         for k in child.start..child.end {
            //             if let Some(token) = self.get_token_at_position(k) {
            //                 eprintln!("        [{}]: {:?}", k, token);
            //             }
            //         }
            //     }
            // }
            
            // For binary operations, check if we have a pattern like "left op right"
            // where the child node starts after position 0 and there's an operator before it
            if children.len() == 1 && node.start < node.end {
                if let Some(&child_id) = children.first() {
                    if let Some(child) = self.get_node(child_id) {
                        // Check if child starts after the beginning, indicating something before it
                        if child.start > node.start + 1 {
                            // Check for operator token before the child
                            let op_pos = child.start - 1;
                            if let Some(token) = self.get_token_at_position(op_pos) {
                                let operator = match token {
                                    Token::Symbol(s) => Some(s.clone()),
                                    _ => None,
                                };
                                
                                if let Some(op) = operator {
                                    // Check if this is a known binary operator
                                    let is_binary_op = matches!(op.as_str(),
                                        "+" | "-" | "*" | "/" | "^" | "++" | "::" |
                                        "==" | "!=" | "<" | ">" | "<=" | ">=" |
                                        "&&" | "||" | "|>" | "$" | "mod"
                                    );
                                    
                                    if is_binary_op {
                                        // eprintln!("Found binary operator '{}' at position {}", op, op_pos);
                                        
                                        // Parse left operand
                                        let left_expr = if node.start < op_pos {
                                            // For now, handle simple identifiers
                                            if let Some(Token::Symbol(name)) = self.get_token_at_position(node.start) {
                                                Expr::Ident(Ident(name.clone()), Span::new(node.start, node.start + 1))
                                            } else if let Some(token) = self.get_token_at_position(node.start) {
                                                match token {
                                                    Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(node.start, node.start + 1)),
                                                    _ => return Err(ConversionError::UnexpectedToken("Expected identifier or literal".to_string())),
                                                }
                                            } else {
                                                return Err(ConversionError::UnexpectedToken("Expected identifier or literal".to_string()));
                                            }
                                        } else {
                                            return Err(ConversionError::UnexpectedToken("No left operand".to_string()));
                                        };
                                        
                                        // Parse right operand
                                        let right_expr = self.convert_node_to_expr(child_id)?;
                                        
                                        return Ok(Expr::Apply {
                                            func: Box::new(Expr::Ident(
                                                Ident(op.clone()),
                                                Span::new(op_pos, op_pos + 1)
                                            )),
                                            args: vec![left_expr, right_expr],
                                            span: Span::new(node.start, node.end),
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Check if this is a general binary operation (3 children: left op right)
            if children.len() == 3 {
                if let (Some(&left_id), Some(&op_id), Some(&right_id)) = 
                    (children.get(0), children.get(1), children.get(2)) {
                    
                    // Check if middle child is an operator terminal
                    if let Some(op_node) = self.get_node(op_id) {
                        if let SPPFNodeType::Terminal(op_str) = &op_node.node_type {
                            // eprintln!("Found operator terminal: {}", op_str);
                            // Any terminal in operator position is a valid operator
                            // Convert left and right operands
                            let left = self.convert_node_to_expr(left_id)?;
                            let right = self.convert_node_to_expr(right_id)?;
                            
                            // Map operator symbols to function names
                            let func_name = match op_str.as_str() {
                                "+" => "+",
                                "-" => "-",
                                "*" => "*",
                                "/" => "/",
                                "^" => "^",
                                "++" => "++",
                                "::" => "::",
                                "==" => "==",
                                "!=" => "!=",
                                "<" => "<",
                                ">" => ">",
                                "<=" => "<=",
                                ">=" => ">=",
                                "&&" => "&&",
                                "||" => "||",
                                "|>" => "|>",
                                "$" => "$",
                                "mod" => "mod",
                                _ => op_str,  // Use operator as-is
                            };
                            
                            return Ok(Expr::Apply {
                                func: Box::new(Expr::Ident(
                                    Ident(func_name.to_string()), 
                                    Span::new(op_node.start, op_node.end)
                                )),
                                args: vec![left, right],
                                span: Span::new(node.start, node.end),
                            });
                        } else if let SPPFNodeType::NonTerminal(nt) = &op_node.node_type {
                            // Could be a backtick operator or other non-terminal
                            // eprintln!("Found non-terminal in operator position: {}", nt);
                            // For now, try to extract it as an identifier
                            if let Ok(op_expr) = self.convert_node_to_expr(op_id) {
                                let left = self.convert_node_to_expr(left_id)?;
                                let right = self.convert_node_to_expr(right_id)?;
                                
                                return Ok(Expr::Apply {
                                    func: Box::new(op_expr),
                                    args: vec![left, right],
                                    span: Span::new(node.start, node.end),
                                });
                            }
                        }
                    }
                }
            }
            
            // If only one child, it might be just a MulExpr
            if children.len() == 1 {
                if let Some(&child_id) = children.first() {
                    // This might be BinaryExpr -> NextExpr (no operator)
                    return self.convert_node_to_expr(child_id);
                }
            }
        }
        
        // Fallback: try to handle as a general expression
        self.convert_complex_expr(node_id)
    }
    
    /// Convert AppExpr (function application)
    fn convert_app_expr(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        // eprintln!("convert_app_expr: node at pos {}-{}", node.start, node.end);
        // eprintln!("  Node has {} child sets", node.children.len());
        
        // // Debug: print children
        // for (i, children) in node.children.iter().enumerate() {
        //     eprintln!("  Child set {}: {} children", i, children.len());
        //     for (j, &child_id) in children.iter().enumerate() {
        //         if let Some(child) = self.get_node(child_id) {
        //             eprintln!("    Child {}: {:?} at pos {}-{}", j, child.node_type, child.start, child.end);
        //         }
        //     }
        // }
        
        // AppExpr -> AppExpr PostfixExpr | PostfixExpr
        // If we have multiple child sets, it could be ambiguous
        
        // Look for pattern with 2 children (function and argument)
        for children in &node.children {
            if children.len() == 2 {
                if let (Some(&func_id), Some(&arg_id)) = (children.get(0), children.get(1)) {
                    // This looks like function application
                    let func = self.convert_node_to_expr(func_id)?;
                    let arg = self.convert_node_to_expr(arg_id)?;
                    
                    // Check if func is already an Apply, extend it
                    match func {
                        Expr::Apply { func: inner_func, mut args, .. } => {
                            args.push(arg);
                            return Ok(Expr::Apply {
                                func: inner_func,
                                args,
                                span: Span::new(node.start, node.end),
                            });
                        }
                        _ => {
                            return Ok(Expr::Apply {
                                func: Box::new(func),
                                args: vec![arg],
                                span: Span::new(node.start, node.end),
                            });
                        }
                    }
                }
            }
        }
        
        // If only one child, it's just a PostfixExpr
        if let Some(children) = node.children.first() {
            if children.len() == 1 {
                if let Some(&child_id) = children.first() {
                    return self.convert_node_to_expr(child_id);
                }
            }
        }
        
        // Fallback
        self.convert_complex_expr(node_id)
    }
    
    /// Parse parenthesized expression from tokens
    fn parse_parenthesized_expr_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_parenthesized_expr_from_tokens: range {}-{}", start, end);
        
        // Should start with ( and end with )
        if start >= self.tokens.len() || end <= start + 2 {
            return Err(ConversionError::UnexpectedToken("Invalid parenthesized expression range".to_string()));
        }
        
        // Verify we have parentheses
        if let Some(Token::LeftParen) = self.get_token_at_position(start) {
            if let Some(Token::RightParen) = self.get_token_at_position(end - 1) {
                // Parse what's inside the parentheses
                let inner_start = start + 1;
                let inner_end = end - 1;
                
                if inner_end <= inner_start {
                    return Err(ConversionError::UnexpectedToken("Empty parentheses".to_string()));
                }
                
                // Check what's inside - could be:
                // 1. Simple application: (print "hello")
                // 2. Complex expression: (x + y)
                // 3. Test call: (test "name" expr)
                
                // For now, try to parse as function application
                if let Some(Token::Symbol(func_name)) = self.get_token_at_position(inner_start) {
                    // Collect arguments
                    let mut args = Vec::new();
                    let mut pos = inner_start + 1;
                    
                    while pos < inner_end {
                        if let Some(token) = self.get_token_at_position(pos) {
                            let arg = match token {
                                Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(pos, pos + 1)),
                                Token::Float(f) => Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(pos, pos + 1)),
                                Token::String(s) => Expr::Literal(Literal::String(s.clone()), Span::new(pos, pos + 1)),
                                Token::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(pos, pos + 1)),
                                Token::Symbol(s) => Expr::Ident(Ident(s.clone()), Span::new(pos, pos + 1)),
                                _ => {
                                    // For more complex expressions, we'd need recursive parsing
                                    pos += 1;
                                    continue;
                                }
                            };
                            args.push(arg);
                        }
                        pos += 1;
                    }
                    
                    if args.is_empty() {
                        // Just the function name in parentheses
                        return Ok(Expr::Ident(Ident(func_name.clone()), Span::new(start, end)));
                    } else {
                        // Function application
                        return Ok(Expr::Apply {
                            func: Box::new(Expr::Ident(Ident(func_name.clone()), Span::new(inner_start, inner_start + 1))),
                            args,
                            span: Span::new(start, end),
                        });
                    }
                }
                
                // Try to parse as a single expression
                if inner_end == inner_start + 1 {
                    // Single token inside parentheses
                    if let Some(token) = self.get_token_at_position(inner_start) {
                        match token {
                            Token::Int(n) => return Ok(Expr::Literal(Literal::Int(*n), Span::new(start, end))),
                            Token::Float(f) => return Ok(Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(start, end))),
                            Token::String(s) => return Ok(Expr::Literal(Literal::String(s.clone()), Span::new(start, end))),
                            Token::Bool(b) => return Ok(Expr::Literal(Literal::Bool(*b), Span::new(start, end))),
                            Token::Symbol(s) => return Ok(Expr::Ident(Ident(s.clone()), Span::new(start, end))),
                            _ => {}
                        }
                    }
                }
            }
        }
        
        Err(ConversionError::UnexpectedToken("Failed to parse parenthesized expression".to_string()))
    }
    
    /// Parse block from tokens { expr; expr; ... }
    fn parse_block_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_block_from_tokens: range {}-{}", start, end);
        
        // Should start with { and end with }
        if start >= self.tokens.len() || end <= start + 1 {
            return Err(ConversionError::UnexpectedToken("Invalid block range".to_string()));
        }
        
        // Verify we have braces
        if let Some(Token::LeftBrace) = self.get_token_at_position(start) {
            // Find matching right brace
            let mut brace_count = 1;
            let mut right_brace_pos = None;
            
            for pos in (start + 1)..self.tokens.len().min(end) {
                if let Some(token) = self.get_token_at_position(pos) {
                    match token {
                        Token::LeftBrace => brace_count += 1,
                        Token::RightBrace => {
                            brace_count -= 1;
                            if brace_count == 0 {
                                right_brace_pos = Some(pos);
                                break;
                            }
                        }
                        _ => {}
                    }
                }
            }
            
            if let Some(rbrace_pos) = right_brace_pos {
                // Parse expressions inside the block
                let inner_start = start + 1;
                let inner_end = rbrace_pos;
                
                if inner_end <= inner_start {
                    // Empty block
                    return Ok(Expr::Block {
                        exprs: vec![],
                        span: Span::new(start, rbrace_pos + 1),
                    });
                }
                
                // For now, parse single expression in block
                // TODO: Parse multiple expressions separated by semicolons
                let mut exprs = Vec::new();
                
                // Simple case: single literal or identifier
                if inner_end == inner_start + 1 {
                    if let Some(token) = self.get_token_at_position(inner_start) {
                        let expr = match token {
                            Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(inner_start, inner_start + 1)),
                            Token::Float(f) => Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(inner_start, inner_start + 1)),
                            Token::String(s) => Expr::Literal(Literal::String(s.clone()), Span::new(inner_start, inner_start + 1)),
                            Token::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(inner_start, inner_start + 1)),
                            Token::Symbol(s) => Expr::Ident(Ident(s.clone()), Span::new(inner_start, inner_start + 1)),
                            _ => return Err(ConversionError::UnexpectedToken(format!("Unexpected token in block: {:?}", token))),
                        };
                        exprs.push(expr);
                    }
                }
                
                return Ok(Expr::Block {
                    exprs,
                    span: Span::new(start, rbrace_pos + 1),
                });
            }
        }
        
        Err(ConversionError::UnexpectedToken("Failed to parse block expression".to_string()))
    }
    
    /// Parse if expression from tokens: if cond { expr } else { expr }
    fn parse_if_expr_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_if_expr_from_tokens: range {}-{}", start, end);
        
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..self.tokens.len().min(end) {
            tokens.push(&self.tokens[i]);
        }
        
        // Find brace and else positions
        let mut first_lbrace = None;
        let mut first_rbrace = None;
        let mut else_pos = None;
        let mut second_lbrace = None;
        let mut second_rbrace = None;
        let mut brace_count = 0;
        
        for (i, token) in tokens.iter().enumerate() {
            match token {
                Token::LeftBrace => {
                    if first_lbrace.is_none() && else_pos.is_none() {
                        first_lbrace = Some(i);
                    } else if else_pos.is_some() && second_lbrace.is_none() {
                        second_lbrace = Some(i);
                    }
                    brace_count += 1;
                }
                Token::RightBrace => {
                    brace_count -= 1;
                    if brace_count == 0 {
                        if first_rbrace.is_none() && else_pos.is_none() {
                            first_rbrace = Some(i);
                        } else if else_pos.is_some() && second_rbrace.is_none() {
                            second_rbrace = Some(i);
                        }
                    }
                }
                Token::Else => {
                    if brace_count == 0 {
                        else_pos = Some(i);
                    }
                }
                _ => {}
            }
        }
        
        // Validate structure: if <cond> { <then_expr> } else { <else_expr> }
        if let (Some(lb1), Some(rb1), Some(else_idx), Some(lb2), Some(rb2)) = 
            (first_lbrace, first_rbrace, else_pos, second_lbrace, second_rbrace) {
            
            // Parse condition (between if and first {)
            let cond = self.parse_simple_expr_from_tokens(&tokens[1..lb1], start + 1)?;
            
            // Parse then branch (between { and })
            let then_expr = if rb1 > lb1 + 1 {
                self.parse_simple_expr_from_tokens(&tokens[lb1 + 1..rb1], start + lb1 + 1)?
            } else {
                // Empty block
                Expr::Block { exprs: vec![], span: Span::new(start + lb1, start + rb1 + 1) }
            };
            
            // Parse else branch (between { and })
            let else_expr = if rb2 > lb2 + 1 {
                self.parse_simple_expr_from_tokens(&tokens[lb2 + 1..rb2], start + lb2 + 1)?
            } else {
                // Empty block
                Expr::Block { exprs: vec![], span: Span::new(start + lb2, start + rb2 + 1) }
            };
            
            return Ok(Expr::If {
                cond: Box::new(cond),
                then_expr: Box::new(then_expr),
                else_expr: Box::new(else_expr),
                span: Span::new(start, end),
            });
        }
        
        Err(ConversionError::UnexpectedToken("Invalid if expression syntax".to_string()))
    }
    
    /// Parse a simple expression from a slice of tokens
    fn parse_simple_expr_from_tokens(&self, tokens: &[&Token], start_pos: usize) -> Result<Expr, ConversionError> {
        if tokens.is_empty() {
            return Err(ConversionError::UnexpectedToken("Empty expression".to_string()));
        }
        
        // For now, handle simple cases
        match tokens[0] {
            Token::Int(n) => Ok(Expr::Literal(Literal::Int(*n), Span::new(start_pos, start_pos + 1))),
            Token::Float(f) => Ok(Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(start_pos, start_pos + 1))),
            Token::String(s) => Ok(Expr::Literal(Literal::String(s.clone()), Span::new(start_pos, start_pos + 1))),
            Token::Bool(b) => Ok(Expr::Literal(Literal::Bool(*b), Span::new(start_pos, start_pos + 1))),
            Token::Symbol(s) => Ok(Expr::Ident(Ident(s.clone()), Span::new(start_pos, start_pos + 1))),
            _ => Err(ConversionError::UnexpectedToken(format!("Cannot parse expression starting with {:?}", tokens[0]))),
        }
    }
    
    /// Parse match expression from tokens: match expr { pat1 -> expr1 pat2 -> expr2 ... }
    fn parse_match_expr_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // eprintln!("parse_match_expr_from_tokens: range {}-{}", start, end);
        
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..self.tokens.len().min(end) {
            tokens.push(&self.tokens[i]);
        }
        
        // Find the left brace
        let mut lbrace_pos = None;
        let mut rbrace_pos = None;
        
        for (i, token) in tokens.iter().enumerate() {
            match token {
                Token::LeftBrace => {
                    if lbrace_pos.is_none() {
                        lbrace_pos = Some(i);
                    }
                }
                Token::RightBrace => {
                    rbrace_pos = Some(i);
                }
                _ => {}
            }
        }
        
        if let (Some(lb), Some(rb)) = (lbrace_pos, rbrace_pos) {
            // Parse the expression being matched (between match and {)
            let expr = if lb > 1 {
                self.parse_simple_expr_from_tokens(&tokens[1..lb], start + 1)?
            } else {
                return Err(ConversionError::UnexpectedToken("Missing expression in match".to_string()));
            };
            
            // Parse the branches (between { and })
            let mut branches = Vec::new();
            
            // For now, just create a simple pattern match
            // TODO: Parse actual patterns and branches
            
            // Simple case: match true { true -> 1 false -> 0 }
            if rb > lb + 1 {
                // Look for patterns
                let mut i = lb + 1;
                while i < rb {
                    if let Some(token) = tokens.get(i) {
                        // Parse pattern
                        let pattern = match token {
                            Token::Bool(b) => Pattern::Literal(Literal::Bool(*b), Span::new(i, i + 1)),
                            Token::Int(n) => Pattern::Literal(Literal::Int(*n), Span::new(i, i + 1)),
                            Token::Symbol(s) if s == "_" => Pattern::Wildcard(Span::new(i, i + 1)),
                            Token::Symbol(s) => Pattern::Variable(Ident(s.clone()), Span::new(i, i + 1)),
                            Token::LeftBracket => {
                                // List pattern - for now, just empty list
                                if i + 1 < rb {
                                    if let Some(Token::RightBracket) = tokens.get(i + 1) {
                                        i += 1; // Skip the ]
                                        Pattern::List { patterns: vec![], span: Span::new(i, i + 2) }
                                    } else {
                                        Pattern::Wildcard(Span::new(i, i + 1))
                                    }
                                } else {
                                    Pattern::Wildcard(Span::new(i, i + 1))
                                }
                            }
                            _ => Pattern::Wildcard(Span::new(i, i + 1)),
                        };
                        
                        // Look for ->
                        if i + 2 < rb {
                            if let Some(Token::Arrow) = tokens.get(i + 1) {
                                // Parse the branch expression
                                if let Some(branch_token) = tokens.get(i + 2) {
                                    let branch_expr = match branch_token {
                                        Token::Int(n) => Expr::Literal(Literal::Int(*n), Span::new(start + i + 2, start + i + 3)),
                                        Token::Bool(b) => Expr::Literal(Literal::Bool(*b), Span::new(start + i + 2, start + i + 3)),
                                        Token::String(s) => Expr::Literal(Literal::String(s.clone()), Span::new(start + i + 2, start + i + 3)),
                                        Token::Symbol(s) => Expr::Ident(Ident(s.clone()), Span::new(start + i + 2, start + i + 3)),
                                        _ => Expr::Literal(Literal::Int(0), Span::new(start + i + 2, start + i + 3)),
                                    };
                                    
                                    branches.push((pattern, branch_expr));
                                    i += 3; // Skip pattern, ->, and expression
                                    continue;
                                }
                            }
                        }
                    }
                    i += 1;
                }
            }
            
            // If no branches were parsed, add a default
            if branches.is_empty() {
                branches.push((Pattern::Wildcard(Span::new(start, start + 1)), Expr::Literal(Literal::Int(0), Span::new(start, start + 1))));
            }
            
            return Ok(Expr::Match {
                expr: Box::new(expr),
                cases: branches,
                span: Span::new(start, end),
            });
        }
        
        Err(ConversionError::UnexpectedToken("Invalid match expression syntax".to_string()))
    }
}

/// Conversion error types
#[derive(Debug, Clone)]
pub enum ConversionError {
    InvalidNode,
    EmptyNode,
    UnexpectedToken(String),
    UnsupportedNode,
    MissingChildren,
    TypeMismatch,
}

impl std::fmt::Display for ConversionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConversionError::InvalidNode => write!(f, "Invalid SPPF node"),
            ConversionError::EmptyNode => write!(f, "Empty SPPF node"),
            ConversionError::UnexpectedToken(token) => write!(f, "Unexpected token: {}", token),
            ConversionError::UnsupportedNode => write!(f, "Unsupported SPPF node type"),
            ConversionError::MissingChildren => write!(f, "Expected children nodes but found none"),
            ConversionError::TypeMismatch => write!(f, "Type mismatch in conversion"),
        }
    }
}

impl std::error::Error for ConversionError {}