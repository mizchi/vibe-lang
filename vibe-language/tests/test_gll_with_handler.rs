//! Tests for with/handler expressions in GLL parser

use vibe_language::parser::experimental::GLLParser;
use vibe_language::parser::experimental::vibe_grammar::create_vibe_grammar;
use vibe_language::parser::lexer::{Lexer, Token};

/// Convert Token to string representation for GLL parser
fn token_to_string(token: &Token) -> String {
    match token {
        // Keywords
        Token::Let => "let".to_string(),
        Token::LetRec => "rec".to_string(),
        Token::In => "in".to_string(),
        Token::If => "if".to_string(),
        Token::Else => "else".to_string(),
        Token::Match => "match".to_string(),
        Token::Type => "type".to_string(),
        Token::Module => "module".to_string(),
        Token::Import => "import".to_string(),
        Token::Export => "export".to_string(),
        Token::As => "as".to_string(),
        Token::Fn => "fn".to_string(),
        Token::Perform => "perform".to_string(),
        Token::Handle => "handle".to_string(),
        Token::With => "with".to_string(),
        Token::Do => "do".to_string(),
        Token::Bool(true) => "true".to_string(),
        Token::Bool(false) => "false".to_string(),
        
        // Operators
        Token::Equals => "=".to_string(),
        Token::EqualsEquals => "==".to_string(),
        Token::LessThan | Token::LeftAngle => "<".to_string(),
        Token::GreaterThan | Token::RightAngle => ">".to_string(),
        Token::Arrow => "->".to_string(),
        Token::FatArrow => "=>".to_string(),
        Token::Pipe => "|".to_string(),
        Token::DoubleColon => "::".to_string(),
        Token::Dot => ".".to_string(),
        Token::Ellipsis => "...".to_string(),
        Token::Dollar => "$".to_string(),
        Token::At => "@".to_string(),
        Token::Hash => "#".to_string(),
        Token::QuestionMark => "?".to_string(),
        Token::Underscore => "_".to_string(),
        
        // Delimiters
        Token::LeftParen => "(".to_string(),
        Token::RightParen => ")".to_string(),
        Token::LeftBracket => "[".to_string(),
        Token::RightBracket => "]".to_string(),
        Token::LeftBrace => "{".to_string(),
        Token::RightBrace => "}".to_string(),
        
        // Separators
        Token::Comma => ",".to_string(),
        Token::Semicolon => ";".to_string(),
        Token::Colon => ":".to_string(),
        
        // Identifiers and literals
        Token::Symbol(s) => {
            // Check special symbols that are operators
            match s.as_str() {
                "+" => "+".to_string(),
                "-" => "-".to_string(),
                "*" => "*".to_string(),
                "/" => "/".to_string(),
                "<" => "<".to_string(),
                ">" => ">".to_string(),
                "<=" => "<=".to_string(),
                ">=" => ">=".to_string(),
                "!=" => "!=".to_string(),
                "&&" => "&&".to_string(),
                "||" => "||".to_string(),
                _ => {
                    // Check if it's a type identifier (starts with uppercase)
                    if s.chars().next().map_or(false, |c| c.is_uppercase()) {
                        "type_identifier".to_string()
                    } else {
                        "identifier".to_string()
                    }
                }
            }
        }
        Token::Int(_) => "number".to_string(),
        Token::Float(_) => "number".to_string(),
        Token::String(_) => "string".to_string(),
        Token::LeftArrow => "<-".to_string(),
        
        // Other tokens not yet implemented in grammar
        Token::Data => "data".to_string(),
        Token::Effect => "effect".to_string(),
        Token::Handler => "handler".to_string(),
        Token::End => "end".to_string(),
        Token::Where => "where".to_string(),
        Token::Backslash => "\\".to_string(),
        Token::Forall => "forall".to_string(),
        Token::PipeForward => "|>".to_string(),
        Token::Comment(_) => panic!("Comment token should not appear in parser"),
        Token::Newline => panic!("Newline token should not appear in parser"),
        Token::Eof => panic!("EOF token should not appear in parser"),
    }
}

#[test]
fn test_gll_parser_simple_expr() {
    // First test with a simple identifier
    let input = "x";
    let mut lexer = Lexer::new(input);
    let mut tokens = Vec::new();
    
    // Tokenize
    while let Ok(Some((token, _span))) = lexer.next_token() {
        tokens.push(token);
    }
    
    println!("Simple test - Tokens: {:?}", tokens);
    
    // Convert tokens to strings for GLL parser
    let token_strings: Vec<String> = tokens.iter().map(token_to_string).collect();
    
    println!("Simple test - Token strings: {:?}", token_strings);
    
    // Create parser
    let grammar = create_vibe_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Parse
    let result = parser.parse(token_strings);
    
    println!("Simple test - Parse result: {:?}", result);
    
    if let Err(ref e) = result {
        println!("Simple test - Parse error: {}", e);
    }
    
    assert!(result.is_ok(), "Failed to parse simple expression");
}

#[test]
fn test_gll_parser_handle_expression() {
    let input = "handle { x } { }";
    let mut lexer = Lexer::new(input);
    let mut tokens = Vec::new();
    
    // Tokenize
    while let Ok(Some((token, _span))) = lexer.next_token() {
        tokens.push(token);
    }
    
    println!("Handle test - Tokens: {:?}", tokens);
    
    // Convert tokens to strings for GLL parser
    let token_strings: Vec<String> = tokens.iter().map(token_to_string).collect();
    
    println!("Handle test - Token strings: {:?}", token_strings);
    
    // Create parser
    let grammar = create_vibe_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Parse (GLL parser starts from the grammar's start symbol)
    let result = parser.parse(token_strings);
    
    println!("Handle test - Parse result: {:?}", result);
    
    if let Err(ref e) = result {
        println!("Handle test - Parse error: {}", e);
        
        // Try a simpler version without handler cases
        let simple_input = vec!["handle".to_string(), "{".to_string(), "x".to_string(), "}".to_string(), "{".to_string(), "}".to_string()];
        println!("Trying with simple input: {:?}", simple_input);
        let mut parser2 = GLLParser::new(create_vibe_grammar());
        let simple_result = parser2.parse(simple_input);
        println!("Simple result: {:?}", simple_result);
    }
    
    assert!(result.is_ok(), "Failed to parse handle expression");
    
    let roots = result.unwrap();
    println!("Handle test - Roots: {:?}", roots);
    assert!(!roots.is_empty(), "No parse trees found");
}

#[test]
fn test_gll_parser_with_expression() {
    // Test with handler syntax - handler is an identifier followed by { expr }
    let input = "with stateHandler { 42 }";
    let mut lexer = Lexer::new(input);
    let mut tokens = Vec::new();
    
    // Tokenize
    while let Ok(Some((token, _span))) = lexer.next_token() {
        tokens.push(token);
    }
    
    println!("With test - Tokens: {:?}", tokens);
    
    // Convert tokens to strings for GLL parser
    let token_strings: Vec<String> = tokens.iter().map(token_to_string).collect();
    
    println!("With test - Token strings: {:?}", token_strings);
    
    // Create parser
    let grammar = create_vibe_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Parse
    let result = parser.parse(token_strings);
    
    println!("With test - Parse result: {:?}", result);
    
    if let Err(ref e) = result {
        println!("With test - Parse error: {}", e);
    }
    
    assert!(result.is_ok(), "Failed to parse with expression");
    
    let roots = result.unwrap();
    println!("Roots: {:?}", roots);
    assert!(!roots.is_empty(), "No parse trees found");
}

#[test]
fn test_gll_parser_do_expression() {
    // Test with semicolon
    let input = "do { x <- foo; y }";
    let mut lexer = Lexer::new(input);
    let mut tokens = Vec::new();
    
    // Tokenize
    while let Ok(Some((token, _span))) = lexer.next_token() {
        tokens.push(token);
    }
    
    println!("Do test - Tokens: {:?}", tokens);
    
    // Convert tokens to strings for GLL parser
    let token_strings: Vec<String> = tokens.iter().map(token_to_string).collect();
    
    println!("Do test - Token strings: {:?}", token_strings);
    
    // Create parser
    let grammar = create_vibe_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Parse
    let result = parser.parse(token_strings);
    
    println!("Do test - Parse result: {:?}", result);
    
    if let Err(ref e) = result {
        println!("Do test - Parse error: {}", e);
    }
    
    assert!(result.is_ok(), "Failed to parse do expression");
    
    let roots = result.unwrap();
    println!("Roots: {:?}", roots);
    assert!(!roots.is_empty(), "No parse trees found");
}

#[test]
fn test_gll_parser_perform_expression() {
    // EffectOp requires Effect.operation format
    let input = "perform IO.print \"Hello\"";
    let mut lexer = Lexer::new(input);
    let mut tokens = Vec::new();
    
    // Tokenize
    while let Ok(Some((token, _span))) = lexer.next_token() {
        tokens.push(token);
    }
    
    println!("Perform test - Tokens: {:?}", tokens);
    
    // Convert tokens to strings for GLL parser
    let token_strings: Vec<String> = tokens.iter().map(token_to_string).collect();
    
    println!("Perform test - Token strings: {:?}", token_strings);
    
    // Create parser
    let grammar = create_vibe_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Parse
    let result = parser.parse(token_strings);
    
    println!("Perform test - Parse result: {:?}", result);
    
    if let Err(ref e) = result {
        println!("Perform test - Parse error: {}", e);
    }
    
    assert!(result.is_ok(), "Failed to parse perform expression");
    
    let roots = result.unwrap();
    println!("Roots: {:?}", roots);
    assert!(!roots.is_empty(), "No parse trees found");
}