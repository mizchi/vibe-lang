use crate::{Type, Expr, parser::lexer::Lexer};
use super::vibe_grammar::create_vibe_grammar;
use super::gll::GLLParser;
use super::sppf_to_ast_converter::SPPFToASTConverter;

/// Parse source code using the GLL parser
pub fn parse_with_gll(source: &str) -> Result<Vec<Expr>, String> {
    let mut lexer = Lexer::new(source);
    let mut tokens = Vec::new();
    
    // Collect all tokens
    while let Some((token, _span)) = lexer.next_token().map_err(|e| e.to_string())? {
        tokens.push(token);
    }
    
    // Debug: print tokens
    eprintln!("DEBUG parse_with_gll: tokens = {:?}", tokens);
    
    let grammar = create_vibe_grammar();
    let mut parser = GLLParser::new(grammar);
    
    // Convert tokens to strings for the GLL parser
    let token_strings: Vec<String> = tokens.iter().map(|tok| {
        use crate::parser::lexer::Token;
        match tok {
            Token::Symbol(s) => s.clone(),
            Token::Int(n) => n.to_string(),
            Token::Float(f) => f.to_string(),
            Token::String(s) => format!("\"{}\"", s),
            Token::Bool(b) => b.to_string(),
            Token::Let => "let".to_string(),
            Token::LetRec => "rec".to_string(),
            Token::In => "in".to_string(),
            Token::Fn => "fn".to_string(),
            Token::If => "if".to_string(),
            Token::Else => "else".to_string(),
            Token::Match => "match".to_string(),
            Token::Type => "type".to_string(),
            Token::Data => "data".to_string(),
            Token::Effect => "effect".to_string(),
            Token::With => "with".to_string(),
            Token::Do => "do".to_string(),
            Token::Perform => "perform".to_string(),
            Token::Handler => "handler".to_string(),
            Token::Handle => "handle".to_string(),
            Token::End => "end".to_string(),
            Token::Module => "module".to_string(),
            Token::Import => "import".to_string(),
            Token::Export => "export".to_string(),
            Token::As => "as".to_string(),
            Token::Where => "where".to_string(),
            Token::Forall => "forall".to_string(),
            Token::Underscore => "_".to_string(),
            Token::LeftParen => "(".to_string(),
            Token::RightParen => ")".to_string(),
            Token::LeftBracket => "[".to_string(),
            Token::RightBracket => "]".to_string(),
            Token::LeftBrace => "{".to_string(),
            Token::RightBrace => "}".to_string(),
            Token::Comma => ",".to_string(),
            Token::Semicolon => ";".to_string(),
            Token::Colon => ":".to_string(),
            Token::Equals => "=".to_string(),
            Token::EqualsEquals => "==".to_string(),
            Token::Arrow => "->".to_string(),
            Token::FatArrow => "=>".to_string(),
            Token::LeftArrow => "<-".to_string(),
            Token::Pipe => "|".to_string(),
            Token::PipeForward => "|>".to_string(),
            Token::LessThan => "<".to_string(),
            Token::GreaterThan => ">".to_string(),
            Token::QuestionMark => "?".to_string(),
            Token::Backslash => "\\".to_string(),
            Token::Newline => "\n".to_string(),
            _ => "".to_string(),
        }
    }).collect();
    
    eprintln!("DEBUG parse_with_gll: token_strings = {:?}", token_strings);
    let roots = parser.parse(token_strings)?;
    
    eprintln!("DEBUG parse_with_gll: roots = {:?}", roots);
    
    if roots.is_empty() {
        return Err("No valid parse found".to_string());
    }
    
    // Convert SPPF to AST
    let sppf = parser.get_sppf();
    let converter = SPPFToASTConverter::new(sppf, tokens);
    converter.convert(roots).map_err(|e| format!("{:?}", e))
}

/// Node identifier for AST nodes
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(pub u64);

/// Parser state for tracking effects and verification
#[derive(Debug, Clone, Default)]
pub struct ParserState {
    /// Tracked effects during parsing
    pub effects: Vec<ParseEffect>,
    /// Verification constraints
    pub constraints: Vec<Constraint>,
}

/// Token type for ParseEffect
#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Let,
    If,
}

/// Effects that occur during parsing (Morpheus-style)
#[derive(Debug, Clone, PartialEq)]
pub enum ParseEffect {
    /// Token consumption
    Consume(Token),
    /// Lookahead
    Lookahead(usize),
    /// Backtracking
    Backtrack,
    /// Error recovery
    ErrorRecovery(String),
    /// Semantic action
    SemanticAction(String),
}

/// Verification constraints (Morpheus-style)
#[derive(Debug, Clone, PartialEq)]
pub enum Constraint {
    /// Type constraint
    TypeConstraint { expr: NodeId, expected: Type },
    /// Effect constraint
    EffectConstraint { expr: NodeId, effects: Vec<String> },
    /// Termination constraint
    Termination { expr: NodeId },
    /// Equivalence constraint
    Equivalence { left: NodeId, right: NodeId },
}