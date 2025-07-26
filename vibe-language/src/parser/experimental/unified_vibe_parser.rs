use super::gll::GLLParser;
use super::unified_vibe_grammar::create_unified_vibe_grammar;
use super::error::{ParseError, ErrorLocation};
use super::sppf_to_ast_converter::{SPPFToASTConverter, ConversionError};
use super::expression_combiner::ExpressionCombiner;
use crate::parser::lexer::{Lexer, Token};
use crate::{Expr};
use crate::XsError;

/// Unified Vibe language parser using consistent syntax
pub struct UnifiedVibeParser {
    pub(crate) gll_parser: GLLParser,
    /// Store tokens for SPPF to AST conversion
    last_tokens: Vec<Token>,
}

impl UnifiedVibeParser {
    pub fn new() -> Self {
        let grammar = create_unified_vibe_grammar();
        Self {
            gll_parser: GLLParser::new(grammar),
            last_tokens: vec![],
        }
    }
    
    /// Parse Vibe source code using unified syntax
    pub fn parse(&mut self, source: &str) -> Result<Vec<Expr>, ParseError> {
        // Tokenize the input
        let tokens = self.tokenize(source)?;
        
        // Store tokens for later use
        self.last_tokens = tokens.clone();
        
        // Convert tokens to strings for GLL parser
        let token_strings: Vec<String> = tokens.into_iter()
            .map(|t| self.token_to_string(t))
            .collect();
        
        #[cfg(test)]
        if source.contains('[') {
            println!("DEBUG: GLL parser input strings: {:?}", token_strings);
        }
        
        // Parse with GLL parser
        let sppf_roots = self.gll_parser.parse_with_errors(token_strings)?;
        
        // eprintln!("GLL parse returned {} roots", sppf_roots.len());
        
        // Convert SPPF to AST
        eprintln!("Starting SPPF to AST conversion with {} roots", sppf_roots.len());
        
        // Debug: Print SPPF roots info
        for (i, &root_id) in sppf_roots.iter().enumerate() {
            eprintln!("  Root {}: node_id={}", i, root_id);
        }
        
        let ast = self.sppf_to_ast(sppf_roots)?;
        eprintln!("AST conversion complete: {} expressions", ast.len());
        
        Ok(ast)
    }
    
    /// Tokenize source code
    fn tokenize(&self, source: &str) -> Result<Vec<Token>, ParseError> {
        let mut lexer = Lexer::new(source);
        let mut tokens = Vec::new();
        
        loop {
            match lexer.next_token() {
                Ok(Some((token, _span))) => {
                    // Skip newlines and comments for now
                    match token {
                        Token::Newline | Token::Comment(_) => continue,
                        _ => tokens.push(token),
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    return Err(self.xs_error_to_parse_error(e, source));
                }
            }
        }
        
        #[cfg(test)]
        if source.contains('[') {
            println!("DEBUG: tokenize() input '{}' produced tokens: {:?}", source, tokens);
        }
        
        Ok(tokens)
    }
    
    /// Convert Token to string representation for GLL parser
    fn token_to_string(&self, token: Token) -> String {
        match token {
            // Keywords
            Token::Let => "let".to_string(),
            Token::LetRec => "letrec".to_string(),
            Token::In => "in".to_string(),
            Token::If => "if".to_string(),
            Token::Else => "else".to_string(),
            Token::Match => "match".to_string(),  // Updated to match syntax
            Token::Type => "type".to_string(),
            Token::Module => "module".to_string(),
            Token::Import => "import".to_string(),
            Token::Export => "exposing".to_string(),  // Using 'exposing' in unified syntax
            Token::As => "as".to_string(),
            Token::Fn => "fn".to_string(),  // Lambda syntax
            Token::Perform => "perform".to_string(),
            Token::Handle => "handle".to_string(),
            Token::With => "with".to_string(),
            Token::Do => "do".to_string(),
            Token::Bool(true) => "true".to_string(),
            Token::Bool(false) => "false".to_string(),
            Token::Where => "where".to_string(),
            Token::End => "end".to_string(),
            Token::Forall => "forall".to_string(),
            Token::Data => "data".to_string(),
            Token::Effect => "effect".to_string(),
            Token::Handler => "handler".to_string(),
            
            // Keywords specific to unified syntax
            Token::Symbol(ref s) if s == "and" => "and".to_string(),
            Token::Symbol(ref s) if s == "then" => "then".to_string(),
            Token::Symbol(ref s) if s == "of" => "of".to_string(),
            Token::Symbol(ref s) if s == "when" => "when".to_string(),
            Token::Symbol(ref s) if s == "class" => "class".to_string(),
            Token::Symbol(ref s) if s == "instance" => "instance".to_string(),
            Token::Symbol(ref s) if s == "mod" => "mod".to_string(),
            
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
            Token::Ellipsis => "..".to_string(),
            Token::Dollar => "$".to_string(),
            Token::At => "@".to_string(),
            Token::Hash => "#".to_string(),
            Token::QuestionMark => "?".to_string(),
            Token::Underscore => "_".to_string(),
            Token::LeftArrow => "<-".to_string(),
            Token::PipeForward => "|>".to_string(),
            Token::Backslash => "\\".to_string(),
            
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
                    "++" => "++".to_string(),
                    "^" => "^".to_string(),
                    "?" => "?".to_string(),
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
            
            // Special tokens
            Token::Eof => "EOF".to_string(),
            Token::Newline => "\n".to_string(),
            Token::Comment(_) => "comment".to_string(),
        }
    }
    
    /// Convert XsError to ParseError
    fn xs_error_to_parse_error(&self, error: XsError, _source: &str) -> ParseError {
        let message = format!("{}", error);
        let location = ErrorLocation {
            file: None,
            line: 1, // TODO: Extract actual line/column from span
            column: 1,
            offset: 0,
            length: 1,
        };
        
        ParseError::syntax(message, location)
    }
    
    /// Convert SPPF to AST
    fn sppf_to_ast(&self, sppf_roots: Vec<usize>) -> Result<Vec<Expr>, ParseError> {
        // eprintln!("sppf_to_ast called with {} roots", sppf_roots.len());
        // Get SPPF reference from the parser
        let sppf = self.gll_parser.get_sppf();
        
        // Use stored tokens
        let tokens = self.last_tokens.clone();
        // eprintln!("Got {} tokens from tokenizer", tokens.len());
        
        // Create converter
        let converter = SPPFToASTConverter::new(sppf, tokens);
        
        // Convert SPPF roots to AST
        let exprs = converter.convert(sppf_roots)
            .map_err(|e| self.conversion_error_to_parse_error(e))?;
        
        // Apply expression combiner to fix split expressions
        let combiner = ExpressionCombiner::new(exprs);
        let combined = combiner.combine();
        
        // eprintln!("After combining: {} expressions", combined.len());
        Ok(combined)
    }
    
    /// Convert ConversionError to ParseError
    fn conversion_error_to_parse_error(&self, error: ConversionError) -> ParseError {
        let message = format!("AST conversion error: {}", error);
        let location = ErrorLocation {
            file: None,
            line: 1,
            column: 1,
            offset: 0,
            length: 1,
        };
        
        ParseError::syntax(message, location)
    }
    
    /// Get GLL parser for testing
    #[cfg(test)]
    pub fn gll_parser(&self) -> &GLLParser {
        &self.gll_parser
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_unified_parser_let_binding() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = "let x = 42";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_function() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = "let add x y = x + y";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_case_expression() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = r#"
            case xs of
            | [] -> 0
            | h :: t -> 1 + length t
        "#;
        
        // Debug: print tokens
        if let Ok(tokens) = parser.tokenize(source) {
            println!("Tokens: {:?}", tokens);
        }
        
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_if_then_else() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = "if x > 0 then x else -x";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_pipeline() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = "[1, 2, 3] |> map double |> filter positive";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_lambda() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = "\\x y -> x + y";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_type_definition() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = "type Option a = | None | Some a";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_module() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = r#"
            module Data.List exposing (map, filter) where
                let map f xs = case xs of
                    | [] -> []
                    | h :: t -> f h :: map f t
        "#;
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_unified_parser_do_notation() {
        let mut parser = UnifiedVibeParser::new();
        
        let source = r#"
            do {
                x <- readInt
                y <- readInt
                return x + y
            }
        "#;
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
}