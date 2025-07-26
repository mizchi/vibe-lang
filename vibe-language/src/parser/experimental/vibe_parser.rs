use super::gll::GLLParser;
use super::vibe_grammar::create_vibe_grammar;
use super::error::{ParseError, ErrorLocation};
use crate::parser::lexer::{Lexer, Token};
use crate::XsError;

/// Vibe language parser using GLL algorithm
pub struct VibeGLLParser {
    gll_parser: GLLParser,
}

impl VibeGLLParser {
    pub fn new() -> Self {
        let grammar = create_vibe_grammar();
        Self {
            gll_parser: GLLParser::new(grammar),
        }
    }
    
    /// Parse Vibe source code
    pub fn parse(&mut self, source: &str) -> Result<Vec<usize>, ParseError> {
        // Tokenize the input
        let tokens = self.tokenize(source)?;
        
        // Convert tokens to strings for GLL parser
        let token_strings: Vec<String> = tokens.into_iter()
            .map(|t| self.token_to_string(t))
            .collect();
        
        // Parse with GLL parser
        self.gll_parser.parse_with_errors(token_strings)
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
        
        Ok(tokens)
    }
    
    /// Convert Token to string representation for GLL parser
    fn token_to_string(&self, token: Token) -> String {
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
            
            // Special tokens
            Token::Eof => "EOF".to_string(),
            Token::Newline => "\n".to_string(),
            Token::Comment(_) => "comment".to_string(),
            
            // Other keywords not yet handled
            Token::Data => "data".to_string(),
            Token::Effect => "effect".to_string(),
            Token::Handler => "handler".to_string(),
            Token::End => "end".to_string(),
            Token::Where => "where".to_string(),
            Token::Forall => "forall".to_string(),
            Token::LeftArrow => "<-".to_string(),
            Token::PipeForward => "|>".to_string(),
            Token::Backslash => "\\".to_string(),
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
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_vibe_parser_let_binding() {
        let mut parser = VibeGLLParser::new();
        
        let source = "let x = 42";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_function() {
        let mut parser = VibeGLLParser::new();
        
        let source = "let add = fn x y -> x + y";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_match() {
        let mut parser = VibeGLLParser::new();
        
        let source = r#"
            match xs {
                [] -> 0
                h :: t -> 1 + length t
            }
        "#;
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_type_definition() {
        let mut parser = VibeGLLParser::new();
        
        let source = "type Option a = | None | Some a";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_if_expression() {
        let mut parser = VibeGLLParser::new();
        
        let source = "if x > 0 { x } else { 0 - x }";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_dollar_operator() {
        let mut parser = VibeGLLParser::new();
        
        let source = "print $ 1 + 2";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_let_in() {
        let mut parser = VibeGLLParser::new();
        
        let source = "let x = 10 in x + 5";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_module() {
        let mut parser = VibeGLLParser::new();
        
        let source = r#"
            module Math {
                export add, multiply
                let add = fn x y -> x + y
                let multiply = fn x y -> x * y
            }
        "#;
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_record() {
        let mut parser = VibeGLLParser::new();
        
        let source = "{ name: \"Alice\", age: 30 }";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_list() {
        let mut parser = VibeGLLParser::new();
        
        let source = "[1, 2, 3, 4, 5]";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_import() {
        let mut parser = VibeGLLParser::new();
        
        let source = "import Math.Utils as MU";
        let result = parser.parse(source);
        
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
    }
    
    #[test]
    fn test_vibe_parser_error_reporting() {
        let mut parser = VibeGLLParser::new();
        
        // Invalid syntax
        let source = "let x = if";
        let result = parser.parse(source);
        
        assert!(result.is_err());
        if let Err(e) = result {
            // Error should be structured and AI-friendly
            let json = e.to_ai_json();
            assert!(json.contains("\"category\": \"Syntax\""));
        }
    }
}