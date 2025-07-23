use crate::{Span, XsError};
use std::iter::Peekable;
use std::str::Chars;

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // Basic tokens
    LeftParen,      // (
    RightParen,     // )
    LeftBrace,      // {
    RightBrace,     // }
    LeftBracket,    // [
    RightBracket,   // ]
    
    // Literals
    Int(i64),
    Float(f64),
    Bool(bool),
    String(String),
    Symbol(String),
    
    // Keywords (lowerCamelCase style)
    Let,
    LetRec,
    In,
    Fn,
    If,
    Else,
    Case,
    Of,
    Type,
    Data,
    Effect,
    Handler,
    With,
    Do,
    Perform,
    Module,
    Import,
    Export,
    As,
    Where,
    
    // Operators
    Equals,         // =
    EqualsEquals,   // ==
    Arrow,          // ->
    FatArrow,       // =>
    Pipe,           // |
    PipeForward,    // |>
    Dot,            // .
    Comma,          // ,
    Colon,          // :
    Semicolon,      // ;
    DoubleColon,    // ::
    At,             // @
    Hash,           // #
    Dollar,         // $
    Underscore,     // _
    Ellipsis,       // ...
    Backslash,      // \
    
    // Type/Effect operators
    LeftAngle,      // <
    RightAngle,     // >
    
    // Comments
    Comment(String),
    
    // Special
    Newline,
    Eof,
}

pub struct Lexer<'a> {
    chars: Peekable<Chars<'a>>,
    position: usize,
    line: usize,
    column: usize,
    skip_comments: bool,
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        Lexer {
            chars: input.chars().peekable(),
            position: 0,
            line: 1,
            column: 1,
            skip_comments: true,
        }
    }

    pub fn with_comments(input: &'a str) -> Self {
        let mut lexer = Self::new(input);
        lexer.skip_comments = false;
        lexer
    }

    pub fn next_token(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        self.skip_whitespace_except_newline();

        let start = self.position;

        match self.chars.peek() {
            None => Ok(None),
            Some(&ch) => {
                match ch {
                    '\n' => {
                        self.advance();
                        Ok(Some((Token::Newline, Span::new(start, self.position))))
                    }
                    '(' => {
                        self.advance();
                        Ok(Some((Token::LeftParen, Span::new(start, self.position))))
                    }
                    ')' => {
                        self.advance();
                        Ok(Some((Token::RightParen, Span::new(start, self.position))))
                    }
                    '{' => {
                        self.advance();
                        Ok(Some((Token::LeftBrace, Span::new(start, self.position))))
                    }
                    '}' => {
                        self.advance();
                        Ok(Some((Token::RightBrace, Span::new(start, self.position))))
                    }
                    '[' => {
                        self.advance();
                        Ok(Some((Token::LeftBracket, Span::new(start, self.position))))
                    }
                    ']' => {
                        self.advance();
                        Ok(Some((Token::RightBracket, Span::new(start, self.position))))
                    }
                    '=' if self.peek_next() == Some('>') => {
                        self.advance();
                        self.advance();
                        Ok(Some((Token::FatArrow, Span::new(start, self.position))))
                    }
                    '=' => {
                        if self.peek_next() == Some('=') {
                            self.advance();
                            self.advance();
                            Ok(Some((Token::EqualsEquals, Span::new(start, self.position))))
                        } else {
                            self.advance();
                            Ok(Some((Token::Equals, Span::new(start, self.position))))
                        }
                    }
                    '-' if self.peek_next() == Some('>') => {
                        self.advance();
                        self.advance();
                        Ok(Some((Token::Arrow, Span::new(start, self.position))))
                    }
                    '-' if self.peek_next() == Some('-') => {
                        self.read_line_comment()
                    }
                    '-' if self.peek_next().map(|c| c.is_numeric()).unwrap_or(false) => {
                        self.read_number()
                    }
                    '|' if self.peek_next() == Some('>') => {
                        self.advance();
                        self.advance();
                        Ok(Some((Token::PipeForward, Span::new(start, self.position))))
                    }
                    '|' => {
                        self.advance();
                        Ok(Some((Token::Pipe, Span::new(start, self.position))))
                    }
                    ':' if self.peek_next() == Some(':') => {
                        self.advance();
                        self.advance();
                        Ok(Some((Token::DoubleColon, Span::new(start, self.position))))
                    }
                    ':' => {
                        self.advance();
                        Ok(Some((Token::Colon, Span::new(start, self.position))))
                    }
                    '.' if self.peek_next() == Some('.') && self.peek_next_next() == Some('.') => {
                        self.advance();
                        self.advance();
                        self.advance();
                        Ok(Some((Token::Ellipsis, Span::new(start, self.position))))
                    }
                    '.' => {
                        self.advance();
                        Ok(Some((Token::Dot, Span::new(start, self.position))))
                    }
                    ',' => {
                        self.advance();
                        Ok(Some((Token::Comma, Span::new(start, self.position))))
                    }
                    ';' => {
                        self.advance();
                        Ok(Some((Token::Semicolon, Span::new(start, self.position))))
                    }
                    '@' => {
                        self.advance();
                        Ok(Some((Token::At, Span::new(start, self.position))))
                    }
                    '#' => {
                        self.advance();
                        Ok(Some((Token::Hash, Span::new(start, self.position))))
                    }
                    '$' => {
                        self.advance();
                        Ok(Some((Token::Dollar, Span::new(start, self.position))))
                    }
                    '\\' => {
                        self.advance();
                        Ok(Some((Token::Backslash, Span::new(start, self.position))))
                    }
                    '<' => self.read_operator(),
                    '>' => self.read_operator(),
                    '"' => self.read_string(),
                    '\'' => self.read_char_or_quoted_symbol(),
                    '0'..='9' => self.read_number(),
                    _ if ch.is_alphabetic() || ch == '_' => self.read_identifier(),
                    _ if is_operator_char(ch) => self.read_operator(),
                    _ => Err(XsError::ParseError(
                        self.position,
                        format!("Unexpected character: {ch}"),
                    )),
                }
            }
        }
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.chars.next();
        if let Some(c) = ch {
            self.position += 1;
            if c == '\n' {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
        }
        ch
    }

    fn peek_next(&mut self) -> Option<char> {
        let mut iter = self.chars.clone();
        iter.next();
        iter.peek().copied()
    }

    fn peek_next_next(&mut self) -> Option<char> {
        let mut iter = self.chars.clone();
        iter.next();
        iter.next();
        iter.peek().copied()
    }

    fn skip_whitespace_except_newline(&mut self) {
        while let Some(&ch) = self.chars.peek() {
            if ch == ' ' || ch == '\t' || ch == '\r' {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn read_line_comment(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        self.advance(); // skip first -
        self.advance(); // skip second -

        let mut comment = String::new();
        while let Some(&ch) = self.chars.peek() {
            if ch == '\n' {
                break;
            }
            comment.push(ch);
            self.advance();
        }

        if self.skip_comments {
            // Skip the comment and get next token
            self.next_token()
        } else {
            Ok(Some((
                Token::Comment(comment.trim().to_string()),
                Span::new(start, self.position),
            )))
        }
    }

    fn read_string(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        self.advance(); // skip opening quote

        let mut value = String::new();
        while let Some(&ch) = self.chars.peek() {
            if ch == '"' {
                self.advance();
                return Ok(Some((
                    Token::String(value),
                    Span::new(start, self.position),
                )));
            } else if ch == '\\' {
                self.advance();
                match self.chars.peek() {
                    Some(&'n') => {
                        self.advance();
                        value.push('\n');
                    }
                    Some(&'t') => {
                        self.advance();
                        value.push('\t');
                    }
                    Some(&'\\') => {
                        self.advance();
                        value.push('\\');
                    }
                    Some(&'"') => {
                        self.advance();
                        value.push('"');
                    }
                    _ => {
                        return Err(XsError::ParseError(
                            self.position,
                            "Invalid escape sequence".to_string(),
                        ))
                    }
                }
            } else {
                value.push(ch);
                self.advance();
            }
        }

        Err(XsError::ParseError(
            start,
            "Unterminated string".to_string(),
        ))
    }

    fn read_char_or_quoted_symbol(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        self.advance(); // skip opening quote

        let mut value = String::new();
        while let Some(&ch) = self.chars.peek() {
            if ch == '\'' {
                self.advance();
                // For now, treat as symbol
                return Ok(Some((
                    Token::Symbol(value),
                    Span::new(start, self.position),
                )));
            }
            value.push(ch);
            self.advance();
        }

        Err(XsError::ParseError(
            start,
            "Unterminated quoted symbol".to_string(),
        ))
    }

    fn read_number(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        let mut value = String::new();

        if let Some(&'-') = self.chars.peek() {
            value.push('-');
            self.advance();
        }

        while let Some(&ch) = self.chars.peek() {
            if ch.is_numeric() {
                value.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        // Check for decimal point
        if let Some(&'.') = self.chars.peek() {
            let mut peek_chars = self.chars.clone();
            peek_chars.next();
            if let Some(&next_ch) = peek_chars.peek() {
                if next_ch.is_numeric() {
                    value.push('.');
                    self.advance();

                    while let Some(&ch) = self.chars.peek() {
                        if ch.is_numeric() {
                            value.push(ch);
                            self.advance();
                        } else {
                            break;
                        }
                    }

                    match value.parse::<f64>() {
                        Ok(f) => return Ok(Some((Token::Float(f), Span::new(start, self.position)))),
                        Err(_) => {
                            return Err(XsError::ParseError(
                                start,
                                format!("Invalid float: {value}"),
                            ))
                        }
                    }
                }
            }
        }

        match value.parse::<i64>() {
            Ok(n) => Ok(Some((Token::Int(n), Span::new(start, self.position)))),
            Err(_) => Err(XsError::ParseError(
                start,
                format!("Invalid number: {value}"),
            )),
        }
    }

    fn read_identifier(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        let mut value = String::new();

        while let Some(&ch) = self.chars.peek() {
            if ch.is_alphanumeric() || ch == '_' {
                value.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        let token = match value.as_str() {
            "let" => Token::Let,
            "letrec" => Token::LetRec,
            "in" => Token::In,
            "fn" => Token::Fn,
            "if" => Token::If,
            "else" => Token::Else,
            "case" => Token::Case,
            "of" => Token::Of,
            "type" => Token::Type,
            "data" => Token::Data,
            "effect" => Token::Effect,
            "with" => Token::With,
            "do" => Token::Do,
            "perform" => Token::Perform,
            "handler" => Token::Handler,
            "module" => Token::Module,
            "import" => Token::Import,
            "export" => Token::Export,
            "as" => Token::As,
            "where" => Token::Where,
            "true" => Token::Bool(true),
            "false" => Token::Bool(false),
            "_" => Token::Underscore,
            _ => Token::Symbol(value),
        };

        Ok(Some((token, Span::new(start, self.position))))
    }

    fn read_operator(&mut self) -> Result<Option<(Token, Span)>, XsError> {
        let start = self.position;
        let mut value = String::new();

        while let Some(&ch) = self.chars.peek() {
            if is_operator_char(ch) {
                value.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        Ok(Some((Token::Symbol(value), Span::new(start, self.position))))
    }
}

fn is_operator_char(ch: char) -> bool {
    matches!(ch, '+' | '-' | '*' | '/' | '%' | '&' | '^' | '!' | '?' | '~' | '<' | '>' | '=')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_tokens() {
        let mut lexer = Lexer::new("{ } ( ) [ ]");
        
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::LeftBrace, Span::new(0, 1)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::RightBrace, Span::new(2, 3)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::LeftParen, Span::new(4, 5)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::RightParen, Span::new(6, 7)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::LeftBracket, Span::new(8, 9)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::RightBracket, Span::new(10, 11)))
        );
    }

    #[test]
    fn test_operators() {
        let mut lexer = Lexer::new("= -> => | |> :: ... @ #");
        
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Equals, Span::new(0, 1)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Arrow, Span::new(2, 4)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::FatArrow, Span::new(5, 7)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Pipe, Span::new(8, 9)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::PipeForward, Span::new(10, 12)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::DoubleColon, Span::new(13, 15)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Ellipsis, Span::new(16, 19)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::At, Span::new(20, 21)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Hash, Span::new(22, 23)))
        );
    }

    #[test]
    fn test_keywords() {
        let mut lexer = Lexer::new("let fn if else case of with do effect handler");
        
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Let, Span::new(0, 3)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Fn, Span::new(4, 6)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::If, Span::new(7, 9)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Else, Span::new(10, 14)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Case, Span::new(15, 19)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Of, Span::new(20, 22)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::With, Span::new(23, 27)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Do, Span::new(28, 30)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Effect, Span::new(31, 37)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Handler, Span::new(38, 45)))
        );
    }

    #[test]
    fn test_comments() {
        let mut lexer = Lexer::new("42 -- this is a comment\n43");
        
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(42), Span::new(0, 2)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Newline, Span::new(23, 24)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(43), Span::new(24, 26)))
        );
    }

    #[test]
    fn test_newlines() {
        let mut lexer = Lexer::new("42\n43\n");
        
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(42), Span::new(0, 2)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Newline, Span::new(2, 3)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Int(43), Span::new(3, 5)))
        );
        assert_eq!(
            lexer.next_token().unwrap(),
            Some((Token::Newline, Span::new(5, 6)))
        );
    }
}