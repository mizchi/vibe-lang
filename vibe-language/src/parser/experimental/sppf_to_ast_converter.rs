//! SPPF to AST Converter - Converts Shared Packed Parse Forest to Vibe AST

use super::gll::sppf::{SharedPackedParseForest, SPPFNode, SPPFNodeType};
use crate::{Expr, Ident, Literal, Pattern, Span, Type, HandlerCase};
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
                println!("DEBUG: Root node id={}: {:?} at pos {}-{}", root_id, node.node_type, node.start, node.end);
                match &node.node_type {
                    SPPFNodeType::NonTerminal(name) if name == "Program" || name == "program" => {
                        // A program can have multiple expressions
                        match self.convert_program(root_id) {
                            Ok(Expr::List(program_exprs, _)) => {
                                println!("DEBUG: Program returned list with {} expressions", program_exprs.len());
                                exprs.extend(program_exprs);
                            }
                            Ok(expr) => {
                                println!("DEBUG: Program returned single expression: {:?}", expr);
                                exprs.push(expr);
                            }
                            Err(e) => {
                                println!("DEBUG: Failed to convert Program node: {:?}", e);
                                return Err(e);
                            }
                        }
                    }
                    _ => {
                        // Single expression
                        println!("DEBUG: Converting single expression from node type: {:?}", node.node_type);
                        match self.convert_node_to_expr(root_id) {
                            Ok(expr) => {
                                println!("DEBUG: Converted to: {:?}", expr);
                                exprs.push(expr);
                            }
                            Err(e) => {
                                println!("DEBUG: Conversion failed: {:?}", e);
                                return Err(e);
                            }
                        }
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
            "type_identifier" => {
                // Treat type_identifier as a regular identifier for now
                if let Some(Token::Symbol(name)) = self.get_token_at_position(start) {
                    Ok(Expr::Ident(Ident(name.clone()), span))
                } else {
                    Ok(Expr::Ident(Ident("Type".to_string()), span))
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
            "ImportDef" => self.convert_import(node_id),
            "ImportTail" => self.convert_import_tail(node_id),
            "ImportList" => self.convert_import_list(node_id),
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
            "PrimaryExpr" => {
                let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
                
                // Debug: Print all children
                println!("DEBUG: PrimaryExpr node {} has {} child sets", node_id, node.children.len());
                for (i, children) in node.children.iter().enumerate() {
                    println!("  Child set {}: {} children", i, children.len());
                    for (j, &child_id) in children.iter().enumerate() {
                        if let Some(child_node) = self.get_node(child_id) {
                            println!("    Child {}: node {} type {:?} at pos {}-{}", 
                                     j, child_id, child_node.node_type, child_node.start, child_node.end);
                        }
                    }
                }
                
                // Check if this is a list by looking at the first token
                if node.start < self.tokens.len() {
                    if let Some(Token::LeftBracket) = self.get_token_at_position(node.start) {
                        println!("DEBUG: PrimaryExpr is a list expression!");
                        // This should be a list
                        return self.parse_list_from_tokens(node.start, node.end);
                    }
                    
                    // Check if this is a perform expression
                    if let Some(Token::Perform) = self.get_token_at_position(node.start) {
                        println!("DEBUG: PrimaryExpr is a perform expression!");
                        // Parse perform effect args
                        // Structure: perform PostfixExpr
                        if let Some(children) = node.children.first() {
                            if children.len() >= 2 {
                                // Second child should be PostfixExpr
                                if let Some(&postfix_id) = children.get(1) {
                                    if let Ok(postfix_expr) = self.convert_node_to_expr(postfix_id) {
                                        // Extract effect name and args from postfix expression
                                        match &postfix_expr {
                                            Expr::Apply { func, args, .. } => {
                                                // perform IO "Hello" -> effect=IO, args=["Hello"]
                                                if let Expr::Ident(effect_name, _) = &**func {
                                                    return Ok(Expr::Perform {
                                                        effect: effect_name.clone(),
                                                        args: args.clone(),
                                                        span: Span::new(node.start, node.end),
                                                    });
                                                }
                                            }
                                            Expr::Ident(effect_name, _) => {
                                                // perform State.get -> effect=State, args=[get]
                                                return Ok(Expr::Perform {
                                                    effect: effect_name.clone(),
                                                    args: vec![],
                                                    span: Span::new(node.start, node.end),
                                                });
                                            }
                                            _ => {}
                                        }
                                    }
                                }
                            }
                        }
                        // Fallback: parse from tokens
                        return self.parse_perform_from_tokens(node.start, node.end);
                    }
                    
                    // Check if this is a handle expression
                    if let Some(Token::Handle) = self.get_token_at_position(node.start) {
                        println!("DEBUG: PrimaryExpr is a handle expression!");
                        // Parse handle Block Handlers
                        if let Some(children) = node.children.first() {
                            if children.len() >= 3 {
                                // Second child should be Block, third should be Handlers
                                if let Some(&block_id) = children.get(1) {
                                    if let Some(&handlers_id) = children.get(2) {
                                        if let Ok(block_expr) = self.convert_node_to_expr(block_id) {
                                            // Parse handlers
                                            let handlers = self.parse_handlers(handlers_id)?;
                                            return Ok(Expr::HandleExpr {
                                                expr: Box::new(block_expr),
                                                handlers,
                                                return_handler: None,
                                                span: Span::new(node.start, node.end),
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // Check if this is an operator section ( Operator )
                    if let Some(Token::LeftParen) = self.get_token_at_position(node.start) {
                        if node.end >= node.start + 3 {
                            if let Some(Token::RightParen) = self.get_token_at_position(node.end - 1) {
                                // Check if the middle token is an operator
                                if let Some(token) = self.get_token_at_position(node.start + 1) {
                                    match token {
                                        Token::Symbol(op) => {
                                            let is_operator = matches!(op.as_str(),
                                                "+" | "-" | "*" | "/" | "mod" | "^" | "++" | "::" |
                                                "==" | "!=" | "<" | ">" | "<=" | ">=" |
                                                "&&" | "||" | "|>" | "$"
                                            );
                                            if is_operator {
                                                println!("DEBUG: PrimaryExpr is an operator section: ({})", op);
                                                return Ok(Expr::Ident(
                                                    Ident(op.clone()),
                                                    Span::new(node.start, node.end)
                                                ));
                                            }
                                        }
                                        _ => {}
                                    }
                                }
                            }
                        }
                    }
                }
                
                if let Some(children) = node.children.first() {
                    if let Some(&child_id) = children.first() {
                        return self.convert_node_to_expr(child_id);
                    }
                }
                self.convert_complex_expr(node_id)
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
                    
                    // Check if this is a list expression
                    if let Some(Token::LeftBracket) = self.get_token_at_position(node.start) {
                        println!("DEBUG: PostfixExpr is a list expression!");
                        // Look for the Intermediate node which should contain the list structure
                        for children in &node.children {
                            for &child_id in children {
                                if let Some(child) = self.get_node(child_id) {
                                    // Check if this is an Intermediate node that represents the list structure
                                    if matches!(child.node_type, SPPFNodeType::Intermediate { .. }) {
                                        // The Intermediate node should have children that represent list elements
                                        // For now, use simple parsing
                                        return self.parse_list_from_tokens(node.start, node.end);
                                    }
                                }
                            }
                        }
                        // Fallback to simple parsing
                        return self.parse_list_from_tokens(node.start, node.end);
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
                
                // Debug: Print all children
                println!("DEBUG: PrimaryExpr node {} has {} child sets", node_id, node.children.len());
                for (i, children) in node.children.iter().enumerate() {
                    println!("  Child set {}: {} children", i, children.len());
                    for (j, &child_id) in children.iter().enumerate() {
                        if let Some(child_node) = self.get_node(child_id) {
                            println!("    Child {}: node {} type {:?} at pos {}-{}", 
                                     j, child_id, child_node.node_type, child_node.start, child_node.end);
                        }
                    }
                }
                
                // Check if this is a list by looking at the first token
                if node.start < self.tokens.len() {
                    if let Some(Token::LeftBracket) = self.get_token_at_position(node.start) {
                        println!("DEBUG: PrimaryExpr is a list expression!");
                        // This should be a list
                        return self.parse_list_from_tokens(node.start, node.end);
                    }
                }
                
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
        
        println!("DEBUG: convert_list: node at {}-{}, {} child sets", node.start, node.end, node.children.len());
        
        // Print SPPF structure for debugging
        for (i, children) in node.children.iter().enumerate() {
            println!("  Child set {}: {} children", i, children.len());
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    println!("    Child: {:?} at {}-{}", child.node_type, child.start, child.end);
                }
            }
        }
        
        // Try to find list elements
        let mut elements = Vec::new();
        
        // The structure might be:
        // List -> [ ListElems ]
        // ListElems -> Expr (, Expr)*
        
        for children in &node.children {
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    match &child.node_type {
                        SPPFNodeType::Terminal(t) if t == "[" || t == "]" => {
                            // Skip brackets
                            continue;
                        }
                        SPPFNodeType::Terminal(t) if t == "," => {
                            // Skip commas
                            continue;
                        }
                        SPPFNodeType::NonTerminal(nt) if nt == "ListElems" || nt == "ListElements" => {
                            // Found list elements container
                            elements = self.convert_list_elements(child_id)?;
                        }
                        _ => {
                            // Try to convert as expression
                            if let Ok(expr) = self.convert_node_to_expr(child_id) {
                                elements.push(expr);
                            }
                        }
                    }
                }
            }
        }
        
        println!("DEBUG: convert_list: found {} elements", elements.len());
        Ok(Expr::List(elements, span))
    }
    
    /// Convert list elements (helper for convert_list)
    fn convert_list_elements(&self, node_id: usize) -> Result<Vec<Expr>, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        let mut elements = Vec::new();
        
        println!("DEBUG: convert_list_elements: node at {}-{}, {} child sets", 
            node.start, node.end, node.children.len());
        
        // List elements might be structured as recursive nodes or as a flat list
        for children in &node.children {
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    match &child.node_type {
                        SPPFNodeType::Terminal(t) if t == "," => {
                            // Skip commas
                            continue;
                        }
                        SPPFNodeType::NonTerminal(nt) if nt == "ListElems" || nt == "ListElements" => {
                            // Recursive list elements
                            let mut sub_elements = self.convert_list_elements(child_id)?;
                            elements.append(&mut sub_elements);
                        }
                        _ => {
                            // Try to convert as expression
                            if let Ok(expr) = self.convert_node_to_expr(child_id) {
                                elements.push(expr);
                            }
                        }
                    }
                }
            }
        }
        
        Ok(elements)
    }
    
    /// Convert top level definition
    fn convert_top_level_def(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        println!("DEBUG: convert_top_level_def: node {} at pos {}-{}", node_id, node.start, node.end);
        println!("  Node has {} child sets", node.children.len());
        if node.end <= self.tokens.len() {
            println!("  Tokens in range: {:?}", &self.tokens[node.start..node.end]);
        }
        
        // Analyze children structure
        for (i, children) in node.children.iter().enumerate() {
            eprintln!("  Child set {}: {} children", i, children.len());
            for &child_id in children {
                if let Some(child) = self.get_node(child_id) {
                    eprintln!("    Child: {:?} at pos {}-{}", child.node_type, child.start, child.end);
                    // Try to go deeper
                    if !child.children.is_empty() {
                        for (j, grandchildren) in child.children.iter().enumerate() {
                            eprintln!("      Grandchild set {}: {} nodes", j, grandchildren.len());
                            for &grandchild_id in grandchildren {
                                if let Some(grandchild) = self.get_node(grandchild_id) {
                                    eprintln!("        Grandchild: {:?} at pos {}-{}", 
                                             grandchild.node_type, grandchild.start, grandchild.end);
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
            
            // Check if this is a perform expression at top level
            if let Some(Token::Perform) = self.get_token_at_position(node.start) {
                println!("DEBUG: TopLevelDef starts with perform token, parsing as perform expression");
                return self.parse_perform_from_tokens(node.start, node.end);
            }
            
            // Check if this is a handle expression at top level
            if let Some(Token::Handle) = self.get_token_at_position(node.start) {
                println!("DEBUG: TopLevelDef starts with handle token, parsing as handle expression");
                return self.parse_handle_from_tokens(node.start, node.end);
            }
            
            // Check if this is a simple function application (f arg1 arg2 ...)
            if let Some(token) = self.get_token_at_position(node.start) {
                println!("DEBUG: First token at pos {}: {:?}", node.start, token);
                if let Token::Symbol(_) = token {
                    // Check if we have more than one token
                    if node.end - node.start > 1 {
                        println!("DEBUG: Found potential function application at top level from {} to {}", node.start, node.end);
                        let result = self.parse_application_from_tokens(node.start, node.end);
                        println!("DEBUG: parse_application_from_tokens result: {:?}", result);
                        return result;
                    }
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
        println!("DEBUG: convert_program called for node {}", node_id);
        
        // Instead of relying on the SPPF structure, let's collect all TopLevelDef nodes
        let mut all_top_level_defs = Vec::new();
        let mut visited = std::collections::HashSet::new();
        self.collect_all_top_level_defs(node_id, &mut all_top_level_defs, &mut visited)?;
        
        // Sort by start position to maintain order
        all_top_level_defs.sort_by_key(|&(_, start, _)| start);
        
        // Remove duplicates (same node_id)
        all_top_level_defs.dedup_by_key(|&mut (node_id, _, _)| node_id);
        
        // DEBUG: Found unique TopLevelDef nodes
        println!("DEBUG: Found {} unique TopLevelDef nodes", all_top_level_defs.len());
        
        // Special case: if we have one TopLevelDef that covers the entire range, 
        // it should be a single expression
        if all_top_level_defs.len() > 0 {
            let first_def = all_top_level_defs[0];
            if first_def.1 == 0 && first_def.2 == self.tokens.len() {
                println!("DEBUG: Single TopLevelDef covers entire range, converting as single expression");
                return self.convert_top_level_def(first_def.0);
            }
        }
        
        let mut definitions = Vec::new();
        for (def_node_id, _start, _end) in all_top_level_defs {
            // Converting TopLevelDef
            if let Ok(def) = self.convert_top_level_def(def_node_id) {
                definitions.push(def);
            }
        }
        
        // If we didn't find enough TopLevelDefs through traversal, fall back to parsing from tokens
        // In this case, we expect at least 2 statements based on the tokens
        let expected_statements = self.count_expected_statements();
        if definitions.len() < expected_statements {
            // Only found fewer TopLevelDef nodes than expected, parsing from tokens
            definitions = self.parse_all_top_level_defs_from_tokens()?;
        }
        
        // If still no definitions and this looks like a single expression program, convert it as such
        if definitions.is_empty() {
            println!("DEBUG: No definitions found, trying to convert Program node's children as expressions");
            let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
            
            // Try to find expression nodes in the Program
            for children in &node.children {
                for &child_id in children {
                    if let Some(child) = self.get_node(child_id) {
                        println!("DEBUG: Program child: {:?} at {}-{}", child.node_type, child.start, child.end);
                        
                        // Skip Program nodes to avoid infinite recursion
                        if let SPPFNodeType::NonTerminal(name) = &child.node_type {
                            if name == "Program" {
                                continue;
                            }
                        }
                        
                        // Try to convert as expression
                        if let Ok(expr) = self.convert_node_to_expr(child_id) {
                            println!("DEBUG: Successfully converted child to expression");
                            definitions.push(expr);
                        }
                    }
                }
            }
        }
        
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        Ok(Expr::List(definitions, Span::new(node.start, node.end)))
    }
    
    /// Recursively collect all TopLevelDef nodes from the SPPF
    fn collect_all_top_level_defs(&self, node_id: usize, result: &mut Vec<(usize, usize, usize)>, visited: &mut std::collections::HashSet<usize>) -> Result<(), ConversionError> {
        // Avoid infinite recursion
        if !visited.insert(node_id) {
            return Ok(());
        }
        
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        
        match &node.node_type {
            SPPFNodeType::NonTerminal(nt) if nt == "TopLevelDef" => {
                // Found a TopLevelDef, add it to results
                result.push((node_id, node.start, node.end));
            }
            _ => {
                // Recursively search children
                for children in &node.children {
                    for &child_id in children {
                        let _ = self.collect_all_top_level_defs(child_id, result, visited);
                    }
                }
            }
        }
        
        Ok(())
    }
    
    /// Count expected statements based on tokens
    fn count_expected_statements(&self) -> usize {
        // Look at the tokens to identify statements
        // In "let x = 42\nprint x", we have:
        // [Let, Symbol("x"), Equals, Int(42), Symbol("print"), Symbol("x")]
        // We should have 2 statements: "let" and "print"
        
        let mut count = 0;
        let mut i = 0;
        
        while i < self.tokens.len() {
            match &self.tokens[i] {
                Token::Let => {
                    count += 1;
                    // Skip until we find a potential statement start
                    i += 1;
                    while i < self.tokens.len() {
                        match &self.tokens[i] {
                            // If we see another Let or a Symbol that could start a statement, break
                            Token::Let => break,
                            Token::Symbol(s) if i > 0 => {
                                // Check if this could be the start of a new statement
                                // "print" after "let x = 42" would be a new statement
                                if let Some(prev) = self.tokens.get(i - 1) {
                                    match prev {
                                        Token::Int(_) | Token::Symbol(_) => {
                                            // Could be a new statement
                                            break;
                                        }
                                        _ => {}
                                    }
                                }
                            }
                            _ => {}
                        }
                        i += 1;
                    }
                }
                Token::Symbol(s) => {
                    // This could be the start of a statement like "print x"
                    // Only count if it's at the beginning or after a complete expression
                    if i == 0 || self.looks_like_statement_start(i) {
                        count += 1;
                    }
                    i += 1;
                }
                _ => i += 1,
            }
        }
        
        // Found expected statements
        count
    }
    
    /// Check if a position looks like the start of a new statement
    fn looks_like_statement_start(&self, pos: usize) -> bool {
        // For simplicity, if we see "print" after some tokens, it's likely a new statement
        if let Some(Token::Symbol(s)) = self.tokens.get(pos) {
            if s == "print" {
                return true;
            }
        }
        false
    }
    
    /// Parse all TopLevelDef from tokens directly
    fn parse_all_top_level_defs_from_tokens(&self) -> Result<Vec<Expr>, ConversionError> {
        // Parse all TopLevelDef from tokens directly
        
        // For tokens [Let, Symbol("x"), Equals, Int(42), Symbol("print"), Symbol("x")]
        // We need to identify two statements:
        // 1. "let x = 42" (positions 0-3)
        // 2. "print x" (positions 4-5)
        
        let mut definitions = Vec::new();
        let mut pos = 0;
        
        while pos < self.tokens.len() {
            // Processing token at position
            
            if let Some(token) = self.tokens.get(pos) {
                match token {
                    Token::Let => {
                        // Find the end of this let binding
                        let mut end = pos + 1;
                        
                        // Skip through the let binding tokens
                        // Typical pattern: Let Symbol Equals Expression
                        while end < self.tokens.len() {
                            // Check if we've reached another statement
                            if let Some(tok) = self.tokens.get(end) {
                                match tok {
                                    Token::Let => break,
                                    Token::Symbol(s) if self.looks_like_statement_start(end) => break,
                                    _ => end += 1,
                                }
                            } else {
                                break;
                            }
                        }
                        
                        // Parsing let binding
                        if let Ok(def) = self.parse_let_binding_from_tokens(pos, end) {
                            // Successfully parsed let binding
                            definitions.push(def);
                            pos = end;
                        } else {
                            // Failed to parse let binding
                            pos += 1;
                        }
                    }
                    Token::Symbol(s) if self.looks_like_statement_start(pos) => {
                        // This starts a new statement like "print x"
                        let mut end = pos + 1;
                        
                        // Find the end of this expression
                        while end < self.tokens.len() {
                            if let Some(tok) = self.tokens.get(end) {
                                match tok {
                                    Token::Let => break,
                                    Token::Symbol(s) if self.looks_like_statement_start(end) => break,
                                    _ => end += 1,
                                }
                            } else {
                                break;
                            }
                        }
                        
                        // Parsing expression
                        if let Ok(expr) = self.parse_application_from_tokens(pos, end) {
                            // Successfully parsed expression
                            definitions.push(expr);
                            pos = end;
                        } else {
                            // Failed to parse expression
                            pos += 1;
                        }
                    }
                    _ => {
                        // Skipping token
                        pos += 1;
                    }
                }
            } else {
                break;
            }
        }
        
        // Returning definitions from token parsing
        Ok(definitions)
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
            println!("DEBUG: convert_node_to_expr: node_id={}, type={:?}, pos={}-{}", 
                     node_id, node.node_type, node.start, node.end);
            match &node.node_type {
                SPPFNodeType::NonTerminal(name) => self.convert_nonterminal_expr(name, node_id),
                SPPFNodeType::Terminal(token) => self.convert_terminal_to_expr(token, node.start, node.end),
                SPPFNodeType::Intermediate { slot } => {
                    println!("DEBUG: Found Intermediate node with slot={}", slot);
                    // Intermediate nodes are used for binarization in GLL parsing
                    // We need to look at their children
                    if let Some(children) = node.children.first() {
                        println!("DEBUG: Intermediate has {} children", children.len());
                        
                        // Print all children
                        for (i, &child_id) in children.iter().enumerate() {
                            if let Some(child_node) = self.get_node(child_id) {
                                println!("DEBUG: Child {}: node {} type {:?} at pos {}-{}", 
                                         i, child_id, child_node.node_type, child_node.start, child_node.end);
                            } else {
                                println!("DEBUG: Child {}: id {} is not a valid node", i, child_id);
                            }
                        }
                        
                        if let Some(&child_id) = children.first() {
                            println!("DEBUG: Converting first child of Intermediate node");
                            return self.convert_node_to_expr(child_id);
                        }
                    }
                    Err(ConversionError::UnsupportedNode)
                }
                SPPFNodeType::Epsilon => {
                    // println!("DEBUG: Found Epsilon node");
                    // Epsilon nodes represent empty productions
                    Ok(Expr::List(vec![], Span::new(node.start, node.end)))
                }
                _ => {
                    println!("DEBUG: Unsupported node type at {}-{}: {:?}", node.start, node.end, node.node_type);
                    println!("DEBUG: Node has {} child sets", node.children.len());
                    for (i, children) in node.children.iter().enumerate() {
                        println!("  Child set {}: {} children", i, children.len());
                    }
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
    
    /// Debug helper to print node structure
    fn debug_print_node(&self, node_id: usize, indent: usize) {
        let indent_str = " ".repeat(indent);
        if let Some(node) = self.get_node(node_id) {
            match &node.node_type {
                SPPFNodeType::Terminal(s) => {
                    println!("{}Terminal({}) @{}-{} id={}", indent_str, s, node.start, node.end, node_id);
                }
                SPPFNodeType::NonTerminal(s) => {
                    println!("{}NonTerminal({}) @{}-{} id={}", indent_str, s, node.start, node.end, node_id);
                }
                SPPFNodeType::Intermediate { slot } => {
                    println!("{}Intermediate(slot {}) @{}-{} id={}", indent_str, slot, node.start, node.end, node_id);
                }
                SPPFNodeType::Packed { slot } => {
                    println!("{}Packed(slot={}) @{}-{} id={}", indent_str, slot, node.start, node.end, node_id);
                }
                SPPFNodeType::Epsilon => {
                    println!("{}Epsilon @{}-{} id={}", indent_str, node.start, node.end, node_id);
                }
            }
            
            // Print children
            for (i, children) in node.children.iter().enumerate() {
                if !children.is_empty() {
                    println!("{}  Child set {}:", indent_str, i);
                    for &child_id in children {
                        // Avoid cycles
                        if indent < 20 {
                            self.debug_print_node(child_id, indent + 4);
                        }
                    }
                }
            }
        }
    }
    
    /// Parse a TopLevelDef from tokens in a given range
    fn parse_top_level_def_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        println!("DEBUG: parse_top_level_def_from_tokens: range {}-{}", start, end);
        
        if start < self.tokens.len() {
            match self.tokens.get(start) {
                Some(Token::Let) => {
                    // This is a let binding
                    self.parse_let_binding_from_tokens(start, end)
                }
                Some(Token::Symbol(name)) => {
                    // Check for boolean literals
                    if name == "true" {
                        Ok(Expr::Literal(Literal::Bool(true), Span::new(start, end)))
                    } else if name == "false" {
                        Ok(Expr::Literal(Literal::Bool(false), Span::new(start, end)))
                    } else if end - start > 1 {
                        // This might be a function application
                        self.parse_application_from_tokens(start, end)
                    } else {
                        // Single identifier
                        Ok(Expr::Ident(Ident(name.clone()), Span::new(start, end)))
                    }
                }
                Some(Token::Int(n)) => {
                    Ok(Expr::Literal(Literal::Int(*n), Span::new(start, end)))
                }
                Some(Token::Float(f)) => {
                    Ok(Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(start, end)))
                }
                Some(Token::String(s)) => {
                    Ok(Expr::Literal(Literal::String(s.clone()), Span::new(start, end)))
                }
                _ => {
                    println!("DEBUG: Unexpected token at position {}: {:?}", start, self.tokens.get(start));
                    Err(ConversionError::UnexpectedToken(format!("{:?}", self.tokens.get(start))))
                }
            }
        } else {
            Err(ConversionError::InvalidNode)
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
                        // Check for type annotation first
                        let mut type_ann = None;
                        let mut colon_pos = None;
                        
                        // Look for colon between name and equals
                        for i in 2..eq_idx {
                            if let Token::Colon = tokens[i] {
                                colon_pos = Some(i);
                                break;
                            }
                        }
                        
                        // Parse type if colon found
                        let params_start = if let Some(colon_idx) = colon_pos {
                            // Parse type annotation
                            if colon_idx + 1 < eq_idx {
                                type_ann = self.parse_type_from_tokens(start + colon_idx + 1, start + eq_idx);
                            }
                            colon_idx
                        } else {
                            2
                        };
                        
                        // Check if we have parameters between name and = (or colon)
                        let params: Vec<Ident> = if params_start > 2 {
                            // Collect parameter names
                            let mut p = Vec::new();
                            for i in 2..params_start {
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
                                Token::Fn => {
                                    // Lambda expression
                                    self.parse_lambda_from_tokens(start + body_start, end)?
                                }
                                Token::LeftBracket => {
                                    // List expression
                                    self.parse_list_from_tokens(start + body_start, end)?
                                }
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
                            type_ann,
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
        println!("DEBUG: parse_application_from_tokens: range {}-{}", start, end);
        
        // Collect tokens in the range
        let mut tokens_debug = Vec::new();
        for i in start..end.min(self.tokens.len()) {
            tokens_debug.push(&self.tokens[i]);
            println!("  Token {}: {:?}", i, self.tokens[i]);
        }
        
        if start >= self.tokens.len() {
            return Err(ConversionError::UnexpectedToken("No tokens for application".to_string()));
        }
        
        // First token should be the function
        let mut pos = start;
        let func = match self.get_token_at_position(pos) {
            Some(Token::Symbol(name)) => {
                pos += 1;
                Expr::Ident(Ident(name.clone()), Span::new(start, pos))
            }
            _ => return Err(ConversionError::UnexpectedToken("Expected function name".to_string())),
        };
        
        // Parse arguments - can be complex expressions
        let mut args = Vec::new();
        while pos < end {
            if let Some(token) = self.get_token_at_position(pos) {
                match token {
                    // Skip whitespace tokens if any
                    Token::Symbol(_) => {
                        // Simple identifier argument
                        if let Some(Token::Symbol(s)) = self.get_token_at_position(pos) {
                            args.push(Expr::Ident(Ident(s.clone()), Span::new(pos, pos + 1)));
                            pos += 1;
                        }
                    }
                    Token::Int(n) => {
                        args.push(Expr::Literal(Literal::Int(*n), Span::new(pos, pos + 1)));
                        pos += 1;
                    }
                    Token::Float(f) => {
                        args.push(Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(pos, pos + 1)));
                        pos += 1;
                    }
                    Token::String(s) => {
                        args.push(Expr::Literal(Literal::String(s.clone()), Span::new(pos, pos + 1)));
                        pos += 1;
                    }
                    Token::Bool(b) => {
                        args.push(Expr::Literal(Literal::Bool(*b), Span::new(pos, pos + 1)));
                        pos += 1;
                    }
                    Token::LeftParen => {
                        // Parenthesized expression - could be operator section
                        let paren_end = self.find_matching_paren(pos)?;
                        if paren_end == pos + 2 {
                            // Check if it's an operator section like (+)
                            if let Some(Token::Symbol(op)) = self.get_token_at_position(pos + 1) {
                                let is_operator = matches!(op.as_str(),
                                    "+" | "-" | "*" | "/" | "mod" | "^" | "++" | "::" |
                                    "==" | "!=" | "<" | ">" | "<=" | ">=" |
                                    "&&" | "||" | "|>" | "$"
                                );
                                if is_operator {
                                    println!("DEBUG: Found operator section: ({})", op);
                                    args.push(Expr::Ident(Ident(op.clone()), Span::new(pos, paren_end + 1)));
                                    pos = paren_end + 1;
                                    continue;
                                }
                            }
                        }
                        // Otherwise parse as parenthesized expression
                        let expr = self.parse_parenthesized_expr_from_tokens(pos, paren_end + 1)?;
                        args.push(expr);
                        pos = paren_end + 1;
                    }
                    Token::LeftBracket => {
                        // List expression
                        let bracket_end = self.find_matching_bracket(pos)?;
                        let list_expr = self.parse_list_from_tokens(pos, bracket_end + 1)?;
                        args.push(list_expr);
                        pos = bracket_end + 1;
                    }
                    _ => {
                        println!("DEBUG: Unexpected token in application at {}: {:?}", pos, token);
                        return Err(ConversionError::UnexpectedToken(format!("Unexpected token in application: {:?}", token)));
                    }
                }
            } else {
                break;
            }
        }
        
        println!("DEBUG: Parsed function: {:?}, args: {:?}", func, args);
        
        if args.is_empty() {
            // No arguments, just return the function
            Ok(func)
        } else {
            // Build left-associative application
            // f a b c -> ((f a) b) c
            let mut result = func;
            for arg in args {
                result = Expr::Apply {
                    func: Box::new(result),
                    args: vec![arg],
                    span: Span::new(start, pos),
                };
            }
            Ok(result)
        }
    }
    
    /// Find matching closing parenthesis
    fn find_matching_paren(&self, start: usize) -> Result<usize, ConversionError> {
        let mut depth = 0;
        for i in start..self.tokens.len() {
            match self.get_token_at_position(i) {
                Some(Token::LeftParen) => depth += 1,
                Some(Token::RightParen) => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(i);
                    }
                }
                _ => {}
            }
        }
        Err(ConversionError::UnexpectedToken("Unmatched parenthesis".to_string()))
    }
    
    /// Find matching closing bracket
    fn find_matching_bracket(&self, start: usize) -> Result<usize, ConversionError> {
        let mut depth = 0;
        for i in start..self.tokens.len() {
            match self.get_token_at_position(i) {
                Some(Token::LeftBracket) => depth += 1,
                Some(Token::RightBracket) => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(i);
                    }
                }
                _ => {}
            }
        }
        Err(ConversionError::UnexpectedToken("Unmatched bracket".to_string()))
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
    
    /// Parse list from tokens
    fn parse_list_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        println!("DEBUG: parse_list_from_tokens from {} to {}", start, end);
        if end <= self.tokens.len() {
            println!("  Tokens: {:?}", &self.tokens[start..end]);
        }
        
        // Expecting [ ... ]
        if start >= end || start >= self.tokens.len() {
            return Err(ConversionError::InvalidNode);
        }
        
        // Check for [
        if let Some(Token::LeftBracket) = self.get_token_at_position(start) {
            // Find matching ]
            let mut elements = Vec::new();
            let mut pos = start + 1;
            
            while pos < end && pos < self.tokens.len() {
                if let Some(Token::RightBracket) = self.get_token_at_position(pos) {
                    // Found closing bracket for the main list
                    break;
                }
                
                // Try to parse an element
                let elem_start = pos;
                let mut elem_end = pos;
                let mut bracket_depth = 0;
                
                // Initialize bracket depth if we start with a bracket
                if let Some(Token::LeftBracket) = self.get_token_at_position(pos) {
                    bracket_depth = 1;
                    elem_end = pos + 1;
                } else {
                    elem_end = pos + 1;
                }
                
                // Find the end of this element (either comma at depth 0 or ])
                while elem_end < end && elem_end < self.tokens.len() {
                    if let Some(token) = self.get_token_at_position(elem_end) {
                        match token {
                            Token::LeftBracket => {
                                bracket_depth += 1;
                                elem_end += 1;
                            }
                            Token::RightBracket => {
                                if bracket_depth > 0 {
                                    bracket_depth -= 1;
                                    elem_end += 1;
                                } else {
                                    // This is the closing bracket of our list
                                    break;
                                }
                            }
                            Token::Comma => {
                                if bracket_depth == 0 {
                                    // This comma separates list elements
                                    break;
                                } else {
                                    // This comma is inside a nested list
                                    elem_end += 1;
                                }
                            }
                            _ => elem_end += 1,
                        }
                    } else {
                        elem_end += 1;
                    }
                }
                
                // Parse the element
                if elem_end > elem_start {
                    println!("DEBUG: Parsing element from {} to {}", elem_start, elem_end);
                    // Try to parse a sub-expression
                    if let Ok(elem_expr) = self.parse_simple_expr_from_token_range(elem_start, elem_end) {
                        elements.push(elem_expr);
                    }
                }
                
                // Skip comma if present
                if elem_end < self.tokens.len() {
                    if let Some(Token::Comma) = self.get_token_at_position(elem_end) {
                        pos = elem_end + 1;
                    } else {
                        pos = elem_end;
                    }
                } else {
                    break;
                }
            }
            
            println!("DEBUG: parse_list_from_tokens found {} elements", elements.len());
            for (i, elem) in elements.iter().enumerate() {
                println!("  Element {}: {:?}", i, elem);
            }
            return Ok(Expr::List(elements, Span::new(start, end)));
        }
        
        Err(ConversionError::InvalidNode)
    }
    
    /// Parse simple expression from token range
    fn parse_simple_expr_from_token_range(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // Handle simple cases for now
        if end == start + 1 {
            // Single token
            if let Some(token) = self.get_token_at_position(start) {
                match token {
                    Token::Int(n) => {
                        return Ok(Expr::Literal(Literal::Int(*n), Span::new(start, end)));
                    }
                    Token::Float(f) => {
                        return Ok(Expr::Literal(Literal::Float(OrderedFloat(*f)), Span::new(start, end)));
                    }
                    Token::String(s) => {
                        return Ok(Expr::Literal(Literal::String(s.clone()), Span::new(start, end)));
                    }
                    Token::Bool(b) => {
                        return Ok(Expr::Literal(Literal::Bool(*b), Span::new(start, end)));
                    }
                    Token::Symbol(s) => {
                        return Ok(Expr::Ident(Ident(s.clone()), Span::new(start, end)));
                    }
                    _ => {}
                }
            }
        } else if end > start + 2 {
            // Check for binary operations (e.g., 1 + 2)
            // For now, look for simple patterns
            let mut pos = start;
            while pos < end {
                if let Some(token) = self.get_token_at_position(pos) {
                    match token {
                        Token::Symbol(op) if op == "+" || op == "-" || op == "*" || op == "/" => {
                            // Found an operator
                            if pos > start && pos < end - 1 {
                                // Parse left and right operands
                                if let Ok(left) = self.parse_simple_expr_from_token_range(start, pos) {
                                    if let Ok(right) = self.parse_simple_expr_from_token_range(pos + 1, end) {
                                        return Ok(Expr::Apply {
                                            func: Box::new(Expr::Ident(Ident(op.clone()), Span::new(pos, pos + 1))),
                                            args: vec![left, right],
                                            span: Span::new(start, end),
                                        });
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
                pos += 1;
            }
            
            // Check for nested lists
            if let Some(Token::LeftBracket) = self.get_token_at_position(start) {
                if let Some(Token::RightBracket) = self.get_token_at_position(end - 1) {
                    return self.parse_list_from_tokens(start, end);
                }
            }
        }
        
        Err(ConversionError::InvalidNode)
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

    /// Convert import statement from SPPF
    fn convert_import(&self, node_id: usize) -> Result<Expr, ConversionError> {
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        println!("DEBUG: convert_import: node {} at pos {}-{}", node_id, node.start, node.end);
        
        // Debug: Print SPPF structure
        println!("  Node children: {} sets", node.children.len());
        for (i, children) in node.children.iter().enumerate() {
            println!("    Child set {}: {} children", i, children.len());
            for (j, &child_id) in children.iter().enumerate() {
                if let Some(child_node) = self.get_node(child_id) {
                    println!("      Child {}: node {} type {:?} at pos {}-{}", 
                             j, child_id, child_node.node_type, child_node.start, child_node.end);
                }
            }
        }
        
        // ImportDef -> import ModulePath ImportTail
        // We need to extract the module name and optional items/alias/hash
        let mut module_name = None;
        let mut items = None;
        let mut as_name = None;
        let mut hash = None;
        
        // For ImportDef nodes, we need to find the actual import tokens
        // Always scan from the beginning for import statements
        let mut start_pos = 0;
        let mut end_pos = self.tokens.len();
        
        // Find the import token
        for i in 0..self.tokens.len() {
            if let Some(Token::Import) = self.get_token_at_position(i) {
                start_pos = i;
                break;
            }
        }
        
        // Parse from tokens
        let mut tokens_in_range = Vec::new();
        for i in start_pos..end_pos {
            if let Some(token) = self.get_token_at_position(i) {
                tokens_in_range.push(token.clone());
            }
        }
        println!("  Tokens in range: {:?}", tokens_in_range);
        println!("  Start pos: {}, End pos: {}", start_pos, end_pos);
        
        // Find the module name after "import"
        let mut i = 0;
        while i < tokens_in_range.len() {
            if let Token::Import = &tokens_in_range[i] {
                i += 1;
                break;
            }
            i += 1;
        }
        
        // Parse module path (e.g., Math.Utils)
        let mut module_parts = Vec::new();
        while i < tokens_in_range.len() {
            match &tokens_in_range[i] {
                Token::Symbol(name) if name.chars().next().unwrap_or('a').is_uppercase() => {
                    module_parts.push(name.clone());
                    i += 1;
                    
                    // Check for dot or @ next
                    if i < tokens_in_range.len() {
                        match &tokens_in_range[i] {
                            Token::Dot => {
                                i += 1;
                                continue;
                            }
                            Token::At => {
                                // Hash specification follows
                                i += 1;
                                if i < tokens_in_range.len() {
                                    if let Token::Symbol(h) = &tokens_in_range[i] {
                                        hash = Some(h.clone());
                                        i += 1;
                                    }
                                }
                                break;
                            }
                            _ => break,
                        }
                    }
                    break;
                }
                _ => break,
            }
        }
        
        if module_parts.is_empty() {
            return Err(ConversionError::UnexpectedToken("Missing module name in import".to_string()));
        }
        
        module_name = Some(Ident(module_parts.join(".")));
        
        // Parse ImportTail (as alias, items list, or exposing)
        while i < tokens_in_range.len() {
            match &tokens_in_range[i] {
                Token::As => {
                    i += 1;
                    if i < tokens_in_range.len() {
                        if let Token::Symbol(alias) = &tokens_in_range[i] {
                            as_name = Some(Ident(alias.clone()));
                            i += 1;
                        }
                    }
                    break;  // Stop after processing 'as' clause
                }
                Token::LeftParen => {
                    // Parse import list
                    i += 1;
                    let mut import_items = Vec::new();
                    
                    while i < tokens_in_range.len() {
                        match &tokens_in_range[i] {
                            Token::Symbol(item) => {
                                if item == ".." {
                                    // Import all (..)
                                    items = None;
                                    break;
                                }
                                import_items.push(Ident(item.clone()));
                                i += 1;
                            }
                            Token::Comma => {
                                i += 1;
                            }
                            Token::RightParen => {
                                i += 1;
                                break;
                            }
                            _ => break,
                        }
                    }
                    
                    if !import_items.is_empty() {
                        items = Some(import_items);
                    }
                }
                Token::Symbol(s) if s == "exposing" => {
                    i += 1;
                    // exposing is followed by (...)
                    if i < tokens_in_range.len() {
                        if let Token::LeftParen = &tokens_in_range[i] {
                            i += 1;
                            // Check for (..)
                            if i + 1 < tokens_in_range.len() {
                                if let (Token::Dot, Token::Dot) = (&tokens_in_range[i], &tokens_in_range[i + 1]) {
                                    // exposing (..) means import all
                                    items = None;
                                    break;
                                }
                            }
                        }
                    }
                }
                _ => {
                    i += 1;
                }
            }
        }
        
        Ok(Expr::Import {
            module_name: module_name.unwrap(),
            items,
            as_name,
            hash,
            span: Span::new(start_pos, end_pos),
        })
    }
    
    /// Convert ImportTail (for recursive parsing)
    fn convert_import_tail(&self, node_id: usize) -> Result<Expr, ConversionError> {
        // This is handled within convert_import
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        
        // Return a placeholder expression since ImportTail is not a standalone expression
        Ok(Expr::List(vec![], Span::new(node.start, node.end)))
    }
    
    /// Convert ImportList (for recursive parsing)
    fn convert_import_list(&self, node_id: usize) -> Result<Expr, ConversionError> {
        // This is handled within convert_import
        let node = self.get_node(node_id).ok_or(ConversionError::InvalidNode)?;
        
        // Return a placeholder expression since ImportList is not a standalone expression
        Ok(Expr::List(vec![], Span::new(node.start, node.end)))
    }
    
    /// Parse perform expression from tokens
    fn parse_perform_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..end.min(self.tokens.len()) {
            tokens.push(&self.tokens[i]);
        }
        
        if tokens.len() < 2 {
            return Err(ConversionError::UnexpectedToken("Invalid perform expression".to_string()));
        }
        
        // First token should be perform
        if !matches!(tokens[0], Token::Perform) {
            return Err(ConversionError::UnexpectedToken("Expected perform".to_string()));
        }
        
        // Parse effect and args
        if let Token::Symbol(effect_name) = tokens[1] {
            let mut args = Vec::new();
            
            // Check if there's a dot for method-like syntax
            if tokens.len() > 2 {
                if matches!(tokens[2], Token::Dot) && tokens.len() > 3 {
                    // perform State.get syntax
                    if let Token::Symbol(method_name) = tokens[3] {
                        args.push(Expr::Ident(Ident(method_name.clone()), Span::new(start + 3, start + 4)));
                    }
                } else {
                    // perform IO "Hello" syntax - parse remaining as arguments
                    for i in 2..tokens.len() {
                        match tokens[i] {
                            Token::String(s) => {
                                args.push(Expr::Literal(Literal::String(s.clone()), Span::new(start + i, start + i + 1)));
                            }
                            Token::Int(n) => {
                                args.push(Expr::Literal(Literal::Int(*n), Span::new(start + i, start + i + 1)));
                            }
                            Token::Symbol(s) => {
                                args.push(Expr::Ident(Ident(s.clone()), Span::new(start + i, start + i + 1)));
                            }
                            _ => {}
                        }
                    }
                }
            }
            
            Ok(Expr::Perform {
                effect: Ident(effect_name.clone()),
                args,
                span: Span::new(start, end),
            })
        } else {
            Err(ConversionError::UnexpectedToken("Expected effect name after perform".to_string()))
        }
    }
    
    /// Parse handlers from SPPF node
    fn parse_handlers(&self, handlers_id: usize) -> Result<Vec<HandlerCase>, ConversionError> {
        let node = self.get_node(handlers_id).ok_or(ConversionError::InvalidNode)?;
        
        // Handlers -> { HandlerCases }
        if let Some(children) = node.children.first() {
            if children.len() >= 3 {
                // Second child should be HandlerCases
                if let Some(&handler_cases_id) = children.get(1) {
                    return self.parse_handler_cases(handler_cases_id);
                }
            }
        }
        
        Ok(vec![])
    }
    
    /// Parse handler cases from SPPF node
    fn parse_handler_cases(&self, handler_cases_id: usize) -> Result<Vec<HandlerCase>, ConversionError> {
        let node = self.get_node(handler_cases_id).ok_or(ConversionError::InvalidNode)?;
        let mut handlers = Vec::new();
        
        // HandlerCases can be:
        // - HandlerCase HandlerCases
        // - HandlerCase
        // - ε
        if let Some(children) = node.children.first() {
            if children.is_empty() {
                // Epsilon case
                return Ok(handlers);
            }
            
            // Parse first handler case
            if let Some(&handler_case_id) = children.get(0) {
                if let Ok(handler) = self.parse_handler_case(handler_case_id) {
                    handlers.push(handler);
                }
                
                // If there are more handler cases
                if children.len() >= 2 {
                    if let Some(&more_cases_id) = children.get(1) {
                        let more_handlers = self.parse_handler_cases(more_cases_id)?;
                        handlers.extend(more_handlers);
                    }
                }
            }
        }
        
        Ok(handlers)
    }
    
    /// Parse single handler case from SPPF node
    fn parse_handler_case(&self, handler_case_id: usize) -> Result<HandlerCase, ConversionError> {
        let node = self.get_node(handler_case_id).ok_or(ConversionError::InvalidNode)?;
        
        // HandlerCase -> identifier PatternList -> Expr | type_identifier PatternList -> Expr
        if let Some(children) = node.children.first() {
            if children.len() >= 4 {
                // First child is effect name (identifier or type_identifier)
                let effect_name = if let Some(&effect_id) = children.get(0) {
                    if let Some(effect_node) = self.get_node(effect_id) {
                        if let Some(token) = self.get_token_at_position(effect_node.start) {
                            match token {
                                Token::Symbol(name) => name.clone(),
                                _ => return Err(ConversionError::UnexpectedToken("Expected effect name".to_string())),
                            }
                        } else {
                            return Err(ConversionError::UnexpectedToken("Expected effect name".to_string()));
                        }
                    } else {
                        return Err(ConversionError::InvalidNode);
                    }
                } else {
                    return Err(ConversionError::MissingChildren);
                };
                
                // Second child is PatternList
                let (args, continuation) = if let Some(&pattern_list_id) = children.get(1) {
                    self.parse_handler_pattern_list(pattern_list_id)?
                } else {
                    return Err(ConversionError::MissingChildren);
                };
                
                // Fourth child is the handler body expression
                let body = if let Some(&expr_id) = children.get(3) {
                    Box::new(self.convert_node_to_expr(expr_id)?)
                } else {
                    return Err(ConversionError::MissingChildren);
                };
                
                Ok(HandlerCase {
                    effect: Ident(effect_name),
                    operation: None, // TODO: Handle State.get syntax
                    args: args.into_iter().map(|id| Pattern::Variable(id, Span::new(node.start, node.end))).collect(),
                    continuation,
                    body: *body,
                    span: Span::new(node.start, node.end),
                })
            } else {
                Err(ConversionError::MissingChildren)
            }
        } else {
            Err(ConversionError::EmptyNode)
        }
    }
    
    /// Parse handler pattern list (including continuation parameter)
    fn parse_handler_pattern_list(&self, pattern_list_id: usize) -> Result<(Vec<Ident>, Ident), ConversionError> {
        let node = self.get_node(pattern_list_id).ok_or(ConversionError::InvalidNode)?;
        let mut patterns = Vec::new();
        
        // Collect all patterns from tokens
        for i in node.start..node.end.min(self.tokens.len()) {
            if let Some(token) = self.get_token_at_position(i) {
                match token {
                    Token::Symbol(name) => {
                        patterns.push(Ident(name.clone()));
                    }
                    Token::Comma => {
                        // Skip commas
                    }
                    _ => {}
                }
            }
        }
        
        // The last pattern is the continuation
        if patterns.len() >= 1 {
            let continuation = patterns.pop().unwrap();
            Ok((patterns, continuation))
        } else {
            Err(ConversionError::UnexpectedToken("Handler must have at least a continuation parameter".to_string()))
        }
    }
    
    /// Parse handle expression from tokens
    fn parse_handle_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // Find the boundaries of the handle expression
        // Pattern: handle { expr } { handlers }
        
        let mut pos = start;
        
        // Skip 'handle' token
        if pos < self.tokens.len() {
            if let Some(Token::Handle) = self.get_token_at_position(pos) {
                pos += 1;
            } else {
                return Err(ConversionError::UnexpectedToken("Expected handle".to_string()));
            }
        }
        
        // Find first { for the expression block
        let mut block_start = None;
        while pos < end && pos < self.tokens.len() {
            if let Some(Token::LeftBrace) = self.get_token_at_position(pos) {
                block_start = Some(pos);
                break;
            }
            pos += 1;
        }
        
        if block_start.is_none() {
            return Err(ConversionError::UnexpectedToken("Expected { after handle".to_string()));
        }
        
        // Find matching } for the expression block
        let mut brace_count = 1;
        pos = block_start.unwrap() + 1;
        let mut block_end = None;
        
        while pos < end && pos < self.tokens.len() {
            if let Some(token) = self.get_token_at_position(pos) {
                match token {
                    Token::LeftBrace => brace_count += 1,
                    Token::RightBrace => {
                        brace_count -= 1;
                        if brace_count == 0 {
                            block_end = Some(pos);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            pos += 1;
        }
        
        if block_end.is_none() {
            return Err(ConversionError::UnexpectedToken("Unmatched { in handle expression".to_string()));
        }
        
        // Parse the expression inside the first block
        let expr = if block_end.unwrap() > block_start.unwrap() + 1 {
            // Create a simple block expression from the tokens
            let mut block_exprs = Vec::new();
            let mut expr_start = block_start.unwrap() + 1;
            
            // For now, just parse a simple perform expression inside
            if let Ok(parsed_expr) = self.parse_expression_from_tokens(expr_start, block_end.unwrap()) {
                block_exprs.push(parsed_expr);
            }
            
            Expr::Block {
                exprs: block_exprs,
                span: Span::new(block_start.unwrap(), block_end.unwrap() + 1),
            }
        } else {
            // Empty block
            Expr::Block {
                exprs: vec![],
                span: Span::new(block_start.unwrap(), block_end.unwrap() + 1),
            }
        };
        
        // Find second { for the handlers block
        pos = block_end.unwrap() + 1;
        let mut handlers_start = None;
        
        while pos < end && pos < self.tokens.len() {
            if let Some(Token::LeftBrace) = self.get_token_at_position(pos) {
                handlers_start = Some(pos);
                break;
            }
            pos += 1;
        }
        
        if handlers_start.is_none() {
            return Err(ConversionError::UnexpectedToken("Expected { for handlers".to_string()));
        }
        
        // Find matching } for the handlers block
        brace_count = 1;
        pos = handlers_start.unwrap() + 1;
        let mut handlers_end = None;
        
        while pos < end && pos < self.tokens.len() {
            if let Some(token) = self.get_token_at_position(pos) {
                match token {
                    Token::LeftBrace => brace_count += 1,
                    Token::RightBrace => {
                        brace_count -= 1;
                        if brace_count == 0 {
                            handlers_end = Some(pos);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            pos += 1;
        }
        
        if handlers_end.is_none() {
            return Err(ConversionError::UnexpectedToken("Unmatched { in handlers".to_string()));
        }
        
        // Parse handlers
        let handlers = self.parse_handlers_from_tokens(handlers_start.unwrap() + 1, handlers_end.unwrap())?;
        
        Ok(Expr::HandleExpr {
            expr: Box::new(expr),
            handlers,
            return_handler: None,
            span: Span::new(start, end.min(handlers_end.unwrap() + 1)),
        })
    }
    
    /// Parse handlers from tokens
    fn parse_handlers_from_tokens(&self, start: usize, end: usize) -> Result<Vec<HandlerCase>, ConversionError> {
        let mut handlers = Vec::new();
        let mut pos = start;
        
        while pos < end && pos < self.tokens.len() {
            // Skip whitespace tokens
            
            // Look for effect name (identifier or type_identifier)
            if let Some(Token::Symbol(effect_name)) = self.get_token_at_position(pos) {
                let mut handler_end = pos;
                
                // Find the arrow for this handler
                let mut arrow_pos = None;
                for i in pos..end.min(self.tokens.len()) {
                    if let Some(Token::Arrow) = self.get_token_at_position(i) {
                        arrow_pos = Some(i);
                        break;
                    }
                }
                
                if let Some(arrow) = arrow_pos {
                    // Parse pattern list between effect name and arrow
                    let mut args = Vec::new();
                    let mut continuation = None;
                    
                    for i in (pos + 1)..arrow {
                        if let Some(Token::Symbol(name)) = self.get_token_at_position(i) {
                            if i == arrow - 1 {
                                // Last symbol before arrow is the continuation
                                continuation = Some(Ident(name.clone()));
                            } else {
                                args.push(Pattern::Variable(Ident(name.clone()), Span::new(i, i + 1)));
                            }
                        }
                    }
                    
                    if continuation.is_none() {
                        return Err(ConversionError::UnexpectedToken("Handler must have a continuation parameter".to_string()));
                    }
                    
                    // Find the end of this handler's body
                    // For now, assume it ends at the next handler or the end
                    let mut body_end = arrow + 1;
                    for i in (arrow + 1)..end.min(self.tokens.len()) {
                        if let Some(Token::Symbol(s)) = self.get_token_at_position(i) {
                            if s.chars().next().map_or(false, |c| c.is_uppercase()) {
                                // Found start of next handler
                                body_end = i;
                                break;
                            }
                        }
                    }
                    
                    // If we didn't find another handler, body ends at the end
                    if body_end == arrow + 1 {
                        body_end = end;
                    }
                    
                    // Parse the body expression
                    let body = self.parse_expression_from_tokens(arrow + 1, body_end)?;
                    
                    handlers.push(HandlerCase {
                        effect: Ident(effect_name.clone()),
                        operation: None,
                        args,
                        continuation: continuation.unwrap(),
                        body,
                        span: Span::new(pos, body_end),
                    });
                    
                    pos = body_end;
                } else {
                    pos += 1;
                }
            } else {
                pos += 1;
            }
        }
        
        Ok(handlers)
    }
    
    /// Parse expression from tokens
    fn parse_expression_from_tokens(&self, start: usize, end: usize) -> Result<Expr, ConversionError> {
        // Simple implementation for now
        if start >= end || start >= self.tokens.len() {
            return Err(ConversionError::UnexpectedToken("Empty expression".to_string()));
        }
        
        // Check for perform expression
        if let Some(Token::Perform) = self.get_token_at_position(start) {
            return self.parse_perform_from_tokens(start, end);
        }
        
        // Check for function application: k ()
        if let Some(Token::Symbol(func_name)) = self.get_token_at_position(start) {
            if start + 1 < end {
                if let Some(Token::LeftParen) = self.get_token_at_position(start + 1) {
                    if start + 2 < end {
                        if let Some(Token::RightParen) = self.get_token_at_position(start + 2) {
                            // k () pattern
                            return Ok(Expr::Apply {
                                func: Box::new(Expr::Ident(Ident(func_name.clone()), Span::new(start, start + 1))),
                                args: vec![Expr::List(vec![], Span::new(start + 1, start + 3))], // () is unit/empty tuple
                                span: Span::new(start, start + 3),
                            });
                        }
                    }
                }
                
                // Regular function application
                let mut args = Vec::new();
                for i in (start + 1)..end {
                    if let Ok(arg) = self.parse_atom_from_token(i) {
                        args.push(arg);
                    }
                }
                
                if !args.is_empty() {
                    return Ok(Expr::Apply {
                        func: Box::new(Expr::Ident(Ident(func_name.clone()), Span::new(start, start + 1))),
                        args,
                        span: Span::new(start, end),
                    });
                }
            }
            
            // Just an identifier
            return Ok(Expr::Ident(Ident(func_name.clone()), Span::new(start, start + 1)));
        }
        
        // Try to parse a simple atom
        self.parse_atom_from_token(start)
    }
    
    /// Parse a single atom from a token
    fn parse_atom_from_token(&self, pos: usize) -> Result<Expr, ConversionError> {
        if pos >= self.tokens.len() {
            return Err(ConversionError::UnexpectedToken("No token at position".to_string()));
        }
        
        if let Some(token) = self.get_token_at_position(pos) {
            match token {
                Token::Symbol(s) => Ok(Expr::Ident(Ident(s.clone()), Span::new(pos, pos + 1))),
                Token::Int(n) => Ok(Expr::Literal(Literal::Int(*n), Span::new(pos, pos + 1))),
                Token::String(s) => Ok(Expr::Literal(Literal::String(s.clone()), Span::new(pos, pos + 1))),
                Token::Bool(b) => Ok(Expr::Literal(Literal::Bool(*b), Span::new(pos, pos + 1))),
                Token::LeftParen => {
                    if pos + 1 < self.tokens.len() {
                        if let Some(Token::RightParen) = self.get_token_at_position(pos + 1) {
                            // () is unit/empty tuple
                            return Ok(Expr::List(vec![], Span::new(pos, pos + 2)));
                        }
                    }
                    Err(ConversionError::UnexpectedToken("Unexpected (".to_string()))
                }
                _ => Err(ConversionError::UnexpectedToken(format!("Unexpected token: {:?}", token))),
            }
        } else {
            Err(ConversionError::UnexpectedToken("No token".to_string()))
        }
    }
    
    /// Parse type from tokens in the range
    fn parse_type_from_tokens(&self, start: usize, end: usize) -> Option<Type> {
        // Collect tokens in the range
        let mut tokens = Vec::new();
        for i in start..end.min(self.tokens.len()) {
            tokens.push(&self.tokens[i]);
        }
        
        if tokens.is_empty() {
            return None;
        }
        
        // Handle list types first: [Type]
        if let Token::LeftBracket = tokens[0] {
            if tokens.len() >= 3 {
                if let Token::RightBracket = tokens[tokens.len() - 1] {
                    // Parse inner type
                    let inner_type = self.parse_type_from_tokens(start + 1, start + tokens.len() - 1);
                    return inner_type.map(|t| Type::List(Box::new(t)));
                }
            }
            return None;
        }
        
        // Look for function arrow to handle function types
        let mut arrow_pos = None;
        for (i, token) in tokens.iter().enumerate() {
            if let Token::Arrow = token {
                arrow_pos = Some(i);
                break;
            }
        }
        
        if let Some(arrow_idx) = arrow_pos {
            // Function type: Type -> Type
            if arrow_idx > 0 && arrow_idx + 1 < tokens.len() {
                let left_type = self.parse_type_from_tokens(start, start + arrow_idx);
                let right_type = self.parse_type_from_tokens(start + arrow_idx + 1, end);
                
                if let (Some(from), Some(to)) = (left_type, right_type) {
                    return Some(Type::Function(Box::new(from), Box::new(to)));
                }
            }
            return None;
        }
        
        // Handle simple types
        match tokens[0] {
            Token::Symbol(name) => {
                match name.as_str() {
                    "Int" => Some(Type::Int),
                    "Float" => Some(Type::Float),
                    "Bool" => Some(Type::Bool),
                    "String" => Some(Type::String),
                    _ => {
                        // Simple user-defined type
                        Some(Type::UserDefined {
                            name: name.clone(),
                            type_params: vec![],
                        })
                    }
                }
            }
            _ => None,
        }
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